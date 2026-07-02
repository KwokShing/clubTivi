import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/parsers/m3u_parser.dart';
import '../../data/datasources/remote/xtream_client.dart';
import '../../data/models/channel.dart' hide Provider;
import '../../data/services/logo_resolver_service.dart';
import '../../data/services/epg_refresh_service.dart';
import '../../core/feature_gate.dart';
import 'package:dio/dio.dart';

/// Manages IPTV providers: adding, refreshing, channel loading.
class ProviderManager {
  final db.AppDatabase _db;

  ProviderManager(this._db);

  /// Check provider count against tier limit.
  Future<void> _checkProviderLimit() async {
    final existing = await _db.getAllProviders();
    if (existing.length >= FeatureGate.maxProviders) {
      throw ProviderLimitException(FeatureGate.maxProviders);
    }
  }

  /// Add an M3U provider.
  Future<void> addM3uProvider({
    required String id,
    required String name,
    required String url,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(
      db.ProvidersCompanion.insert(
        id: id,
        name: name,
        type: 'm3u',
        url: Value(url),
      ),
    );
    await refreshProvider(id);
  }

  /// Update an existing M3U provider's name and/or source (URL or file path),
  /// then re-import its channels. Old channels are cleared first so a changed
  /// source doesn't leave stale entries behind. Returns the channel count.
  Future<int> updateM3uProvider({
    required String id,
    required String name,
    required String url,
  }) async {
    await _db.upsertProvider(
      db.ProvidersCompanion(
        id: Value(id),
        name: Value(name),
        type: const Value('m3u'),
        url: Value(url),
      ),
    );
    // refreshProvider re-imports and prunes channels no longer in the source,
    // preserving favorites for any channels that remain.
    return refreshProvider(id);
  }

  /// Add an Xtream Codes provider.
  Future<void> addXtreamProvider({
    required String id,
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(
      db.ProvidersCompanion.insert(
        id: id,
        name: name,
        type: 'xtream',
        url: Value(url),
        username: Value(username),
        password: Value(password),
      ),
    );
    await refreshProvider(id);
  }

  /// Refresh a provider's channels from its source.
  Future<int> refreshProvider(String providerId) async {
    final providers = await _db.getAllProviders();
    final provider = providers.firstWhere((p) => p.id == providerId);

    List<Channel> channels;
    if (provider.type == 'm3u') {
      channels = await _refreshM3u(provider);
    } else if (provider.type == 'xtream') {
      channels = await _refreshXtream(provider);
    } else {
      return 0;
    }

    // Save channels to database with sort order preserved from M3U
    await _db.upsertChannels(
      channels.asMap().entries.map((entry) {
        final c = entry.value;
        final index = entry.key;
        return db.ChannelsCompanion.insert(
          id: c.id,
          providerId: c.providerId,
          name: c.name,
          tvgId: Value(c.tvgId),
          tvgName: Value(c.tvgName),
          tvgLogo: Value(c.tvgLogo),
          groupTitle: Value(c.groupTitle),
          channelNumber: Value(c.channelNumber),
          streamUrl: c.streamUrl,
          streamType: Value(c.streamType.name),
          sortOrder: Value(index),
        );
      }).toList(),
    );

    // Prune channels that no longer exist in the refreshed source so the list
    // matches the playlist exactly (favorites for retained channels are kept).
    // Guard against an empty parse (e.g. transient fetch issue) wiping the list.
    if (channels.isNotEmpty) {
      await _db.deleteStaleChannels(
        providerId,
        channels.map((c) => c.id).toSet(),
      );
    }

    // NOTE: logos and EPG are intentionally NOT resolved here. They are loaded
    // lazily after the channel list is shown (logos via the UI's deferred
    // resolveAllMissingLogos, EPG via a delayed auto-refresh) so refreshing an
    // M3U updates the list immediately without competing for the main isolate.

    // Debug: log parsed vs unique IDs to detect collisions
    final uniqueIds = channels.map((c) => c.id).toSet();
    if (uniqueIds.length != channels.length) {
      debugPrint(
        '[M3U] WARNING: ${channels.length} channels parsed but only ${uniqueIds.length} unique IDs — ${channels.length - uniqueIds.length} will be lost to ID collisions!',
      );
      // Log the colliding IDs
      final seen = <String>{};
      for (final c in channels) {
        if (seen.contains(c.id)) {
          debugPrint('[M3U] Collision: id=${c.id} name=${c.name}');
        }
        seen.add(c.id);
      }
    } else {
      debugPrint('[M3U] Parsed ${channels.length} channels, all IDs unique.');
    }

    return channels.length;
  }

  /// Refresh every M3U provider in one pass. Returns a per-provider result
  /// map (provider name → channel count, or -1 on failure) so the UI can
  /// summarize what happened. Xtream providers are skipped.
  Future<Map<String, int>> refreshAllM3uProviders() async {
    final providers = await _db.getAllProviders();
    final m3uProviders = providers.where((p) => p.type == 'm3u').toList();
    final results = <String, int>{};
    for (final provider in m3uProviders) {
      try {
        final count = await refreshProvider(provider.id);
        results[provider.name] = count;
      } catch (e) {
        debugPrint('[M3U] Refresh-all failed for ${provider.name}: $e');
        results[provider.name] = -1;
      }
    }
    return results;
  }

  Future<List<Channel>> _refreshM3u(db.Provider provider) async {
    final source = provider.url!;
    final isRemote =
        source.startsWith('http://') || source.startsWith('https://');
    String data;
    if (isRemote) {
      final dio = Dio();
      try {
        final response = await dio.get<String>(source);
        data = response.data!;
      } finally {
        dio.close();
      }
    } else {
      // Local file import: the provider's "url" holds a file path. Read and
      // decode tolerantly — m3u files are usually UTF-8 but may carry stray
      // bytes that would otherwise throw.
      final bytes = await File(source).readAsBytes();
      data = utf8.decode(bytes, allowMalformed: true);
    }
    // Parse off the main isolate so large playlists don't freeze the UI.
    final result = await compute(
      parseM3uInBackground,
      (data, provider.id),
    );

    // Auto-add EPG source from M3U header if present, then refresh it lazily
    if (result.epgUrl != null && result.epgUrl!.isNotEmpty) {
      await _autoAddEpgSource(provider.id, provider.name, result.epgUrl!);
      // Defer EPG data refresh so the channel list settles first — EPG is not
      // needed immediately and downloading/parsing it competes for resources.
      Future.delayed(
        const Duration(seconds: 8),
        () => _refreshEpgForProvider(provider.id),
      );
    }

    // Debug: log per-group channel counts
    final groupCounts = <String, int>{};
    for (final c in result.channels) {
      final g = c.groupTitle ?? 'Ungrouped';
      groupCounts[g] = (groupCounts[g] ?? 0) + 1;
    }
    debugPrint(
      '[M3U] ${provider.name}: ${result.channels.length} total channels, ${groupCounts.length} groups',
    );
    for (final entry in groupCounts.entries) {
      debugPrint('[M3U]   ${entry.key}: ${entry.value}');
    }

    return result.channels;
  }

  Future<List<Channel>> _refreshXtream(db.Provider provider) async {
    final client = XtreamClient(
      baseUrl: provider.url!,
      username: provider.username!,
      password: provider.password!,
    );
    try {
      return await client.getLiveStreams(providerId: provider.id);
    } finally {
      client.dispose();
    }
  }

  /// Auto-add EPG source from M3U url-tvg if not already present.
  Future<void> _autoAddEpgSource(
    String providerId,
    String providerName,
    String epgUrl,
  ) async {
    try {
      // Use provider-specific ID so each M3U gets its own EPG source
      final autoId = 'auto_$providerId';
      final existing = await _db.getAllEpgSources();
      // Don't re-add if same URL already stored for this provider
      final current = existing.where((s) => s.id == autoId).toList();
      if (current.isNotEmpty && current.first.url == epgUrl) return;
      // Remove old auto-EPG for this provider before adding new one
      if (current.isNotEmpty) {
        await _db.deleteEpgSource(autoId);
      }
      await _db.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: autoId,
          name: '$providerName EPG',
          url: epgUrl,
          enabled: Value(true),
        ),
      );
    } catch (_) {
      // Silently ignore EPG source add failures
    }
  }

  /// Refresh EPG data for a provider's auto-EPG source in background.
  void _refreshEpgForProvider(String providerId) {
    final sourceId = 'auto_$providerId';
    // Fire and forget — don't block channel loading
    Future(() async {
      try {
        final epgService = EpgRefreshService(_db);
        await epgService.refreshSource(sourceId);
        debugPrint('[EPG] Auto-refresh complete for provider $providerId');
      } catch (e) {
        debugPrint('[EPG] Auto-refresh failed for provider $providerId: $e');
      }
    });
  }

  Future<void> deleteProvider(String id) async {
    // Also remove the auto-EPG source for this provider
    try {
      await _db.deleteEpgSource('auto_$id');
    } catch (e) {
      debugPrint('[Provider] No auto-EPG source to delete for $id: $e');
    }
    await _db.deleteProvider(id);
  }

  /// Resolve missing logos for a set of channels.
  /// Public so it can be called at startup for existing DB channels.
  Future<void> resolveLogosForChannels(List<Channel> channels) async {
    final needsLogo = channels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) return;
    debugPrint('[Logo] ${needsLogo.length} channels need logos');

    final resolved = <String, String>{};

    // First try EPG icons for channels that have EPG mappings
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      final epgIconMap = <String, String>{};
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          epgIconMap[ec.displayName.toLowerCase()] = ec.iconUrl!;
          epgIconMap[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
      for (final ch in needsLogo) {
        final stripped = ch.name
            .toLowerCase()
            .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
            .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
            .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
            .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
        final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
        if (icon != null) {
          resolved[ch.id] = icon;
        }
      }
      // Drop EPG-resolved channels in one pass (avoids O(n^2) removeWhere).
      needsLogo.removeWhere((c) => resolved.containsKey(c.id));
      debugPrint('[Logo] EPG icons resolved ${resolved.length} channels');
    } catch (e) {
      debugPrint('[Logo] EPG icon resolution failed: $e');
    }

    // Then resolve remaining from tv-logo/tv-logos GitHub repo
    if (needsLogo.isNotEmpty) {
      debugPrint('[Logo] Resolving ${needsLogo.length} via GitHub tv-logos...');
      final ghResolved = await LogoResolverService.resolveLogosForChannels(
        needsLogo,
      );
      debugPrint('[Logo] GitHub resolved ${ghResolved.length} logos');
      resolved.addAll(ghResolved);
    }

    // Batch-write all resolved logos in a single transaction
    if (resolved.isNotEmpty) {
      await _db.updateChannelLogos(resolved);
    }
  }

  static const _logoResolvedKey = 'logo_last_resolved';
  static const _logoChannelCountKey = 'logo_channel_count';
  static const _logoCooldown = Duration(hours: 6);
  static const _logoBatchSize = 200;

  /// Resolve missing logos progressively: favorites first, then the rest
  /// in small batches so the UI stays responsive.
  /// Skips entirely if resolved recently and channel count hasn't changed.
  Future<void> resolveAllMissingLogos() async {
    final prefs = await SharedPreferences.getInstance();
    final lastResolved = prefs.getInt(_logoResolvedKey) ?? 0;
    final lastCount = prefs.getInt(_logoChannelCountKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - lastResolved;

    final allChannels = await _db.getAllChannels();

    // Skip if resolved recently AND no new channels were added
    if (age < _logoCooldown.inMilliseconds && allChannels.length == lastCount) {
      return;
    }

    final needsLogo = allChannels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) {
      await prefs.setInt(
        _logoResolvedKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setInt(_logoChannelCountKey, allChannels.length);
      return;
    }

    // Build lookup maps once
    final epgIconMap = await _buildEpgIconMap();
    await LogoResolverService.ensureIndex(); // pre-load GitHub index

    // Partition: favorites first, then the rest
    final favIds = await _db.getAllFavoritedChannelIds();
    final favorites = needsLogo.where((c) => favIds.contains(c.id)).toList();
    final rest = needsLogo.where((c) => !favIds.contains(c.id)).toList();

    debugPrint(
      '[Logo] ${needsLogo.length} missing (${favorites.length} favorites, ${rest.length} other)',
    );

    // Resolve favorites immediately (one write) so they appear quickly.
    if (favorites.isNotEmpty) {
      final resolved = await _resolveLogoBatch(favorites, epgIconMap);
      if (resolved.isNotEmpty) {
        await _db.updateChannelLogos(resolved);
        debugPrint('[Logo] Favorites: resolved ${resolved.length} logos');
      }
    }

    // Resolve the rest in batches but ACCUMULATE the results and write them in
    // a single DB write at the end. Writing per-batch fired the full-table
    // channels watch dozens of times, re-materializing every channel on the
    // main isolate and blocking interaction. One write = one watch emission.
    final allResolved = <String, String>{};
    for (var i = 0; i < rest.length; i += _logoBatchSize) {
      final batch = rest.sublist(i, (i + _logoBatchSize).clamp(0, rest.length));
      final resolved = await _resolveLogoBatch(batch, epgIconMap);
      allResolved.addAll(resolved);
      // Yield between batches so matching doesn't hog a turn.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (allResolved.isNotEmpty) {
      await _db.updateChannelLogos(allResolved);
      debugPrint('[Logo] Resolved ${allResolved.length} logos (single write)');
    }

    debugPrint('[Logo] Resolution complete');
    await prefs.setInt(_logoResolvedKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_logoChannelCountKey, allChannels.length);
  }

  /// Build EPG icon lookup map (display name / channel ID → icon URL).
  Future<Map<String, String>> _buildEpgIconMap() async {
    final map = <String, String>{};
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          map[ec.displayName.toLowerCase()] = ec.iconUrl!;
          map[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
    } catch (e) {
      debugPrint('[Logo] Failed to build EPG icon map: $e');
    }
    return map;
  }

  /// Resolve logos for a batch of channels using EPG icons + GitHub tv-logos.
  Future<Map<String, String>> _resolveLogoBatch(
    List<({String id, String name, String? tvgLogo})> channels,
    Map<String, String> epgIconMap,
  ) async {
    final resolved = <String, String>{};
    final remaining = <({String id, String name, String? tvgLogo})>[];

    for (final ch in channels) {
      final stripped = ch.name
          .toLowerCase()
          .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
          .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
          .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
          .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
      final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
      if (icon != null) {
        resolved[ch.id] = icon;
      } else {
        remaining.add(ch);
      }
    }

    if (remaining.isNotEmpty) {
      final ghResolved = await LogoResolverService.resolveLogosForChannels(
        remaining,
      );
      resolved.addAll(ghResolved);
    }

    return resolved;
  }
}

class ProviderLimitException implements Exception {
  final int limit;
  const ProviderLimitException(this.limit);

  @override
  String toString() =>
      'Provider limit reached ($limit). Upgrade to Pro for unlimited providers.';
}

/// Riverpod provider for the database.
final databaseProvider = Provider<db.AppDatabase>((ref) {
  final database = db.AppDatabase();
  // Close defensively: a backup restore closes the connection before replacing
  // the file, then triggers an app restart which disposes this provider and
  // would otherwise close an already-closed database.
  ref.onDispose(() async {
    try {
      await database.close();
    } catch (e) {
      debugPrint('[Database] close on dispose (likely already closed): $e');
    }
  });
  return database;
});

/// Riverpod provider for the provider manager.
final providerManagerProvider = Provider<ProviderManager>((ref) {
  return ProviderManager(ref.watch(databaseProvider));
});

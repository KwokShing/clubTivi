import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../datasources/local/database.dart' as db;
import '../datasources/parsers/xmltv_parser.dart';
import '../models/epg.dart';
import '../../features/providers/provider_manager.dart';

/// Runs heavy XML parsing in a background isolate.
XmltvResult _parseInIsolate(_ParseArgs args) {
  return XmltvParser().parse(args.xml, sourceId: args.sourceId);
}

class _ParseArgs {
  final String xml;
  final String sourceId;
  const _ParseArgs(this.xml, this.sourceId);
}

class EpgRefreshService {
  final db.AppDatabase _db;
  final _uuid = const Uuid();

  EpgRefreshService(this._db);

  /// Refresh a single EPG source by ID.
  Future<void> refreshSource(String sourceId) async {
    final sources = await _db.getAllEpgSources();
    final source = sources.firstWhere((s) => s.id == sourceId);
    debugPrint('[EPG] Refreshing source: ${source.name} (${source.url})');

    // Download XMLTV data
    final dio = Dio(
      BaseOptions(
        headers: {
          'User-Agent': 'clubTivi/1.0 IPTV Player (compatible; XMLTV fetcher)',
        },
      ),
    );
    try {
      final response = await dio.get<List<int>>(
        source.url,
        options: Options(responseType: ResponseType.bytes),
      );

      final bytes = response.data!;
      debugPrint('[EPG] Downloaded ${bytes.length} bytes');

      // Only keep programmes for the recent-past .. next-2-days window. The
      // filtering happens INSIDE the isolate (see _decompressAndParse) so a
      // huge XMLTV doesn't ship hundreds of thousands of programmes back across
      // the isolate boundary and exhaust memory on iOS.
      final now = DateTime.now();
      final cutoffStart = now.subtract(const Duration(hours: 6));
      final cutoffEnd = now.add(const Duration(days: 2));

      // Decompress + parse + filter in background isolate to avoid ANR / OOM
      final result = await compute(
        _decompressAndParse,
        _DecompressParseArgs(
          bytes,
          sourceId,
          cutoffStart.millisecondsSinceEpoch,
          cutoffEnd.millisecondsSinceEpoch,
        ),
      );
      debugPrint(
        '[EPG] Parsed ${result.channels.length} channels, ${result.programmes.length} programmes (windowed)',
      );

      // Store channels
      final channelCompanions = result.channels.map((c) {
        return db.EpgChannelsCompanion.insert(
          id: '${sourceId}_${c.id}',
          sourceId: sourceId,
          channelId: c.id,
          displayName: c.primaryName,
          iconUrl: Value(c.iconUrl),
        );
      }).toList();
      await _db.upsertEpgChannels(channelCompanions);

      final filteredProgrammes = result.programmes;

      // Delete old programmes for this source, then insert filtered ones
      await _db.deleteEpgProgrammesForSource(sourceId);
      final programmeCompanions = filteredProgrammes.map((p) {
        return db.EpgProgrammesCompanion.insert(
          epgChannelId: '${sourceId}_${p.channelId}',
          sourceId: sourceId,
          title: p.title,
          description: Value(p.description),
          category: Value(p.category),
          subtitle: Value(p.subtitle),
          episodeNum: Value(p.episodeNum),
          start: p.start,
          stop: p.stop,
        );
      }).toList();
      if (programmeCompanions.isNotEmpty) {
        // Insert in larger batches now that dataset is smaller
        for (var i = 0; i < programmeCompanions.length; i += 10000) {
          final end = (i + 10000).clamp(0, programmeCompanions.length);
          await _db.insertEpgProgrammes(programmeCompanions.sublist(i, end));
          await Future<void>.delayed(Duration.zero);
        }
      }

      // Update last refresh timestamp
      await _db.updateEpgSourceRefreshTime(sourceId);
      debugPrint('[EPG] Refresh complete for ${source.name}');
    } finally {
      dio.close();
    }
  }

  /// Refresh all enabled EPG sources (skips sources refreshed within the last 4 hours).
  Future<void> refreshAllSources({bool force = false}) async {
    final sources = await _db.getAllEpgSources();
    final now = DateTime.now();
    for (final source in sources.where((s) => s.enabled)) {
      if (!force &&
          source.lastRefresh != null &&
          now.difference(source.lastRefresh!).inHours < 4) {
        debugPrint(
          '[EPG] Skipping ${source.name} — refreshed ${now.difference(source.lastRefresh!).inMinutes}m ago',
        );
        continue;
      }
      try {
        await refreshSource(source.id);
      } catch (e) {
        debugPrint('[EPG] Error refreshing ${source.name}: $e');
      }
    }
  }

  /// Add default free EPG sources if none exist.
  Future<void> addDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    if (existing.isNotEmpty) return;
    await _insertDefaults();
  }

  /// Delete all existing sources and re-add defaults.
  Future<void> resetToDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    for (final s in existing) {
      await _db.deleteEpgSource(s.id);
    }
    await _insertDefaults();
  }

  Future<void> _insertDefaults() async {
    final defaults = [
      (
        name: 'EPG.best',
        url: 'http://epg.best/16b5b-ypkixv.xml.gz',
        enabled: true,
      ),
      (
        name: 'USA Locals (ABC, CBS, Fox, NBC)',
        url:
            'https://raw.githubusercontent.com/usa-local-epg/usa-locals/main/usalocals.xml.gz',
        enabled: true,
      ),
    ];

    for (final d in defaults) {
      await _db.upsertEpgSource(
        db.EpgSourcesCompanion.insert(
          id: _uuid.v4(),
          name: d.name,
          url: d.url,
          enabled: Value(d.enabled),
        ),
      );
    }
  }
}

final epgRefreshServiceProvider = Provider<EpgRefreshService>((ref) {
  return EpgRefreshService(ref.watch(databaseProvider));
});

/// Args for the background isolate (must be serializable).
class _DecompressParseArgs {
  final List<int> bytes;
  final String sourceId;
  final int cutoffStartMs;
  final int cutoffEndMs;
  const _DecompressParseArgs(
    this.bytes,
    this.sourceId,
    this.cutoffStartMs,
    this.cutoffEndMs,
  );
}

/// Top-level function for compute() — runs decompression + XML parsing off the
/// main thread, AND filters programmes to the keep-window inside the isolate.
///
/// Filtering here (rather than after the isolate returns) is critical for
/// low-memory devices like iOS: a full XMLTV can hold hundreds of thousands of
/// programmes, and serializing all of them back across the isolate boundary can
/// exhaust memory and get the app killed — leaving channels stored but no
/// programmes ("No EPG data"). Returning only the ~kept window avoids that.
XmltvResult _decompressAndParse(_DecompressParseArgs args) {
  List<int> decompressed;
  try {
    decompressed = gzip.decode(args.bytes);
  } catch (_) {
    decompressed = args.bytes;
  }
  final xmlContent = utf8.decode(decompressed, allowMalformed: true);
  final result = XmltvParser().parse(xmlContent, sourceId: args.sourceId);

  final cutoffStart = DateTime.fromMillisecondsSinceEpoch(args.cutoffStartMs);
  final cutoffEnd = DateTime.fromMillisecondsSinceEpoch(args.cutoffEndMs);
  final filtered = result.programmes
      .where((p) => p.stop.isAfter(cutoffStart) && p.start.isBefore(cutoffEnd))
      .toList();
  return XmltvResult(channels: result.channels, programmes: filtered);
}

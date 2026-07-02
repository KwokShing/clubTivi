import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, Platform;

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/countdown_snackbar.dart';
import '../../core/platform_info.dart';
import '../../core/weather_clock_widget.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/remote/tmdb_client.dart';
import '../../data/services/epg_refresh_service.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../player/player_service.dart';
import '../player/stream_info_badges.dart';
import '../providers/provider_manager.dart';
import '../shows/shows_providers.dart';
import 'channel_debug_dialog.dart';

class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key});

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  bool _initialLoadDone = false;
  String _loadStatus = '';
  bool _epgLoading = false;
  List<db.Channel> _allChannels = [];
  List<db.Channel> _filteredChannels = [];
  List<String> _groups = [];
  String _selectedGroup = 'All';
  String _searchQuery = '';
  // _showSearch removed — search bar is always visible in the top navbar
  int _selectedIndex = -1;
  db.Channel? _previewChannel;
  /// Current/near programmes for the scoped channels (flat list, filtered
  /// per-channel at lookup time — matches the known-good simple approach).
  List<db.EpgProgramme> _nowPlaying = [];

  /// Maps channel ID → mapped EPG channel ID (from epg_mappings table)
  Map<String, String> _epgMappings = {};

  /// Maps channel ID → user-set vanity name (original name preserved in DB)
  Map<String, String> _vanityNames = {};
  Map<String, String> _rawToPrefixedEpg = {}; // XMLTV channelId → prefixed id
  Map<String, String> _epgNameToId =
      {}; // normalized EPG displayName → prefixed id
  Map<String, String> _epgCallSignToId =
      {}; // call sign (e.g. WABC) → prefixed id
  bool _showGuideView = true;

  /// Use the compact vertical EPG layout (inline now/next + progress + tap to
  /// expand schedule) everywhere except Android TV, whose D-pad-driven
  /// horizontal timeline grid stays. Enabled on desktop too so it can be
  /// validated without an iOS build.
  bool get _useMobileEpg => !PlatformInfo.isTV;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  List<String> _searchHistory = [];
  static const _kSearchHistory = 'search_history';
  static const _kMaxSearchHistory = 20;
  final _channelListController = ScrollController();
  late final ScrollController _guideScrollController;
  Timer? _guideIdleTimer;
  Timer? _searchDebounce;

  // Overlay state
  // _showDebugOverlay removed — debug info is now a dialog
  Timer? _nowPlayingTimer;
  final _focusNode = FocusNode();

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeOverlayTimer;

  // Inline preview overlay (info + play bar) shown on tapping the video window
  bool _showPreviewControls = false;
  Timer? _previewControlsTimer;

  // Last channel for back/forth toggle (not a full history stack)
  int _previousIndex = -1;

  // Sidebar state
  bool _sidebarExpanded = true;
  Set<String> _expandedSections = {'favorites'};
  final _sidebarSearchController = TextEditingController();
  final _sidebarFocusNode = FocusScopeNode(debugLabel: 'sidebar');
  final _sidebarAllItemFocusNode = FocusNode(debugLabel: 'sidebar-all');
  final _firstChannelFocusNode = FocusNode(debugLabel: 'channel-first');
  String _sidebarSearchQuery = '';

  StreamSubscription<List<db.Provider>>? _providersSub;
  StreamSubscription<List<db.Channel>>? _channelsSub;

  // Provider list for sidebar
  List<db.Provider> _providers = [];
  // Pre-computed: provider ID → sorted group names
  Map<String, List<String>> _providerGroups = {};
  // Cheap signature of the channel set's structure (ids/names/groups). Used to
  // skip the expensive group rebuild + EPG re-index when a watch emission only
  // changed cosmetic data (e.g. logos resolved in the background).
  String? _channelStructureSignature;
  // Debounce timer for the heavy EPG re-index after a structural change.
  Timer? _epgReindexTimer;
  // Debounce timer for lazy logo resolution after the channel list settles.
  Timer? _logoResolveTimer;
  // Debounce timer for refreshing now-playing when the visible list changes.
  Timer? _nowPlayingDebounce;
  // Track which providers' channels have been loaded into _allChannels
  final Set<String> _loadedProviders = {};
  // Favorite lists state
  List<db.FavoriteList> _favoriteLists = [];
  Set<String> _favoritedChannelIds = {};

  // Multi-select mode for failover group creation
  bool _multiSelectMode = false;
  Set<String> _multiSelectedChannelIds = {};
  // Long-press timer for TV remote multi-select (CENTER held >600ms)
  Timer? _longPressTimer;
  String? _longPressChannelId;

  // Failover groups state
  List<db.FailoverGroup> _failoverGroups = [];

  /// groupId → ordered list of channel IDs
  Map<int, List<String>> _failoverGroupMembers = {};

  final Set<int> _expandedFailoverGroups = {};

  // Time format
  bool _use24HourTime = false;
  static const _kUse24HourTime = 'use_24_hour_time';

  // Per-channel EPG timeshift in hours
  final Map<String, int> _epgTimeshifts = {};
  static const _kEpgTimeshifts = 'epg_timeshifts';

  // IMDB ID cache: show title → IMDB ID (null = lookup in progress/failed)
  final Map<String, String?> _imdbIdCache = {};

  // EPG programme futures cache — stabilizes the guide's FutureBuilder subtree.
  // Without it, `future:` was rebuilt every frame, thrashing the Stack/Positioned
  // programme blocks and flooding the accessibility bridge (AXTree churn) /
  // previously crashing layout. ONLY successful, non-empty results are pinned;
  // empty/loading/error results are dropped so the guide self-heals once EPG
  // data arrives (avoids the earlier "EPG never loads" regression).
  // Keyed by epgId|shift|hourlyBucket; cleared on bucket rollover and EPG reload.
  final Map<String, Future<List<db.EpgProgramme>>> _programmeFutureCache = {};
  int? _programmeCacheBucket;

  // Persistence keys
  static const _kLastChannelId = 'last_channel_id';
  static const _kLastGroup = 'last_group';

  @override
  void initState() {
    super.initState();
    _guideScrollController = ScrollController();
    _loadChannels();
    _ensureEpgSources();
    _loadSearchHistory();
    // Resolve missing logos on startup (in background)
    ref
        .read(providerManagerProvider)
        .resolveAllMissingLogos()
        .catchError((_) {});
    // Watch providers + channels tables. Instead of re-running the heavy
    // staged _loadChannels (which races on overlapping refreshes and doubled
    // the in-memory list, and reset the view back to Favorites), update state
    // directly from the authoritative DB snapshot. This keeps other lists
    // untouched and preserves the current selection/group.
    final database = ref.read(databaseProvider);
    Timer? provDebounce;
    Timer? chanDebounce;

    _providersSub = database.select(database.providers).watch().listen((
      providers,
    ) {
      provDebounce?.cancel();
      provDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _onProvidersSnapshot(providers);
      });
    });
    _channelsSub = database.select(database.channels).watch().listen((all) {
      chanDebounce?.cancel();
      chanDebounce = Timer(const Duration(milliseconds: 500), () {
        if (mounted) _onChannelsSnapshot(all);
      });
    });
    // Refresh now-playing every 60 seconds so the info panel stays current
    _nowPlayingTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _refreshNowPlaying(),
    );
  }

  Future<void> _refreshNowPlaying() async {
    if (!mounted) return;
    final database = ref.read(databaseProvider);
    // Collect EPG channel IDs for all favorited channels + their failover alts
    final epgChannelIds = <String>{};
    final favChannels = _allChannels.where((c) => _favoritedChannelIds.contains(c.id));
    for (final c in favChannels) {
      final epgId = _getEpgId(c);
      if (epgId != null) epgChannelIds.add(epgId);
    }
    // Also include any currently filtered channels (e.g. failover alts in view)
    for (final c in _filteredChannels) {
      final epgId = _getEpgId(c);
      if (epgId != null) epgChannelIds.add(epgId);
    }
    if (epgChannelIds.isEmpty) return;
    final maxShift = _epgTimeshifts.values.fold<int>(0, (m, v) => v.abs() > m ? v.abs() : m);
    final now = DateTime.now();
    final nowPlaying = maxShift > 0
        ? await database.getNowPlayingWindow(
            epgChannelIds.toList(),
            now.subtract(Duration(hours: maxShift + 1)),
            now.add(Duration(hours: maxShift + 1)))
        : await database.getNowPlaying(epgChannelIds.toList());
    if (!mounted) return;
    setState(() {
      _nowPlaying = nowPlaying;
    });
  }

  /// Extract a broadcast call-sign sort key from a channel name.
  /// Channels with call signs (W/K + 2-3 letters) sort first (uppercase),
  /// others sort by cleaned name (lowercase) so they come after.
  static String _callSignSortKey(String name) {
    // Strip provider prefixes like "US-P|", "US: ", "UK- ", "CA-", "MX-"
    var s = name.replaceAll(RegExp(r'^[A-Z]{2}[\s:-]*[A-Z]*\|'), '');
    s = s.replaceAll(
      RegExp(r'^(US|UK|CA|MX)[\s:-]+', caseSensitive: false),
      '',
    );
    // Strip bracketed tags [US], [SP], [H]
    s = s.replaceAll(RegExp(r'\[.*?\]'), '');
    // Strip quality tags
    s = s.replaceAll(
      RegExp(r'\b(HD|FHD|SHD|SD|4K|UHD)\b', caseSensitive: false),
      '',
    );
    // Strip common location names
    s = s.replaceAll(
      RegExp(
        r'\b(New York|Los Angeles|Chicago|Houston|Phoenix|Philadelphia|San Antonio|San Diego|Dallas|San Jose|Austin|Jacksonville|Fort Worth|Columbus|Charlotte|Indianapolis|San Francisco|Seattle|Denver|Washington|Nashville|Oklahoma City|El Paso|Boston|Portland|Las Vegas|Memphis|Louisville|Baltimore|Milwaukee|Albuquerque|Tucson|Fresno|Mesa|Sacramento|Atlanta|Kansas City|Colorado Springs|Omaha|Raleigh|Long Beach|Virginia Beach|Miami|Oakland|Minneapolis|Tampa|Tulsa|Arlington|New Orleans|Cleveland|Orlando|Cincinnati|Pittsburgh|Detroit|St\.? Louis)\b',
        caseSensitive: false,
      ),
      '',
    );
    s = s.trim();
    // Try to find a broadcast call sign: W or K followed by 2-3 letters
    final csMatch = RegExp(
      r'\b([WK][A-Z]{2,3})\b',
      caseSensitive: false,
    ).firstMatch(s);
    if (csMatch != null) {
      final cs = csMatch.group(1)!.toUpperCase();
      // Validate it looks like a real call sign (not a common word)
      if (cs.length >= 3 && cs.length <= 4) return cs;
    }
    // No call sign found — return cleaned name lowercase (sorts after uppercase)
    return s.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ').trim().toLowerCase();
  }

  static String _normalizeName(String name) {
    return name
        .toLowerCase()
        .replaceAll(
          RegExp(r'\b(hd|fhd|shd|sd|4k|uhd)\b', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'(us-?[a-z]*\|?|uk-?[a-z]*\|?|ca-?[a-z]*\|?|mx-?[a-z]*\|?)'),
          '',
        )
        .replaceAll(RegExp(r'[\s|()[\]]+'), ' ')
        .trim();
  }

  /// Invisible / zero-width characters that can differ between how a playlist
  /// is saved on one platform vs another (BOM, zero-width spaces, NBSP) and
  /// silently break exact-string EPG id matching.
  static final _epgInvisibleChars = RegExp(
    r'[\u200B\u200C\u200D\u200E\u200F\uFEFF\u00A0]',
  );

  /// Canonical key for exact tvg-id / tvg-name ↔ XMLTV channel-id matching:
  /// lowercased, invisible chars stripped, trimmed. Applied on BOTH sides so a
  /// stray BOM/zero-width/NBSP (e.g. from a differently-saved playlist) can't
  /// make an otherwise-identical id fail to match on one platform.
  static String _epgIdKey(String s) =>
      s.toLowerCase().replaceAll(_epgInvisibleChars, '').trim();

  /// Normalize a channel/EPG display name for fuzzy EPG matching.
  /// Strips country tags, quality tags, provider prefixes, call signs in parens.
  static String _normalizeForEpgMatch(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'\[.*?\]'), '') // [US], [SP], [H]
        .replaceAll(RegExp(r'\(.*?\)'), '') // (WABC), (S)
        .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd|us|uk|ca|mx)\b'), '')
        .replaceAll(RegExp(r'us-?[a-z]*\|'), '') // US-P| prefix
        .replaceAll(
          RegExp(r'[^\p{L}\p{N}]+', unicode: true),
          ' ',
        ) // keep all letters (incl. CJK) + digits
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Extract a broadcast call sign (3-4 uppercase letters starting with W or K)
  /// from a channel name. Checks parenthesized call signs like (WABC) first,
  /// then tvgId patterns, then words in the name.
  static final _callSignInParens = RegExp(r'\(([WK][A-Z]{2,3})\)');
  static final _callSignInTvgId = RegExp(
    r'[.\-_]([wk][a-z]{2,3})(?:[.\-_]|$)',
    caseSensitive: false,
  );
  static final _callSignWord = RegExp(r'\b([WK][A-Z]{2,3})\b');

  static String? _extractCallSign(String name, String? tvgId) {
    // 1. Check parenthesized call sign: (WABC)
    final parenMatch = _callSignInParens.firstMatch(name);
    if (parenMatch != null) return parenMatch.group(1)!.toUpperCase();
    // 2. Check tvgId for embedded call sign: abcwabc.us, ABC.(WABC).New.York
    if (tvgId != null && tvgId.isNotEmpty) {
      final tvgMatch = _callSignInTvgId.firstMatch(tvgId);
      if (tvgMatch != null) return tvgMatch.group(1)!.toUpperCase();
      // Also try last segment before .us: e.g. "cbs2wcbs.us" → extract WCBS
      final dotParts = tvgId
          .replaceAll(RegExp(r'\.us$', caseSensitive: false), '')
          .split('.');
      for (final part in dotParts) {
        final m = RegExp(
          r'([wk][a-z]{2,3})$',
          caseSensitive: false,
        ).firstMatch(part);
        if (m != null) return m.group(1)!.toUpperCase();
      }
    }
    // 3. Check name for standalone call sign word
    final wordMatch = _callSignWord.firstMatch(
      name.replaceAll(RegExp(r'\(.*?\)'), ''),
    );
    if (wordMatch != null) return wordMatch.group(1)!.toUpperCase();
    return null;
  }

  /// Clear the search bar and re-apply filters.
  void _clearSearch() {
    if (_searchQuery.isEmpty) return;
    // Save non-empty query to history before clearing
    _addSearchHistory(_searchQuery);
    _searchQuery = '';
    _searchController.clear();
    _applyFilters();
  }

  /// Add a query to search history (persisted via SharedPreferences).
  void _addSearchHistory(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _searchHistory.remove(trimmed);
    _searchHistory.insert(0, trimmed);
    if (_searchHistory.length > _kMaxSearchHistory) {
      _searchHistory = _searchHistory.sublist(0, _kMaxSearchHistory);
    }
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList(_kSearchHistory, _searchHistory);
    });
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory = prefs.getStringList(_kSearchHistory) ?? [];
  }

  /// Add default EPG sources on first run and kick off a background refresh.
  Future<void> _ensureEpgSources() async {
    final epgService = ref.read(epgRefreshServiceProvider);
    await epgService.addDefaultSources();
    // Refresh EPG in background after a delay so UI loads first
    Future.delayed(const Duration(seconds: 10), () {
      if (!mounted) return;
      epgService.refreshAllSources().catchError((e) {
        debugPrint('[EPG] Background refresh failed: $e');
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _sidebarSearchController.dispose();
    _sidebarFocusNode.dispose();
    _sidebarAllItemFocusNode.dispose();
    _firstChannelFocusNode.dispose();
    _channelListController.dispose();
    _guideScrollController.dispose();
    _guideIdleTimer?.cancel();
    _searchDebounce?.cancel();
    _nowPlayingTimer?.cancel();
    _volumeOverlayTimer?.cancel();
    _previewControlsTimer?.cancel();
    _providersSub?.cancel();
    _channelsSub?.cancel();
    _longPressTimer?.cancel();
    _epgReindexTimer?.cancel();
    _logoResolveTimer?.cancel();
    _nowPlayingDebounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadChannels() async {
    final database = ref.read(databaseProvider);
    final isFirstLoad = _allChannels.isEmpty;

    // ── Micro-phase 1: providers + favIds (tiny queries) ──
    if (mounted) setState(() => _loadStatus = 'Loading providers…');
    final results = await Future.wait([
      database.getAllProviders(),
      database.getAllFavoriteLists(),
      database.getAllFavoritedChannelIds(),
      SharedPreferences.getInstance(),
    ]);
    final providers = results[0] as List<db.Provider>;
    final favLists = results[1] as List<db.FavoriteList>;
    final favChannelIds = results[2] as Set<String>;
    final prefs = results[3] as SharedPreferences;

    // Vanity names (sync parse from already-loaded prefs)
    final vanityJson = prefs.getString('channel_vanity_names');
    if (vanityJson != null) {
      try {
        final decoded = jsonDecode(vanityJson) as Map<String, dynamic>;
        _vanityNames = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (e) {
        debugPrint('[Channels] Failed to parse vanity names: $e');
      }
    }

    // ── Micro-phase 2: favorite channels (direct ID query, ~18 rows) ──
    if (mounted)
      setState(
        () => _loadStatus = 'Loading ${favChannelIds.length} favorites…',
      );
    List<db.Channel> favChannels = [];
    if (favChannelIds.isNotEmpty) {
      favChannels = await database.getChannelsByIds(favChannelIds);
    }

    if (!mounted) return;
    if (mounted)
      setState(
        () => _loadStatus =
            'Found ${providers.length} providers, ${favChannels.length} favorites',
      );
    // FIRST RENDER — user sees Favorites immediately
    setState(() {
      _initialLoadDone = true;
      _allChannels = favChannels;
      _providers = providers;
      _favoriteLists = favLists;
      _favoritedChannelIds = favChannelIds;
      _selectedGroup = 'Favorites';
      _applyFilters();
    });
    if (isFirstLoad) _restoreSession();

    // ── Background: sidebar groups + failover groups (non-blocking) ──
    if (mounted) setState(() => _loadStatus = 'Loading Smart Channel groups…');
    final bgResults = await Future.wait([
      database.getProviderGroups(),
      database.getAllFailoverGroups(),
    ]);
    final pGroups = bgResults[0] as Map<String, List<String>>;
    final foGroups = bgResults[1] as List<db.FailoverGroup>;
    final allGroupNames = <String>{};
    for (final gl in pGroups.values) allGroupNames.addAll(gl);

    final foGroupMembers = <int, List<String>>{};
    for (final g in foGroups) {
      final members = await database.getFailoverGroupMembers(g.id);
      foGroupMembers[g.id] = members.map((m) => m.channelId).toList();
    }

    if (!mounted) return;
    setState(() {
      _providerGroups = pGroups;
      _groups = allGroupNames.toList();
      _failoverGroups = foGroups;
      _failoverGroupMembers = foGroupMembers;
      _applyFilters(); // Re-filter to hide grouped channels
    });

    // ── Background: EPG for favorites ──
    setState(() => _epgLoading = true);
    await _loadEpgData(database, favChannels, favChannelIds);
    if (mounted) setState(() => _epgLoading = false);

    // ── Background: load all provider channels incrementally ──
    // ── Background: load all provider channels in one batch ──
    final allNewChannels = <db.Channel>[];
    final existingIds = _allChannels.map((c) => c.id).toSet();
    for (final provider in providers) {
      if (!mounted) return;
      final channels = await database.getChannelsForProvider(provider.id);
      if (!mounted) return;
      final newChannels = channels
          .where((c) => !existingIds.contains(c.id))
          .toList();
      for (final c in newChannels) {
        existingIds.add(c.id);
      }
      allNewChannels.addAll(newChannels);
      _loadedProviders.add(provider.id);
    }
    if (!mounted) return;
    // Single setState for all providers
    setState(() {
      _allChannels = [..._allChannels, ...allNewChannels];
      _applyFilters();
    });

    // Re-index EPG with full channel set
    if (mounted) _loadEpgData(database, _allChannels, favChannelIds);
  }

  /// On-demand: load a single provider's channels into _allChannels.
  Future<void> _loadProviderChannels(String providerId) async {
    if (_loadedProviders.contains(providerId)) return;
    final database = ref.read(databaseProvider);
    final channels = await database.getChannelsForProvider(providerId);
    if (!mounted) return;
    _loadedProviders.add(providerId);
    final existingIds = _allChannels.map((c) => c.id).toSet();
    final newChannels = channels
        .where((c) => !existingIds.contains(c.id))
        .toList();
    setState(() {
      _allChannels = [..._allChannels, ...newChannels];
      _applyFilters();
    });
  }

  /// Reactively apply a full channels snapshot from the DB watch stream.
  ///
  /// This is authoritative: [_allChannels] is replaced wholesale with the
  /// snapshot rather than appended to, so a refresh that changes one provider
  /// can never duplicate or double the in-memory list. The current group
  /// selection and highlighted channel are preserved so refreshing one list
  /// doesn't disturb the rest of the UI.
  void _onChannelsSnapshot(List<db.Channel> all) {
    if (!mounted || !_initialLoadDone) return;

    // Cheap O(n) signature over id + name + group. If unchanged, this emission
    // only touched cosmetic columns (e.g. logos) — skip the heavy group
    // rebuild and EPG re-index, just refresh the in-memory list so new logos
    // show. This prevents the logo-resolver's batched writes from re-triggering
    // expensive recomputation on every batch and freezing the UI.
    final sig = _channelStructureSignature_(all);
    final structureChanged = sig != _channelStructureSignature;
    _channelStructureSignature = sig;

    // Preserve the currently selected channel across the rebuild.
    final selectedId =
        (_selectedIndex >= 0 && _selectedIndex < _filteredChannels.length)
        ? _filteredChannels[_selectedIndex].id
        : null;

    if (!structureChanged) {
      setState(() {
        _allChannels = all;
        _applyFilters();
        if (selectedId != null) {
          final idx = _filteredChannels.indexWhere((c) => c.id == selectedId);
          if (idx >= 0) _selectedIndex = idx;
        }
      });
      return;
    }

    // Structural change: rebuild provider → ordered group names. Order groups
    // by their first appearance (min sortOrder) without sorting every channel.
    final minOrder = <String, Map<String, int>>{};
    for (final c in all) {
      final g = c.groupTitle ?? '';
      if (g.isEmpty) continue;
      final m = minOrder[c.providerId] ??= <String, int>{};
      final cur = m[g];
      if (cur == null || c.sortOrder < cur) m[g] = c.sortOrder;
    }
    final pGroups = <String, List<String>>{};
    minOrder.forEach((pid, gm) {
      final entries = gm.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      pGroups[pid] = [for (final e in entries) e.key];
    });
    final allGroupNames = <String>{};
    for (final gl in pGroups.values) {
      allGroupNames.addAll(gl);
    }

    setState(() {
      _allChannels = all;
      _providerGroups = pGroups;
      _groups = allGroupNames.toList();
      // We now hold every provider's channels in memory.
      _loadedProviders
        ..clear()
        ..addAll(_providers.map((p) => p.id));
      _applyFilters();
      if (selectedId != null) {
        final idx = _filteredChannels.indexWhere((c) => c.id == selectedId);
        if (idx >= 0) _selectedIndex = idx;
      }
    });

    // Re-index EPG / now-playing — heavy, so debounce it so a burst of
    // structural writes only triggers one pass once the list settles.
    _epgReindexTimer?.cancel();
    _epgReindexTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      final database = ref.read(databaseProvider);
      _loadEpgData(database, _allChannels, _favoritedChannelIds);
    });

    // Lazily resolve missing logos after the list settles. Decoupled from the
    // M3U refresh so importing channels stays fast; logos fill in afterward.
    _logoResolveTimer?.cancel();
    _logoResolveTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      ref.read(providerManagerProvider).resolveAllMissingLogos().catchError(
        (_) {},
      );
    });
  }

  /// Cheap structural fingerprint of the channel set (id + name + group).
  /// Changes only when channels are added/removed/renamed/regrouped, not when
  /// cosmetic columns like logos are updated.
  String _channelStructureSignature_(List<db.Channel> all) {
    var h = all.length;
    for (final c in all) {
      h = 0x1fffffff & (h * 31 + c.id.hashCode);
      h = 0x1fffffff & (h * 31 + c.name.hashCode);
      h = 0x1fffffff & (h * 31 + (c.groupTitle?.hashCode ?? 0));
    }
    return '$h:${all.length}';
  }

  /// Reactively apply a providers snapshot (add / edit / delete / rename).
  /// Lightweight: updates the provider list and re-applies filters without
  /// reloading channels (channel changes arrive via [_onChannelsSnapshot]).
  void _onProvidersSnapshot(List<db.Provider> providers) {
    if (!mounted || !_initialLoadDone) return;
    setState(() {
      _providers = providers;
      _applyFilters();
    });
  }

  /// Loads EPG sources, mappings, and now-playing data in the background.
  /// Updates state incrementally so the UI is never blocked.
  Future<void> _loadEpgData(
    db.AppDatabase database,
    List<db.Channel> allChannels,
    Set<String> favChannelIds,
  ) async {
    // EPG is being (re)loaded — drop cached programme futures so the guide
    // re-fetches fresh data after an import/refresh.
    _programmeFutureCache.clear();

    final epgSources = await database.getAllEpgSources();
    final currentSourceIds = epgSources.map((s) => s.id).toSet();
    final validIds = <String>{};
    final rawToPrefixed = <String, String>{};
    final epgNameToId = <String, String>{};
    final epgCallSignToId = <String, String>{}; // WABC → prefixed id
    for (final src in epgSources) {
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        validIds.add(ch.id);
        rawToPrefixed[_epgIdKey(ch.channelId)] = ch.id;
        final normName = _normalizeForEpgMatch(ch.displayName);
        if (normName.isNotEmpty) epgNameToId[normName] = ch.id;
        // Index by call sign extracted from channelId (e.g. WABC.us → WABC)
        final rawUpper = ch.channelId.toUpperCase();
        final csMatch = RegExp(r'^([WK][A-Z]{2,3})\.').firstMatch(rawUpper);
        if (csMatch != null) {
          epgCallSignToId.putIfAbsent(csMatch.group(1)!, () => ch.id);
        }
        // Also index from local station IDs like abc.ny.newyork.wabc
        final dotParts = ch.channelId.split('.');
        if (dotParts.length >= 4) {
          final lastPart = dotParts.last.toUpperCase();
          if (RegExp(r'^[WK][A-Z]{2,3}$').hasMatch(lastPart)) {
            epgCallSignToId.putIfAbsent(lastPart, () => ch.id);
          }
        }
      }
    }

    final mappings = await database.getAllMappings();
    final epgMap = <String, String>{};
    for (final m in mappings) {
      final directKey = '${m.epgSourceId}_${m.epgChannelId}';
      if (currentSourceIds.contains(m.epgSourceId)) {
        epgMap[m.channelId] = directKey;
      } else {
        for (final srcId in currentSourceIds) {
          final candidate = '${srcId}_${m.epgChannelId}';
          if (validIds.contains(candidate)) {
            epgMap[m.channelId] = candidate;
            break;
          }
        }
      }
    }

    // Build failover name index + EPG scope
    final normNameIndex = <String, List<String>>{};
    for (final c in allChannels) {
      final norm = _normalizeName(c.name);
      (normNameIndex[norm] ??= []).add(c.id);
    }
    final epgScopeIds = <String>{...favChannelIds};
    final favChannels = allChannels.where((c) => favChannelIds.contains(c.id));
    for (final fav in favChannels) {
      final normName = _normalizeName(fav.name);
      final alts = normNameIndex[normName];
      if (alts != null) epgScopeIds.addAll(alts);
    }

    // Collect EPG channel IDs for now-playing lookup
    final epgChannelIds = <String>{};
    for (final c in allChannels) {
      if (!epgScopeIds.contains(c.id)) continue;
      final mapped = epgMap[c.id];
      if (mapped != null && mapped.isNotEmpty) {
        epgChannelIds.add(mapped);
        continue;
      }
      // tvg-name first (preferred when present), then tvg-id.
      if (c.tvgName != null && c.tvgName!.isNotEmpty) {
        final prefixed = rawToPrefixed[_epgIdKey(c.tvgName!)];
        if (prefixed != null) { epgChannelIds.add(prefixed); continue; }
      }
      if (c.tvgId != null && c.tvgId!.isNotEmpty) {
        final prefixed = rawToPrefixed[_epgIdKey(c.tvgId!)];
        if (prefixed != null) { epgChannelIds.add(prefixed); continue; }
      }
      // Fallback: match by normalized channel name
      final normName = _normalizeForEpgMatch(c.name);
      if (normName.isNotEmpty) {
        final byName = epgNameToId[normName];
        if (byName != null) { epgChannelIds.add(byName); continue; }
      }
      // Fallback: match by call sign (WABC, WCBS, WNYW)
      final callSign = _extractCallSign(c.name, c.tvgId);
      if (callSign != null) {
        final byCs = epgCallSignToId[callSign];
        if (byCs != null) epgChannelIds.add(byCs);
      }
    }
    List<db.EpgProgramme> nowPlaying = [];
    if (epgChannelIds.isNotEmpty) {
      nowPlaying = await database.getNowPlaying(epgChannelIds.toList());
    }

    if (!mounted) return;
    setState(() {
      _nowPlaying = nowPlaying;
      _epgMappings = epgMap;
      _rawToPrefixedEpg = rawToPrefixed;
      _epgNameToId = epgNameToId;
      _epgCallSignToId = epgCallSignToId;
    });
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _use24HourTime = prefs.getBool(_kUse24HourTime) ?? false;

    // Restore EPG timeshifts
    final tsJson = prefs.getString(_kEpgTimeshifts);
    if (tsJson != null) {
      try {
        final decoded = jsonDecode(tsJson) as Map<String, dynamic>;
        _epgTimeshifts.clear();
        decoded.forEach((k, v) => _epgTimeshifts[k] = v as int);
      } catch (e) {
        debugPrint('[Channels] Failed to parse EPG timeshifts: $e');
      }
    }
    final lastGroup = prefs.getString(_kLastGroup);
    final lastChannelId = prefs.getString(_kLastChannelId);

    if (lastGroup != null && lastGroup != _selectedGroup) {
      setState(() {
        _selectedGroup = lastGroup;
        _applyFilters();
      });
    }

    if (lastChannelId != null && _filteredChannels.isNotEmpty) {
      final idx = _filteredChannels.indexWhere((c) => c.id == lastChannelId);
      if (idx >= 0) {
        _selectChannel(idx);
      }
    }

    // Refresh EPG now-playing after restoring timeshifts and group
    _refreshNowPlaying();
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastGroup, _selectedGroup);
    if (_selectedIndex >= 0 && _selectedIndex < _filteredChannels.length) {
      await prefs.setString(
        _kLastChannelId,
        _filteredChannels[_selectedIndex].id,
      );
    }
  }

  void _applyFilters() {
    var channels = _allChannels;

    // When sidebar search is active, search ALL channels regardless of group
    if (_sidebarSearchQuery.isNotEmpty) {
      final terms = _sidebarSearchQuery
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      channels = channels.where((c) {
        final nowPlaying = _getChannelNowPlaying(c) ?? '';
        final haystack = '${c.name} ${c.groupTitle ?? ''} $nowPlaying'
            .toLowerCase();
        return terms.every((t) => haystack.contains(t));
      }).toList();
    } else {
      // Group filters only apply when not searching
      if (_selectedGroup == 'Favorites') {
        channels =
            channels.where((c) => _favoritedChannelIds.contains(c.id)).toList()
              ..sort(
                (a, b) => _callSignSortKey(
                  _channelDisplayName(a),
                ).compareTo(_callSignSortKey(_channelDisplayName(b))),
              );
      } else if (_selectedGroup.startsWith('fav:')) {
        final listId = _selectedGroup.substring(4);
        _applyFavoriteListFilter(listId);
        return;
      } else if (_selectedGroup.startsWith('provider:')) {
        final providerId = _selectedGroup.substring(9);
        if (!_loadedProviders.contains(providerId)) {
          _loadProviderChannels(providerId);
          _filteredChannels = [];
          return;
        }
        channels = channels.where((c) => c.providerId == providerId).toList();
      } else if (_selectedGroup.startsWith('provgroup:')) {
        // Format: provgroup:{providerId}:{groupTitle}
        final parts = _selectedGroup.substring(10);
        final sepIdx = parts.indexOf(':');
        if (sepIdx > 0) {
          final providerId = parts.substring(0, sepIdx);
          final groupTitle = parts.substring(sepIdx + 1);
          if (!_loadedProviders.contains(providerId)) {
            _loadProviderChannels(providerId);
            _filteredChannels = [];
            return;
          }
          channels = channels
              .where(
                (c) => c.providerId == providerId && c.groupTitle == groupTitle,
              )
              .toList();
        }
      } else if (_selectedGroup != 'All') {
        channels = channels
            .where((c) => c.groupTitle == _selectedGroup)
            .toList();
      }
    }

    // Top-bar search: when active, search ALL channels across ALL providers
    // regardless of group selection. Single-pass haystack for speed.
    if (_searchQuery.isNotEmpty) {
      final tokens = _searchQuery
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.isNotEmpty) {
        channels = _allChannels.where((c) {
          final haystack =
              '${c.name}\x00${_vanityNames[c.id] ?? ''}\x00${c.groupTitle ?? ''}\x00${c.tvgId ?? ''}'
                  .toLowerCase();
          return tokens.every((t) => haystack.contains(t));
        }).toList();
      }
    }

    // Hide channels that belong to a failover group — group rows replace them
    if (_failoverGroupMembers.isNotEmpty) {
      final grouped = <String>{};
      for (final ids in _failoverGroupMembers.values) {
        grouped.addAll(ids);
      }
      channels = channels.where((c) => !grouped.contains(c.id)).toList();
    }

    _filteredChannels = channels;
    if (_selectedIndex >= _filteredChannels.length) {
      _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
    }
    // The visible list changed (group/search switch) → refresh now-playing for
    // it right away instead of waiting for the 60s timer. Debounced so rapid
    // changes only fire one DB query once the list settles.
    _scheduleNowPlayingRefresh();
  }

  /// Debounced now-playing refresh for the current visible list.
  void _scheduleNowPlayingRefresh() {
    _nowPlayingDebounce?.cancel();
    _nowPlayingDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _refreshNowPlaying();
    });
  }

  Future<void> _applyFavoriteListFilter(String listId) async {
    final database = ref.read(databaseProvider);
    var channels = await database.getChannelsInList(listId);
    if (_searchQuery.isNotEmpty) {
      final tokens = _searchQuery
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.isNotEmpty) {
        // Search ALL channels, not just favorites
        channels = _allChannels.where((c) {
          final haystack =
              '${c.name}\x00${_vanityNames[c.id] ?? ''}\x00${c.groupTitle ?? ''}\x00${c.tvgId ?? ''}'
                  .toLowerCase();
          return tokens.every((t) => haystack.contains(t));
        }).toList();
      }
    }
    if (_sidebarSearchQuery.isNotEmpty) {
      channels = channels.where((c) {
        final q = _sidebarSearchQuery;
        return c.name.toLowerCase().contains(q) ||
            (_vanityNames[c.id]?.toLowerCase().contains(q) ?? false);
      }).toList();
    }
    channels.sort(
      (a, b) => _callSignSortKey(
        _channelDisplayName(a),
      ).compareTo(_callSignSortKey(_channelDisplayName(b))),
    );
    if (!mounted) return;
    setState(() {
      _filteredChannels = channels;
      if (_selectedIndex >= _filteredChannels.length) {
        _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
      }
    });
    // Ensure EPG data is loaded for the favorite list channels
    _refreshNowPlaying();
  }

  void _selectChannel(int index) {
    if (index < 0 || index >= _filteredChannels.length) return;
    final channel = _filteredChannels[index];
    final playerService = ref.read(playerServiceProvider);
    // Skip only if this exact channel is already playing — otherwise always
    // (re)load. This lets the pre-selected first channel play on first click,
    // and lets a single-channel group be played at all.
    if (playerService.currentChannelId == channel.id) {
      if (_selectedIndex != index) {
        setState(() {
          _selectedIndex = index;
          _previewChannel = channel;
        });
      }
      return;
    }
    // Remember current as previous (for back/forth toggle)
    if (_selectedIndex >= 0 && _selectedIndex != index) {
      _previousIndex = _selectedIndex;
    }

    playerService.play(
      channel.streamUrl,
      channelId: channel.id,
      epgChannelId: _getEpgId(channel),
      tvgId: channel.tvgId,
      channelName: channel.name,
      vanityName: _vanityNames[channel.id],
      originalName: channel.tvgName,
    );
    setState(() {
      _selectedIndex = index;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, index);
    _saveSession();
  }

  /// Toggle between current channel and the last channel.
  void _goBackChannel() {
    if (_previousIndex < 0 || _previousIndex >= _filteredChannels.length)
      return;
    final swapTo = _previousIndex;
    _previousIndex = _selectedIndex;
    final channel = _filteredChannels[swapTo];
    final playerService = ref.read(playerServiceProvider);
    playerService.play(
      channel.streamUrl,
      channelId: channel.id,
      epgChannelId: _getEpgId(channel),
      tvgId: channel.tvgId,
      channelName: channel.name,
      vanityName: _vanityNames[channel.id],
      originalName: channel.tvgName,
    );
    setState(() {
      _selectedIndex = swapTo;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, swapTo);
  }

  /// Selecting a channel updates the preview; the old auto-hiding info
  /// overlay was removed, so this is now a no-op kept for its call sites.
  void _showInfoOverlay(db.Channel channel, int index) {}

  Future<void> _goFullscreen(db.Channel channel) async {
    final channelMaps = _filteredChannels
        .map(
          (c) => <String, dynamic>{
            'id': c.id,
            'providerId': c.providerId,
            'name': _channelDisplayName(c),
            'originalName': c.name,
            'streamUrl': c.streamUrl,
            'tvgLogo': c.tvgLogo,
            'tvgId': c.tvgId,
            'tvgName': c.tvgName,
            'groupTitle': c.groupTitle,
            'streamType': c.streamType,
            'epgId': _getEpgId(c),
            'epgChannelId': _getEpgId(c),
            'vanityName': _vanityNames[c.id],
            'alternativeUrls': <String>[],
          },
        )
        .toList();
    await context.push(
      '/player',
      extra: {
        'streamUrl': channel.streamUrl,
        'channelName': _channelDisplayName(channel),
        'channelLogo': channel.tvgLogo,
        'alternativeUrls': <String>[],
        'channels': channelMaps,
        'currentIndex': _selectedIndex >= 0 ? _selectedIndex : 0,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // EPG helpers
  // ---------------------------------------------------------------------------

  /// Get the effective EPG channel ID. Priority: manual mapping, then tvg-name
  /// (preferred when present), then tvg-id, both matched against the XMLTV
  /// channel id; finally normalized-name and call-sign fallbacks.
  String? _getEpgId(db.Channel channel) {
    final mapped = _epgMappings[channel.id];
    if (mapped != null && mapped.isNotEmpty) return mapped;

    // 1. tvg-name → XMLTV channel id (use tvg-name first when it's set).
    if (channel.tvgName != null && channel.tvgName!.isNotEmpty) {
      final prefixed = _rawToPrefixedEpg[_epgIdKey(channel.tvgName!)];
      if (prefixed != null) return prefixed;
    }
    // 2. tvg-id → XMLTV channel id (fallback when tvg-name is empty/unmatched).
    if (channel.tvgId != null && channel.tvgId!.isNotEmpty) {
      final prefixed = _rawToPrefixedEpg[_epgIdKey(channel.tvgId!)];
      if (prefixed != null) return prefixed;
    }
    // 3. Fallback: normalized channel name against EPG display names.
    final normName = _normalizeForEpgMatch(channel.name);
    if (normName.isNotEmpty) {
      final byName = _epgNameToId[normName];
      if (byName != null) return byName;
    }
    // 4. Fallback: broadcast call sign (WABC, WCBS, etc.).
    final callSign = _extractCallSign(channel.name, channel.tvgId);
    if (callSign != null) {
      final byCs = _epgCallSignToId[callSign];
      if (byCs != null) return byCs;
    }
    return null;
  }

  String _getProviderName(String providerId) {
    for (final p in _providers) {
      if (p.id == providerId) return p.name;
    }
    return '';
  }

  String? _getChannelNowPlaying(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final match = _nowPlaying.where((p) => p.epgChannelId == epgId).toList();
    return match.isNotEmpty ? match.first.title : null;
  }

  /// Display name for a channel — vanity name if set, otherwise original name.
  String _channelDisplayName(db.Channel channel) =>
      _vanityNames[channel.id] ?? channel.name;

  /// Get failover alternative details for a channel (for debug dialog).
  List<AlternativeDetail> _getFailoverAlts(db.Channel channel) {
    try {
      return ref
          .read(streamAlternativesProvider)
          .getAlternativeDetails(
            channelId: channel.id,
            epgChannelId: _getEpgId(channel),
            tvgId: channel.tvgId,
            channelName: channel.name,
            vanityName: _vanityNames[channel.id],
            originalName: channel.tvgName,
            excludeUrl: channel.streamUrl,
          );
    } catch (_) {
      return [];
    }
  }

  db.EpgProgramme? _getEpgProgramme(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final shift = _epgTimeshifts[channel.id] ?? 0;
    final adjusted = DateTime.now().subtract(Duration(hours: shift));
    final matches = _nowPlaying.where((p) =>
        p.epgChannelId == epgId &&
        !p.start.isAfter(adjusted) &&
        p.stop.isAfter(adjusted)).toList();
    return matches.isNotEmpty ? matches.first : null;
  }

  db.EpgProgramme? _getNextProgramme(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final current = _getEpgProgramme(channel);
    if (current == null) return null;
    final matches = _nowPlaying.where((p) =>
        p.epgChannelId == epgId &&
        !p.start.isBefore(current.stop)).toList();
    matches.sort((a, b) => a.start.compareTo(b.start));
    return matches.isNotEmpty ? matches.first : null;
  }

  /// Progress fraction (0..1) into the current programme, honoring timeshift.
  double? _channelProgress(db.Channel channel) {
    final p = _getEpgProgramme(channel);
    if (p == null) return null;
    final shift = _epgTimeshifts[channel.id] ?? 0;
    final now = DateTime.now().subtract(Duration(hours: shift));
    final total = p.stop.difference(p.start).inSeconds;
    if (total <= 0) return null;
    final elapsed = now.difference(p.start).inSeconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  /// Mobile channel-tile EPG rows: now-playing title + progress bar + next.
  /// Returns [] when the channel has no EPG (or just a loading hint).
  List<Widget> _buildMobileEpgLines(db.Channel channel) {
    final current = _getEpgProgramme(channel);
    if (current == null) {
      if (_epgLoading) {
        return const [
          Text(
            'Loading guide…',
            style: TextStyle(
              color: Colors.white24,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ];
      }
      return const [];
    }
    final shift = _epgTimeshifts[channel.id] ?? 0;
    final progress = _channelProgress(channel);
    final next = _getNextProgramme(channel);
    return [
      const SizedBox(height: 3),
      Text(
        current.title,
        style: const TextStyle(
          color: Color(0xFF6C5CE7),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      if (progress != null) ...[
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 3,
            backgroundColor: Colors.white12,
            valueColor: const AlwaysStoppedAnimation(Color(0xFF6C5CE7)),
          ),
        ),
      ],
      if (next != null) ...[
        const SizedBox(height: 3),
        Text(
          '${_formatTime(next.start.add(Duration(hours: shift)))}  ${next.title}',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ];
  }

  /// Bottom sheet showing a channel's full vertical schedule (mobile).
  void _showChannelSchedule(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return;
    final database = ref.read(databaseProvider);
    final shift = _epgTimeshifts[channel.id] ?? 0;
    final now = DateTime.now();
    // EPG/source time window = wall window [now-6h, now+24h] minus the shift.
    final qStart = now.subtract(Duration(hours: 6 + shift));
    final qEnd = now.add(Duration(hours: 24 - shift));
    // One-time guard so the auto-scroll-to-now only fires on first data load
    // (FutureBuilder rebuilds would otherwise re-trigger it).
    var didScrollToNow = false;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF16213E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.92,
          builder: (ctx, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _channelDisplayName(channel),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, color: Colors.white12),
                Expanded(
                  child: FutureBuilder<List<db.EpgProgramme>>(
                    future: database.getProgrammes(
                      epgChannelId: epgId,
                      start: qStart,
                      end: qEnd,
                    ),
                    builder: (ctx, snap) {
                      if (!snap.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }
                      final progs = snap.data!;
                      if (progs.isEmpty) {
                        return const Center(
                          child: Text(
                            'No EPG data',
                            style: TextStyle(color: Colors.white38),
                          ),
                        );
                      }
                      final nowEpg = now.subtract(Duration(hours: shift));
                      const itemExtent = 48.0;
                      // Default view: put the current programme at the top
                      // (earlier programmes remain reachable by scrolling up).
                      final currentIndex = progs.indexWhere(
                        (p) =>
                            !p.start.isAfter(nowEpg) && p.stop.isAfter(nowEpg),
                      );
                      if (!didScrollToNow && currentIndex > 0) {
                        didScrollToNow = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (scrollController.hasClients) {
                            final target = (currentIndex * itemExtent).clamp(
                              0.0,
                              scrollController.position.maxScrollExtent,
                            );
                            scrollController.jumpTo(target);
                          }
                        });
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemExtent: itemExtent,
                        itemCount: progs.length,
                        itemBuilder: (ctx, i) {
                          final p = progs[i];
                          final isCurrent = !p.start.isAfter(nowEpg) &&
                              p.stop.isAfter(nowEpg);
                          final startLocal =
                              p.start.add(Duration(hours: shift));
                          return Container(
                            color: isCurrent
                                ? const Color(0xFF6C5CE7).withValues(alpha: 0.15)
                                : null,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 60,
                                  child: Text(
                                    _formatTime(startLocal),
                                    style: TextStyle(
                                      color: isCurrent
                                          ? const Color(0xFF6C5CE7)
                                          : Colors.white54,
                                      fontSize: 12,
                                      fontWeight: isCurrent
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    p.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isCurrent
                                          ? Colors.white
                                          : Colors.white70,
                                      fontSize: 13,
                                      fontWeight: isCurrent
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (isCurrent)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 8),
                                    child: Icon(
                                      Icons.play_arrow_rounded,
                                      color: Color(0xFF6C5CE7),
                                      size: 16,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    if (_use24HourTime) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  String? _programmeTimeRange(db.EpgProgramme? p, {int timeshiftHours = 0}) {
    if (p == null) return null;
    final shift = Duration(hours: timeshiftHours);
    return '${_formatTime(p.start.add(shift))} - ${_formatTime(p.stop.add(shift))}';
  }

  /// Parse XMLTV episode-num into readable label (e.g. "S2 E5").
  String? _parseEpisodeLabel(String? episodeNum) {
    if (episodeNum == null || episodeNum.isEmpty) return null;
    final se = _parseSeasonEpisode(episodeNum);
    if (se != null) return 'S${se.$1} E${se.$2}';
    return episodeNum;
  }

  /// Parse episode string into (season, episode) integers.
  (int, int)? _parseSeasonEpisode(String? episodeNum) {
    if (episodeNum == null || episodeNum.isEmpty) return null;
    final seFmt = RegExp(r'S(\d+)\s*E(\d+)', caseSensitive: false);
    final seMatch = seFmt.firstMatch(episodeNum);
    if (seMatch != null) {
      return (int.parse(seMatch.group(1)!), int.parse(seMatch.group(2)!));
    }
    final nsFmt = RegExp(r'^(\d+)\.(\d+)');
    final nsMatch = nsFmt.firstMatch(episodeNum);
    if (nsMatch != null) {
      return (
        int.parse(nsMatch.group(1)!) + 1,
        int.parse(nsMatch.group(2)!) + 1,
      );
    }
    return null;
  }

  /// Build IMDB URL — exact if IMDB ID cached, otherwise search fallback.
  String _imdbUrl(String title, String? episodeNum) {
    final imdbId = _imdbIdCache[title.toLowerCase()];
    if (imdbId != null) {
      final se = _parseSeasonEpisode(episodeNum);
      if (se != null) {
        return 'https://www.imdb.com/title/$imdbId/episodes/?season=${se.$1}';
      }
      return 'https://www.imdb.com/title/$imdbId/';
    }
    return 'https://www.imdb.com/find/?q=${Uri.encodeComponent(title)}&s=tt&ttype=tv';
  }

  /// Resolve IMDB ID for a show via TMDB (cached, background).
  Future<void> _resolveImdbId(String title) async {
    final key = title.toLowerCase();
    if (_imdbIdCache.containsKey(key)) return;
    _imdbIdCache[key] = null; // mark in-progress
    try {
      final keys = ref.read(showsApiKeysProvider);
      if (!keys.hasTmdbKey) return;
      final tmdb = TmdbClient(apiKey: keys.tmdbApiKey);
      final results = await tmdb.searchTv(title);
      if (results.isEmpty) return;
      final detail = await tmdb.getTvShow(results.first.id);
      if (detail.imdbId != null && detail.imdbId!.isNotEmpty) {
        _imdbIdCache[key] = detail.imdbId;
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('[Channels] IMDB id resolution failed for "$title": $e');
    }
  }

  void _resetGuideIdleTimer(DateTime dayStart) {
    _guideIdleTimer?.cancel();
    _guideIdleTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_guideScrollController.hasClients) return;
      final now = DateTime.now();
      // Return to the default view: ~30 minutes before "now" at the left edge.
      final targetMin = now.difference(dayStart).inMinutes - 30;
      final target = (targetMin * _pixelsPerMinute).clamp(
        0.0,
        _guideScrollController.position.maxScrollExtent,
      );
      _guideScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Keyboard navigation
  // ---------------------------------------------------------------------------

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    // On Android/TV, arrow keys are used for D-pad focus navigation.
    // Channel switching uses dedicated channelUp/channelDown keys.
    final isAndroid = Platform.isAndroid;

    // Open debug info dialog with 'D' key
    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.keyD) {
      if (_previewChannel != null) {
        final ps = ref.read(playerServiceProvider);
        final alts = _getFailoverAlts(_previewChannel!);
        ChannelDebugDialog.show(
          context,
          _previewChannel!,
          ps,
          mappedEpgId: _getEpgId(_previewChannel!),
          originalName: _previewChannel!.tvgName ?? _previewChannel!.name,
          currentProviderName: ref
              .read(streamAlternativesProvider)
              .providerName(_previewChannel!.providerId),
          alternatives: alts,
        );
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.channelUp ||
        (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      final newIndex = (_selectedIndex - 1).clamp(
        0,
        _filteredChannels.length - 1,
      );
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.channelDown ||
        (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      final newIndex = (_selectedIndex + 1).clamp(
        0,
        _filteredChannels.length - 1,
      );
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select) {
      if (_previewChannel != null) {
        _goFullscreen(_previewChannel!);
      }
      return KeyEventResult.handled;
    }

    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }

    // Backspace → go back in channel history
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _goBackChannel();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _scrollToIndex(int index) {
    // Approximate item height of ~52px
    final offset = (index * 52.0).clamp(
      0.0,
      _channelListController.position.maxScrollExtent,
    );
    _channelListController.animateTo(
      offset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _adjustVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 100.0);
      _showVolumeOverlay = true;
    });
    ref.read(playerServiceProvider).setVolume(_volume);
    _volumeOverlayTimer?.cancel();
    _volumeOverlayTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  /// Toggle the inline preview overlay (program info + play bar). Tapping the
  /// windowed player reveals it; it auto-hides after 3s of inactivity.
  void _togglePreviewControls() {
    setState(() => _showPreviewControls = !_showPreviewControls);
    if (_showPreviewControls) _scheduleHidePreviewControls();
  }

  /// (Re)start the 3-second auto-hide timer for the inline preview overlay.
  void _scheduleHidePreviewControls() {
    _previewControlsTimer?.cancel();
    _previewControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showPreviewControls = false);
    });
  }


  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_initialLoadDone) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A1A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/icon/clubtivi-icon.png',
                width: 80,
                height: 80,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.tv, size: 64, color: Color(0xFF6C5CE7)),
              ),
              const SizedBox(height: 12),
              const Text(
                'clubTivi',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF6C5CE7),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _loadStatus,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }
    if (_allChannels.isEmpty && _providers.isEmpty) {
      return _buildEmptyState(context);
    }

    return PopScope(
      canPop: false,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Focus(
          focusNode: _focusNode,
          autofocus: !Platform.isAndroid,
          skipTraversal: Platform.isAndroid,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (_searchFocusNode.hasFocus) return KeyEventResult.ignored;
            // Don't swallow keys when a dialog/overlay is open
            if (ModalRoute.of(context)?.isCurrent != true)
              return KeyEventResult.ignored;
            final key = event.logicalKey;
            // Let Flutter's spatial focus system handle D-pad arrows
            if (key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.arrowDown ||
                key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.arrowRight) {
              return KeyEventResult.ignored;
            }
            return _handleKeyEvent(event);
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF1A1A2E),
            body: SafeArea(
              child: Column(
                children: [
                  // Preview row at full width (player can extend left)
                  _buildPreviewRow(),
                  // Sidebar only next to the guide/channel list below
                  Expanded(
                    child: Row(
                      children: [
                        // Collapsible sidebar tree
                        _buildSidebar(),
                        // Main content area (guide / channel list)
                        Expanded(
                          child: Stack(
                            children: [
                              // Vertical list with inline now/next EPG on
                              // phone + desktop; horizontal timeline grid only
                              // on Android TV.
                              (_showGuideView && !_useMobileEpg)
                                  ? _buildGuideView()
                                  : _buildChannelList(),
                              if (_multiSelectMode)
                                Positioned(
                                  left: 8,
                                  right: 8,
                                  bottom: 8,
                                  child: _buildMultiSelectBar(),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (!Platform.isAndroid) _buildTopBar(context),
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.live_tv_rounded,
                      size: 64,
                      color: Colors.white24,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'No channels yet',
                      style: TextStyle(fontSize: 20, color: Colors.white54),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Add an IPTV provider to get started',
                      style: TextStyle(fontSize: 14, color: Colors.white38),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              autofocus: true,
              onPressed: () => context.push('/providers'),
              icon: const Icon(Icons.add),
              label: const Text('Add Provider'),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            'clubTivi',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: SizedBox(
              height: 36,
              child: RawAutocomplete<String>(
                textEditingController: _searchController,
                focusNode: _searchFocusNode,
                optionsBuilder: (textEditingValue) {
                  if (textEditingValue.text.isEmpty &&
                      _searchHistory.isNotEmpty) {
                    return _searchHistory;
                  }
                  if (_searchHistory.isEmpty)
                    return const Iterable<String>.empty();
                  final q = textEditingValue.text.toLowerCase();
                  return _searchHistory.where(
                    (h) => h.toLowerCase().contains(q),
                  );
                },
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) {
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search channels...',
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Colors.white12,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: Colors.white38,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    size: 18,
                                    color: Colors.white54,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _clearSearch();
                                    });
                                    _focusNode.requestFocus();
                                  },
                                )
                              : null,
                        ),
                        onChanged: (value) {
                          _searchDebounce?.cancel();
                          _searchQuery = value;
                          _searchDebounce = Timer(
                            const Duration(milliseconds: 400),
                            () {
                              if (mounted) setState(() => _applyFilters());
                            },
                          );
                        },
                        onSubmitted: (value) {
                          if (value.trim().isNotEmpty)
                            _addSearchHistory(value.trim());
                          _focusNode.requestFocus();
                        },
                      );
                    },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 8,
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 240,
                          maxWidth: 400,
                        ),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options.elementAt(index);
                            return ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.history,
                                size: 16,
                                color: Colors.white38,
                              ),
                              title: Text(
                                option,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  size: 14,
                                  color: Colors.white24,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _searchHistory.remove(option);
                                    SharedPreferences.getInstance().then((
                                      prefs,
                                    ) {
                                      prefs.setStringList(
                                        _kSearchHistory,
                                        _searchHistory,
                                      );
                                    });
                                  });
                                },
                              ),
                              onTap: () => onSelected(option),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (selection) {
                  _searchController.text = selection;
                  setState(() {
                    _searchQuery = selection;
                    _applyFilters();
                  });
                  _focusNode.requestFocus();
                },
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Previous channel toggle button
                  if (_previousIndex >= 0)
                    IconButton(
                      icon: const Icon(
                        Icons.swap_horiz_rounded,
                        color: Colors.white70,
                      ),
                      tooltip: 'Previous channel (Backspace)',
                      onPressed: _goBackChannel,
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.settings_rounded,
                      color: Colors.white70,
                    ),
                    tooltip: 'Settings',
                    onPressed: () => context.push('/settings'),
                  ),
                  // Cast icon removed — available in fullscreen player
                ],
              ),
            ),
          ),
          const Spacer(),
          const WeatherClockWidget(),
        ],
      ),
    );
  }

  /// Top section: video preview on left, programme + status info on right.
  Widget _buildPreviewRow() {
    final playerService = ref.watch(playerServiceProvider);
    final programme = _previewChannel != null
        ? _getEpgProgramme(_previewChannel!)
        : null;
    final nextProg = _previewChannel != null
        ? _getNextProgramme(_previewChannel!)
        : null;

    final isNarrow = MediaQuery.of(context).size.width < 600;

    if (isNarrow) {
      // Narrow screen (iOS portrait): video fills full width, height adapts to 16:9
      return Padding(
        padding: EdgeInsets.zero,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: _buildVideoContainer(playerService),
        ),
      );
    }

    return SizedBox(
      height: 200,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 356, child: _buildVideoContainer(playerService)),
            const SizedBox(width: 12),
            // Programme info + controls (right side)
            Expanded(
              child: _previewChannel == null
                  ? const SizedBox.shrink()
                  : Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16213E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top row: name+group left, badges+provider+time right
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _channelDisplayName(_previewChannel!),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (_previewChannel!.groupTitle != null &&
                                        _previewChannel!.groupTitle!.isNotEmpty)
                                      Text(
                                        _previewChannel!.groupTitle!,
                                        style: const TextStyle(
                                          color: Colors.white38,
                                          fontSize: 11,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              // Stream info badges + provider + time
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _StreamInfoBadges(
                                        playerService: playerService,
                                      ),
                                      if (_getProviderName(
                                        _previewChannel!.providerId,
                                      ).isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              0xFF6C5CE7,
                                            ).withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            _getProviderName(
                                              _previewChannel!.providerId,
                                            ),
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0xFF6C5CE7),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatTime(DateTime.now()),
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          // Now playing
                          if (programme != null) ...[
                            Row(
                              children: [
                                const Icon(
                                  Icons.play_circle_outline,
                                  size: 14,
                                  color: Colors.cyanAccent,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    programme.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              _programmeTimeRange(
                                    programme,
                                    timeshiftHours:
                                        _epgTimeshifts[_previewChannel!.id] ??
                                        0,
                                  ) ??
                                  '',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ],
                          if (programme != null &&
                              programme.description != null &&
                              programme.description!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                programme.description!,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          // Episode info + IMDB link
                          if (programme != null &&
                              programme.episodeNum != null &&
                              programme.episodeNum!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Builder(
                                builder: (_) {
                                  _resolveImdbId(programme.title);
                                  final hasExact =
                                      _imdbIdCache[programme.title
                                          .toLowerCase()] !=
                                      null;
                                  return GestureDetector(
                                    onTap: () => launchUrl(
                                      Uri.parse(
                                        _imdbUrl(
                                          programme.title,
                                          programme.episodeNum,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          _parseEpisodeLabel(
                                                programme.episodeNum,
                                              ) ??
                                              programme.episodeNum!,
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 11,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          hasExact ? 'IMDb ↗' : 'IMDb 🔍',
                                          style: const TextStyle(
                                            color: Colors.amber,
                                            fontSize: 11,
                                            decoration:
                                                TextDecoration.underline,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          // Next up
                          if (nextProg != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                children: [
                                  const Text(
                                    'Next: ',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      '${nextProg.title}  ${_programmeTimeRange(nextProg, timeshiftHours: _epgTimeshifts[_previewChannel!.id] ?? 0) ?? ''}',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          // Bottom row: status + controls
                          Row(
                            children: [
                              // Buffering status
                              StreamBuilder<bool>(
                                stream: playerService.bufferingStream,
                                builder: (context, snapshot) {
                                  final buffering = snapshot.data ?? false;
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (buffering)
                                        const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.5,
                                            color: Colors.orangeAccent,
                                          ),
                                        )
                                      else
                                        const Icon(
                                          Icons.signal_cellular_alt,
                                          size: 14,
                                          color: Colors.green,
                                        ),
                                      const SizedBox(width: 4),
                                      Text(
                                        buffering ? 'Buffering' : 'OK',
                                        style: TextStyle(
                                          color: buffering
                                              ? Colors.orangeAccent
                                              : Colors.green,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(width: 4),
                              // Audio indicator
                              StreamBuilder<bool>(
                                stream: playerService.hasAudioStream,
                                builder: (context, snapshot) {
                                  final hasAudio = snapshot.data ?? true;
                                  if (hasAudio) return const SizedBox.shrink();
                                  return const Tooltip(
                                    message: 'No audio track detected',
                                    child: Icon(
                                      Icons.volume_off_rounded,
                                      size: 14,
                                      color: Colors.redAccent,
                                    ),
                                  );
                                },
                              ),
                              const Spacer(),
                              // Debug info
                              SizedBox(
                                height: 28,
                                width: 28,
                                child: ExcludeFocus(
                                  excluding: Platform.isAndroid,
                                  child: IconButton(
                                    onPressed: () {
                                      if (_previewChannel == null) return;
                                      final ps = ref.read(
                                        playerServiceProvider,
                                      );
                                      ChannelDebugDialog.show(
                                        context,
                                        _previewChannel!,
                                        ps,
                                        mappedEpgId: _getEpgId(
                                          _previewChannel!,
                                        ),
                                        originalName:
                                            _previewChannel!.tvgName ??
                                            _previewChannel!.name,
                                        currentProviderName: ref
                                            .read(streamAlternativesProvider)
                                            .providerName(
                                              _previewChannel!.providerId,
                                            ),
                                        alternatives: _getFailoverAlts(
                                          _previewChannel!,
                                        ),
                                      );
                                    },
                                    icon: const Icon(
                                      Icons.info_outline,
                                      size: 16,
                                    ),
                                    padding: EdgeInsets.zero,
                                    color: Colors.white70,
                                    tooltip: 'Channel debug info',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Video container widget extracted for reuse in narrow/wide layouts.
  Widget _buildVideoContainer(dynamic playerService) {
    if (_previewChannel == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tv_rounded, size: 48, color: Colors.white24),
              SizedBox(height: 8),
              Text(
                'Select a channel',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: _togglePreviewControls,
      onDoubleTap: () => _goFullscreen(_previewChannel!),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: playerService.videoController,
            controls: NoVideoControls,
            fit: BoxFit.contain,
          ),
          // Centered buffering indicator — shown while (re)buffering, hidden
          // the moment playback resumes (also shown in the inline/windowed
          // player, not just fullscreen).
          Center(
            child: StreamBuilder<bool>(
              stream: playerService.bufferingStream,
              initialData: playerService.player.state.buffering,
              builder: (context, snapshot) {
                final buffering = snapshot.data ?? false;
                return AnimatedOpacity(
                  opacity: buffering ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !buffering,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFF6C5CE7),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Tap-to-reveal info + play bar overlay (auto-hides after 3s)
          _buildPreviewOverlay(playerService),
          // Load-timeout message — shown when a stream fails to start in time.
          Center(
            child: StreamBuilder<bool>(
              stream: playerService.loadTimeoutStream,
              initialData: playerService.loadTimedOut,
              builder: (context, snapshot) {
                if (snapshot.data != true) return const SizedBox.shrink();
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: Colors.white70,
                        size: 32,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Loading timed out',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_showVolumeOverlay)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _volume == 0
                          ? Icons.volume_off
                          : _volume < 50
                          ? Icons.volume_down
                          : Icons.volume_up,
                      color: Colors.white,
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${_volume.round()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Tap-to-reveal overlay for the inline (windowed) preview player.
  ///
  /// Shows the most useful bits without crowding the small window: the channel
  /// name and current programme along the top, and a slim play bar along the
  /// bottom (play/pause, mute and an EPG-based progress indicator). Hidden by
  /// default; revealed on tap and auto-hidden after 3s of inactivity.
  Widget _buildPreviewOverlay(dynamic playerService) {
    final channel = _previewChannel;
    if (channel == null) return const SizedBox.shrink();

    final programme = _getEpgProgramme(channel);

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_showPreviewControls,
        child: AnimatedOpacity(
          opacity: _showPreviewControls ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showPreviewControls = false),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Top: channel name + now playing ──
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                _channelDisplayName(channel),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _PreviewInfoBadges(playerService: playerService),
                          ],
                        ),
                        if (programme != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.play_circle_outline,
                                  size: 12,
                                  color: Colors.cyanAccent,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    programme.title,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // ── Bottom: play bar ──
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Row(
                      children: [
                        // Play / pause
                        StreamBuilder<bool>(
                          stream: playerService.player.stream.playing,
                          initialData: playerService.player.state.playing,
                          builder: (context, snapshot) {
                            final playing = snapshot.data ?? false;
                            return _previewIconBtn(
                              playing ? Icons.pause : Icons.play_arrow,
                              onTap: () {
                                playing
                                    ? playerService.pause()
                                    : playerService.resume();
                                _scheduleHidePreviewControls();
                              },
                            );
                          },
                        ),
                        // Mute toggle
                        _previewIconBtn(
                          _volume == 0
                              ? Icons.volume_off
                              : _volume < 50
                              ? Icons.volume_down
                              : Icons.volume_up,
                          onTap: () {
                            final newVol = _volume > 0 ? 0.0 : 100.0;
                            setState(() => _volume = newVol);
                            playerService.setVolume(newVol);
                            _scheduleHidePreviewControls();
                          },
                        ),
                        // Volume slider
                        SizedBox(
                          width: 90,
                          height: 24,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 10,
                              ),
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: Colors.white30,
                              thumbColor: Colors.white,
                            ),
                            child: Slider(
                              value: _volume,
                              min: 0,
                              max: 100,
                              onChanged: (v) {
                                setState(() => _volume = v);
                                playerService.setVolume(v);
                                _scheduleHidePreviewControls();
                              },
                            ),
                          ),
                        ),
                        const Spacer(),
                        // Stop playback
                        _previewIconBtn(
                          Icons.stop_rounded,
                          onTap: () {
                            ref.read(playerServiceProvider).stop();
                            _previewControlsTimer?.cancel();
                            setState(() {
                              _previewChannel = null;
                              _showPreviewControls = false;
                            });
                          },
                        ),
                        // Fullscreen
                        _previewIconBtn(
                          Icons.fullscreen_rounded,
                          onTap: () => _goFullscreen(channel),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Compact icon button used inside the inline preview overlay play bar.
  Widget _previewIconBtn(IconData icon, {required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  /// Extract quality tag (UHD/4K/FHD/HD/SD) from channel name and return a badge widget.
  Widget? _qualityBadge(String name) {
    final upper = name.toUpperCase();
    String? label;
    Color? color;
    if (upper.contains('4K') || upper.contains('UHD')) {
      label = 'UHD';
      color = const Color(0xFF9B59B6);
    } else if (upper.contains('FHD') ||
        upper.contains('FULLHD') ||
        upper.contains('FULL HD')) {
      label = 'FHD';
      color = const Color(0xFF2ECC71);
    } else if (RegExp(r'\bHD\b').hasMatch(upper)) {
      label = 'HD';
      color = const Color(0xFF3498DB);
    } else if (RegExp(r'\bSD\b').hasMatch(upper)) {
      label = 'SD';
      color = const Color(0xFF95A5A6);
    }
    if (label == null) return null;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color!.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildSidebar() {
    final width = _sidebarExpanded ? 188.0 : 44.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: width,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(color: Color(0xFF111127)),
      child: FocusScope(
        node: _sidebarFocusNode,
        child: Column(
          children: [
            if (!_sidebarExpanded)
              // Collapsed: expand button only
              InkWell(
                onTap: () => setState(() => _sidebarExpanded = true),
                child: Container(
                  height: 36,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                ),
              )
            else if (!Platform.isAndroid) ...[
              // Expanded (desktop/mobile): search field + collapse toggle
              // share one row so the toggle doesn't take a dedicated row.
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 30,
                        child: TextFormField(
                          controller: _sidebarSearchController,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search channel',
                            hintStyle: const TextStyle(
                              color: Colors.white24,
                              fontSize: 11,
                            ),
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 14,
                              color: Colors.white24,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 30,
                            ),
                            suffixIcon: _sidebarSearchQuery.isNotEmpty
                                ? GestureDetector(
                                    onTap: () {
                                      _sidebarSearchController.clear();
                                      setState(() => _sidebarSearchQuery = '');
                                    },
                                    child: const Icon(
                                      Icons.close_rounded,
                                      size: 14,
                                      color: Colors.white24,
                                    ),
                                  )
                                : null,
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 30,
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (v) {
                            setState(() {
                              _sidebarSearchQuery = v.toLowerCase();
                              _applyFilters();
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => setState(() => _sidebarExpanded = false),
                      borderRadius: BorderRadius.circular(6),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.chevron_left_rounded,
                          color: Colors.white38,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white10),
            ] else
              // Expanded (Android TV): collapse toggle only, no search field.
              InkWell(
                onTap: () => setState(() => _sidebarExpanded = false),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerRight,
                  child: const Icon(
                    Icons.chevron_left_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                ),
              ),
            // Tree content
            Expanded(
              child: _sidebarExpanded
                  ? _buildSidebarTree()
                  : _buildCollapsedSidebar(),
            ),
            // Settings — anchored at bottom of sidebar
            const Divider(height: 1, color: Colors.white10),
            if (_sidebarExpanded) ...[
              _buildSidebarNavItem(Icons.settings_rounded, 'Settings', () {
                context.push('/settings');
              }),
            ] else ...[
              _sidebarIcon(Icons.settings_rounded, 'Settings', false, () {
                context.push('/settings');
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedSidebar() {
    // Icons-only when collapsed
    final isAll = _selectedGroup == 'All';
    final isFav =
        _selectedGroup == 'Favorites' || _selectedGroup.startsWith('fav:');
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _sidebarIcon(Icons.grid_view_rounded, 'All', isAll, () {
          setState(() {
            _clearSearch();
            _selectedGroup = 'All';
            _applyFilters();
            _saveSession();
          });
        }),
        _sidebarIcon(Icons.star_rounded, 'Favorites', isFav, () {
          setState(() {
            _clearSearch();
            _selectedGroup = 'Favorites';
            _applyFilters();
            _saveSession();
          });
        }),
        const Divider(height: 1, color: Colors.white10),
        _sidebarIcon(Icons.folder_rounded, 'Groups', !isAll && !isFav, () {
          setState(() => _sidebarExpanded = true);
        }),
      ],
    );
  }

  Widget _sidebarIcon(
    IconData icon,
    String tooltip,
    bool active,
    VoidCallback onTap,
  ) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _firstChannelFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return InkWell(
              onTap: onTap,
              child: Container(
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.transparent,
                  border: hasFocus
                      ? Border.all(color: Colors.purpleAccent, width: 1.5)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: active ? Colors.white : Colors.white38,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSidebarNavItem(IconData icon, String label, VoidCallback onTap) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _firstChannelFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return InkWell(
            onTap: onTap,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: hasFocus
                    ? Border.all(color: Colors.purpleAccent, width: 1.5)
                    : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: Colors.white54),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSidebarTree() {
    final q = _sidebarSearchQuery;
    final filteredGroups = q.isEmpty
        ? _groups
        : _groups.where((g) => g.toLowerCase().contains(q)).toList();
    final filteredFavs = q.isEmpty
        ? _favoriteLists
        : _favoriteLists
              .where((l) => l.name.toLowerCase().contains(q))
              .toList();
    final filteredProviders = q.isEmpty
        ? _providers
        : _providers.where((p) => p.name.toLowerCase().contains(q)).toList();
    final showAll = q.isEmpty || 'all'.contains(q);
    final showFavSection =
        q.isEmpty || filteredFavs.isNotEmpty || 'favorites'.contains(q);
    final showProvSection =
        q.isEmpty || filteredProviders.isNotEmpty || 'providers'.contains(q);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (showAll)
          _buildTreeItem(
            'All (${_allChannels.length})',
            'All',
            Icons.grid_view_rounded,
            indent: 0,
            focusNode: _sidebarAllItemFocusNode,
          ),
        if (showFavSection)
          _buildTreeSection('favorites', Icons.star_rounded, 'Favorites', [
            if (q.isEmpty || 'favorites'.contains(q))
              _buildTreeItem(
                'All Favorites',
                'Favorites',
                Icons.star_rounded,
                indent: 1,
              ),
            for (final list in filteredFavs)
              _buildTreeItem(
                list.name,
                'fav:${list.id}',
                Icons.star_outline_rounded,
                indent: 1,
                onSecondaryTap: () => _renameFavoriteList(list),
              ),
            if (q.isEmpty)
              _buildTreeAction(
                'New List…',
                Icons.add_rounded,
                () => _showManageFavoritesDialog(),
                indent: 1,
              ),
          ]),
        if (showFavSection || showProvSection)
          const Divider(height: 1, color: Colors.white10),
        if (showProvSection) ..._buildProviderTrees(filteredProviders, q),
        if (showProvSection || filteredGroups.isNotEmpty)
          const Divider(height: 1, color: Colors.white10),
        if (filteredGroups.isNotEmpty)
          _buildTreeSection(
            'groups',
            Icons.folder_rounded,
            'Groups (${filteredGroups.length})',
            [
              for (final group in filteredGroups)
                _buildTreeItem(group, group, null, indent: 1),
            ],
          ),
        // Shows & Movies
        const Divider(height: 1, color: Colors.white10),
        _buildTreeItem(
          'Shows & Movies',
          'action:shows',
          Icons.movie_rounded,
          indent: 0,
        ),
        // Quick actions
        const Divider(height: 1, color: Colors.white10),
        _buildTreeItem(
          'Recordings',
          'action:recordings',
          Icons.videocam_rounded,
          indent: 0,
        ),
        _buildTreeItem(
          'Play File',
          'action:play_file',
          Icons.play_circle_outline_rounded,
          indent: 0,
        ),
        _buildTreeItem(
          'Play URL',
          'action:play_url',
          Icons.link_rounded,
          indent: 0,
        ),
      ],
    );
  }

  /// Build provider tree nodes: each provider is a collapsible section
  /// containing its category groups as sub-items.
  List<Widget> _buildProviderTrees(List<db.Provider> providers, String query) {
    final widgets = <Widget>[];
    for (final prov in providers) {
      final sortedGroups = _providerGroups[prov.id] ?? [];
      final filteredGroups = query.isEmpty
          ? sortedGroups
          : sortedGroups.where((g) => g.toLowerCase().contains(query)).toList();

      // No subcategories — show as a flat link
      if (filteredGroups.isEmpty) {
        widgets.add(
          _buildTreeItem(
            '${prov.name} (${_countChannelsInProvider(prov.id)})',
            'provider:${prov.id}',
            prov.type == 'xtream'
                ? Icons.bolt_rounded
                : Icons.playlist_play_rounded,
            indent: 0,
          ),
        );
      } else {
        // Has subcategories — show as expandable tree
        widgets.add(
          _buildTreeSection(
            'prov_${prov.id}',
            prov.type == 'xtream'
                ? Icons.bolt_rounded
                : Icons.playlist_play_rounded,
            '${prov.name} (${_countChannelsInProvider(prov.id)})',
            [
              for (final group in filteredGroups)
                _buildTreeItem(
                  '$group (${_countChannelsInGroup(prov.id, group)})',
                  'provgroup:${prov.id}:$group',
                  Icons.folder_open_rounded,
                  indent: 1,
                ),
            ],
            filterKey: 'provider:${prov.id}',
          ),
        );
      }
    }
    return widgets;
  }

  /// Count channels in a specific provider group.
  ///
  /// Memoized: the per-group counts are computed once and reused until the
  /// [_allChannels] list reference changes, so building the sidebar tree is
  /// O(channels) total rather than O(groups × channels).
  List<db.Channel>? _groupCountSource;
  Map<String, int> _groupCountCache = {};
  Map<String, int> _providerCountCache = {};

  void _ensureChannelCounts() {
    if (!identical(_groupCountSource, _allChannels)) {
      _groupCountSource = _allChannels;
      final counts = <String, int>{};
      final provCounts = <String, int>{};
      for (final c in _allChannels) {
        final key = '${c.providerId}\x00${c.groupTitle ?? ''}';
        counts[key] = (counts[key] ?? 0) + 1;
        provCounts[c.providerId] = (provCounts[c.providerId] ?? 0) + 1;
      }
      _groupCountCache = counts;
      _providerCountCache = provCounts;
    }
  }

  int _countChannelsInGroup(String providerId, String groupTitle) {
    _ensureChannelCounts();
    return _groupCountCache['$providerId\x00$groupTitle'] ?? 0;
  }

  /// Count total channels belonging to a provider (root-level count).
  int _countChannelsInProvider(String providerId) {
    _ensureChannelCounts();
    return _providerCountCache[providerId] ?? 0;
  }

  Widget _buildTreeSection(
    String sectionKey,
    IconData icon,
    String label,
    List<Widget> children, {
    String? filterKey,
  }) {
    final expanded = _expandedSections.contains(sectionKey);
    final isSelected = filterKey != null && _selectedGroup == filterKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _firstChannelFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              setState(() {
                _clearSearch();
                // Only change channel list if provider has no subcategories
                if (filterKey != null && children.isEmpty) {
                  _selectedGroup = filterKey;
                  _applyFilters();
                  _saveSession();
                }
                if (expanded) {
                  _expandedSections.remove(sectionKey);
                } else {
                  _expandedSections.add(sectionKey);
                }
              });
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) {
              final hasFocus = Focus.of(context).hasFocus;
              return InkWell(
                onTap: () {
                  setState(() {
                    _clearSearch();
                    // Only change channel list if provider has no subcategories
                    if (filterKey != null && children.isEmpty) {
                      _selectedGroup = filterKey;
                      _applyFilters();
                      _saveSession();
                    }
                    if (expanded) {
                      _expandedSections.remove(sectionKey);
                    } else {
                      _expandedSections.add(sectionKey);
                    }
                  });
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: hasFocus
                        ? Border.all(color: Colors.purpleAccent, width: 1.5)
                        : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        expanded
                            ? Icons.expand_more_rounded
                            : Icons.chevron_right_rounded,
                        size: 16,
                        color: Colors.white38,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        icon,
                        size: 14,
                        color: isSelected ? Colors.amber : Colors.white54,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isSelected ? Colors.white : Colors.white54,
                            letterSpacing: 0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (expanded) ...children,
      ],
    );
  }

  void _handleQuickAction(String action) {
    switch (action) {
      case 'recordings':
        _showRecordings();
        break;
      case 'play_file':
        _playLocalFile();
        break;
      case 'shows':
        context.push('/shows');
        break;
      case 'play_url':
        _playUrlStream();
        break;
      case 'settings':
        context.push('/settings');
        break;
    }
  }

  Future<void> _showRecordings() async {
    final prefs = await SharedPreferences.getInstance();
    final folder = prefs.getString('recordings_folder');
    if (!mounted) return;
    if (folder == null || folder.isEmpty) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        countdownSnackBar(
          'No recording folder set. Go to Settings → Recordings to choose one.',
          seconds: 5,
        ),
      );
      return;
    }
    // List recordings from the folder
    final dir = Directory(folder);
    if (!await dir.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Recording folder no longer exists. Update in Settings.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    final files = await dir
        .list()
        .where(
          (f) =>
              f.path.endsWith('.mp4') ||
              f.path.endsWith('.ts') ||
              f.path.endsWith('.mkv'),
        )
        .toList();
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No recordings found.'),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Recordings'),
        children: [
          for (final f in files)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f.path),
              child: Row(
                children: [
                  const Icon(
                    Icons.videocam_rounded,
                    size: 18,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      f.path.split('/').last,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      final playerService = ref.read(playerServiceProvider);
      await playerService.play(picked);
      if (mounted) context.push('/player');
    }
  }

  Future<void> _playLocalFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mkv', 'ts', 'avi', 'mov', 'm3u8', 'mpd'],
      dialogTitle: 'Choose a video file',
    );
    if (result != null && result.files.single.path != null && mounted) {
      final playerService = ref.read(playerServiceProvider);
      await playerService.play(result.files.single.path!);
      if (mounted) context.push('/player');
    }
  }

  Future<void> _playUrlStream() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
            return AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              padding: EdgeInsets.only(bottom: bottomInset),
              child: AlertDialog(
                title: const Text('Play Network Stream'),
                content: SizedBox(
                  width: 500,
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      hintText: 'http:// or rtsp:// stream URL',
                      isDense: true,
                    ),
                    onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                    child: const Text('Play'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (url != null && url.isNotEmpty && mounted) {
      final playerService = ref.read(playerServiceProvider);
      await playerService.play(url);
      if (mounted) context.push('/player');
    }
  }

  Widget _buildTreeItem(
    String label,
    String filterKey,
    IconData? icon, {
    int indent = 0,
    VoidCallback? onSecondaryTap,
    Widget? trailing,
    FocusNode? focusNode,
  }) {
    final isSelected = _selectedGroup == filterKey;
    return GestureDetector(
      onSecondaryTap: onSecondaryTap,
      child: Focus(
        focusNode: focusNode,
        autofocus: isSelected && Platform.isAndroid,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            // RIGHT from sidebar → focus channel list
            _firstChannelFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            if (filterKey.startsWith('action:')) {
              _handleQuickAction(filterKey.substring(7));
              return KeyEventResult.handled;
            }
            setState(() {
              _clearSearch();
              _selectedGroup = filterKey;
              _applyFilters();
            });
            _saveSession();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return InkWell(
              onTap: () {
                // Handle quick actions
                if (filterKey.startsWith('action:')) {
                  _handleQuickAction(filterKey.substring(7));
                  return;
                }
                setState(() {
                  _clearSearch();
                  _selectedGroup = filterKey;
                  _applyFilters();
                });
                _saveSession();
              },
              child: Container(
                height: 30,
                padding: EdgeInsets.only(
                  left: 12.0 + (indent * 16.0),
                  right: 8,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.transparent,
                  border: hasFocus
                      ? Border.all(color: Colors.purpleAccent, width: 1.5)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        size: 13,
                        color: isSelected ? Colors.amber : Colors.white38,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          color: isSelected ? Colors.white : Colors.white60,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (trailing != null) trailing,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTreeAction(
    String label,
    IconData icon,
    VoidCallback onTap, {
    int indent = 0,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: EdgeInsets.only(left: 12.0 + (indent * 16.0), right: 8),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Icon(icon, size: 13, color: Colors.white24),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white30,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelList() {
    if (_filteredChannels.isEmpty) {
      return const Center(
        child: Text(
          'No channels match your filter',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    // Build failover group rows to show above the channel list
    final failoverGroupWidgets = <Widget>[];
    if (_failoverGroups.isNotEmpty &&
        !_multiSelectMode &&
        _searchQuery.isEmpty &&
        _sidebarSearchQuery.isEmpty) {
      // Build channel lookup map for performance
      final channelById = <String, db.Channel>{};
      for (final c in _allChannels) {
        channelById[c.id] = c;
      }
      for (final group in _failoverGroups) {
        final memberIds = _failoverGroupMembers[group.id] ?? [];
        final members = memberIds
            .map((id) => channelById[id])
            .whereType<db.Channel>()
            .toList();
        if (members.isNotEmpty) {
          failoverGroupWidgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: _buildFailoverGroupRow(group, members),
            ),
          );
        }
      }
    }

    final listWidget = ListView.builder(
      controller: _channelListController,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount:
          _filteredChannels.length +
          (failoverGroupWidgets.isNotEmpty
              ? failoverGroupWidgets.length + 1
              : 0),
      itemBuilder: (context, index) {
        // Inject failover group rows at the top
        if (failoverGroupWidgets.isNotEmpty) {
          if (index < failoverGroupWidgets.length) {
            return failoverGroupWidgets[index];
          }
          if (index == failoverGroupWidgets.length) {
            return const Divider(color: Colors.white12, height: 16);
          }
          index = index - failoverGroupWidgets.length - 1;
        }
        final channel = _filteredChannels[index];
        final isSelected = index == _selectedIndex;
        final isFavorited = _favoritedChannelIds.contains(channel.id);

        return Material(
          color: Colors.transparent,
          child: GestureDetector(
            onSecondaryTapUp: (_) => _showFavoriteListSheet(channel),
            child: Focus(
              focusNode: index == 0 ? _firstChannelFocusNode : null,
              autofocus: index == 0 && Platform.isAndroid,
              onFocusChange: (hasFocus) {
                if (hasFocus && Platform.isAndroid) _selectChannel(index);
              },
              onKeyEvent: (node, event) {
                // Track this node so sidebar can navigate back
                final key = event.logicalKey;
                final isCenterKey =
                    key == LogicalKeyboardKey.select ||
                    key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.gameButtonA;

                // Long-press CENTER on TV remote → enter/toggle multi-select
                if (Platform.isAndroid && isCenterKey) {
                  if (event is KeyDownEvent) {
                    _longPressChannelId = channel.id;
                    _longPressTimer?.cancel();
                    _longPressTimer = Timer(
                      const Duration(milliseconds: 400),
                      () {
                        if (!mounted) return;
                        setState(() {
                          if (!_multiSelectMode) {
                            _multiSelectMode = true;
                            _multiSelectedChannelIds = {channel.id};
                          } else {
                            if (_multiSelectedChannelIds.contains(channel.id)) {
                              _multiSelectedChannelIds.remove(channel.id);
                            } else {
                              _multiSelectedChannelIds.add(channel.id);
                            }
                          }
                        });
                        _longPressChannelId = null;
                      },
                    );
                    return KeyEventResult.handled;
                  }
                  if (event is KeyUpEvent) {
                    final wasLongPress = _longPressChannelId == null;
                    _longPressTimer?.cancel();
                    _longPressTimer = null;
                    _longPressChannelId = null;
                    if (wasLongPress) {
                      // Long-press already fired, consume the up event
                      return KeyEventResult.handled;
                    }
                    // Short press: toggle selection if in multi-select, else fullscreen
                    if (_multiSelectMode) {
                      setState(() {
                        if (_multiSelectedChannelIds.contains(channel.id)) {
                          _multiSelectedChannelIds.remove(channel.id);
                        } else {
                          _multiSelectedChannelIds.add(channel.id);
                        }
                      });
                    } else {
                      _goFullscreen(channel);
                    }
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.handled;
                }

                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                // SHIFT+ENTER → toggle multi-select (keyboard/desktop)
                if (isCenterKey &&
                    HardwareKeyboard.instance.logicalKeysPressed.any(
                      (k) =>
                          k == LogicalKeyboardKey.shiftLeft ||
                          k == LogicalKeyboardKey.shiftRight,
                    )) {
                  setState(() {
                    if (!_multiSelectMode) {
                      _multiSelectMode = true;
                      _multiSelectedChannelIds = {channel.id};
                    } else {
                      if (_multiSelectedChannelIds.contains(channel.id)) {
                        _multiSelectedChannelIds.remove(channel.id);
                      } else {
                        _multiSelectedChannelIds.add(channel.id);
                      }
                    }
                  });
                  return KeyEventResult.handled;
                }
                // SELECT/ENTER → toggle in multi-select, else fullscreen
                if (isCenterKey) {
                  if (_multiSelectMode) {
                    setState(() {
                      if (_multiSelectedChannelIds.contains(channel.id)) {
                        _multiSelectedChannelIds.remove(channel.id);
                      } else {
                        _multiSelectedChannelIds.add(channel.id);
                      }
                    });
                  } else {
                    _goFullscreen(channel);
                  }
                  return KeyEventResult.handled;
                }
                // LEFT from channel list → focus sidebar
                if (key == LogicalKeyboardKey.arrowLeft) {
                  _sidebarAllItemFocusNode.requestFocus();
                  return KeyEventResult.handled;
                }
                // BACK exits multi-select mode on TV
                if (_multiSelectMode && key == LogicalKeyboardKey.goBack) {
                  setState(() {
                    _multiSelectMode = false;
                    _multiSelectedChannelIds.clear();
                  });
                  return KeyEventResult.handled;
                }
                // MENU/contextMenu → toggle multi-select for this channel
                if (key == LogicalKeyboardKey.contextMenu ||
                    key == LogicalKeyboardKey.f5) {
                  setState(() {
                    if (!_multiSelectMode) {
                      _multiSelectMode = true;
                      _multiSelectedChannelIds = {channel.id};
                    } else {
                      if (_multiSelectedChannelIds.contains(channel.id)) {
                        _multiSelectedChannelIds.remove(channel.id);
                      } else {
                        _multiSelectedChannelIds.add(channel.id);
                      }
                    }
                  });
                  return KeyEventResult.handled;
                }
                return KeyEventResult
                    .ignored; // Let Flutter handle UP/DOWN naturally
              },
              child: Builder(
                builder: (context) {
                  final focused = Focus.of(context).hasFocus;
                  final isMultiSelected =
                      _multiSelectMode &&
                      _multiSelectedChannelIds.contains(channel.id);
                  return InkWell(
                    onTap: () {
                      // Check modifier keys using both APIs for macOS compatibility
                      final hwPressed =
                          HardwareKeyboard.instance.logicalKeysPressed;
                      // ignore: deprecated_member_use
                      final rawPressed = RawKeyboard.instance.keysPressed;
                      final shiftOrCmd =
                          hwPressed.contains(LogicalKeyboardKey.shiftLeft) ||
                          hwPressed.contains(LogicalKeyboardKey.shiftRight) ||
                          hwPressed.contains(LogicalKeyboardKey.metaLeft) ||
                          hwPressed.contains(LogicalKeyboardKey.metaRight) ||
                          rawPressed.contains(LogicalKeyboardKey.shiftLeft) ||
                          rawPressed.contains(LogicalKeyboardKey.shiftRight) ||
                          rawPressed.contains(LogicalKeyboardKey.metaLeft) ||
                          rawPressed.contains(LogicalKeyboardKey.metaRight);
                      try {
                        File('/tmp/click_debug.log').writeAsStringSync(
                          '${DateTime.now()} TAP ch=${channel.name} shift=$shiftOrCmd multiMode=$_multiSelectMode hw=${hwPressed.map((k) => k.debugName).join(",")} raw=${rawPressed.map((k) => k.debugName).join(",")}\n',
                          mode: FileMode.append,
                        );
                      } catch (_) {}
                      if (shiftOrCmd) {
                        // Shift/Cmd+click: toggle multi-select
                        setState(() {
                          if (!_multiSelectMode) {
                            _multiSelectMode = true;
                            _multiSelectedChannelIds = {channel.id};
                          } else {
                            if (_multiSelectedChannelIds.contains(channel.id)) {
                              _multiSelectedChannelIds.remove(channel.id);
                            } else {
                              _multiSelectedChannelIds.add(channel.id);
                            }
                          }
                        });
                      } else if (_multiSelectMode) {
                        setState(() {
                          if (_multiSelectedChannelIds.contains(channel.id)) {
                            _multiSelectedChannelIds.remove(channel.id);
                          } else {
                            _multiSelectedChannelIds.add(channel.id);
                          }
                        });
                      } else {
                        _selectChannel(index);
                      }
                    },
                    onLongPress: _multiSelectMode
                        ? null
                        : () {
                            if (Platform.isAndroid) {
                              // TV: long-press enters multi-select
                              setState(() {
                                _multiSelectMode = true;
                                _multiSelectedChannelIds = {channel.id};
                              });
                            } else {
                              _goFullscreen(channel);
                            }
                          },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isMultiSelected
                            ? const Color(0xFF6C5CE7).withValues(alpha: 0.25)
                            : isSelected
                            ? const Color(0xFF6C5CE7).withValues(alpha: 0.3)
                            : focused
                            ? const Color(0xFF6C5CE7).withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: focused
                            ? Border.all(color: Colors.white, width: 2.0)
                            : isMultiSelected
                            ? Border.all(
                                color: const Color(0xFF6C5CE7),
                                width: 1.5,
                              )
                            : isSelected
                            ? Border.all(
                                color: const Color(0xFF6C5CE7),
                                width: 1.5,
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          // Multi-select checkbox
                          if (_multiSelectMode)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Icon(
                                isMultiSelected
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                size: 20,
                                color: isMultiSelected
                                    ? const Color(0xFF6C5CE7)
                                    : Colors.white38,
                              ),
                            ),
                          // Channel logo
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child:
                                  channel.tvgLogo != null &&
                                      channel.tvgLogo!.isNotEmpty
                                  ? Image.network(
                                      channel.tvgLogo!,
                                      fit: BoxFit.contain,
                                      cacheWidth: 160,
                                      errorBuilder: (_, e, s) => Container(
                                        color: const Color(0xFF16213E),
                                        child: const Icon(
                                          Icons.tv,
                                          size: 18,
                                          color: Colors.white24,
                                        ),
                                      ),
                                    )
                                  : Container(
                                      color: const Color(0xFF16213E),
                                      child: const Icon(
                                        Icons.tv,
                                        size: 18,
                                        color: Colors.white24,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Channel name + group + now-playing
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _channelDisplayName(channel),
                                        style: TextStyle(
                                          color: isSelected
                                              ? Colors.white
                                              : Colors.white70,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (_qualityBadge(channel.name) != null)
                                      _qualityBadge(channel.name)!,
                                  ],
                                ),
                                if (_getProviderName(
                                      channel.providerId,
                                    ).isNotEmpty ||
                                    (channel.groupTitle != null &&
                                        channel.groupTitle!.isNotEmpty))
                                  Text(
                                    [
                                      if (_getProviderName(
                                        channel.providerId,
                                      ).isNotEmpty)
                                        _getProviderName(channel.providerId),
                                      if (channel.groupTitle != null &&
                                          channel.groupTitle!.isNotEmpty)
                                        channel.groupTitle!,
                                    ].join(' · '),
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                if (_useMobileEpg)
                                  ..._buildMobileEpgLines(channel)
                                else if (_getChannelNowPlaying(channel) != null)
                                  Text(
                                    _getChannelNowPlaying(channel)!,
                                    style: const TextStyle(
                                      color: Color(0xFF6C5CE7),
                                      fontSize: 11,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  )
                                else if (_epgLoading)
                                  const Text(
                                    'Loading guide…',
                                    style: TextStyle(
                                      color: Colors.white24,
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Tap to expand this channel's vertical schedule
                          if (_useMobileEpg && _getEpgId(channel) != null)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              icon: const Icon(
                                Icons.expand_more_rounded,
                                color: Colors.white38,
                                size: 20,
                              ),
                              tooltip: 'Show schedule',
                              onPressed: () => _showChannelSchedule(channel),
                            ),
                          // Favorite indicator
                          if (isFavorited)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.star_rounded,
                                color: Colors.amber,
                                size: 16,
                              ),
                            ),
                          // Now-playing indicator
                          if (isSelected)
                            const Icon(
                              Icons.play_arrow_rounded,
                              color: Color(0xFF6C5CE7),
                              size: 20,
                            ),
                        ],
                      ),
                    ),
                  ); // InkWell + return
                }, // Builder builder
              ), // Builder
            ), // Focus
          ), // GestureDetector
        ); // Material
      },
    );

    return Stack(
      children: [
        listWidget,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 40,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, const Color(0xFF0A0A0F)],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  int get _guideFailoverGroupCount {
    if (_failoverGroups.isEmpty ||
        _multiSelectMode ||
        _searchQuery.isNotEmpty ||
        _sidebarSearchQuery.isNotEmpty)
      return 0;
    return _failoverGroups.where((g) {
      final memberIds = _failoverGroupMembers[g.id] ?? [];
      return memberIds.isNotEmpty;
    }).length;
  }

  Widget _buildGuideFailoverGroupRow(
    int foIndex,
    db.AppDatabase database,
    double hOffset,
    DateTime dayStart,
    DateTime dayEnd, {
    required int totalMinutes,
    required double totalWidth,
  }) {
    // Resolve the foIndex-th non-empty failover group
    final channelById = <String, db.Channel>{};
    for (final c in _allChannels) channelById[c.id] = c;
    var count = 0;
    late db.FailoverGroup group;
    late List<db.Channel> members;
    for (final g in _failoverGroups) {
      final memberIds = _failoverGroupMembers[g.id] ?? [];
      final resolved = memberIds
          .map((id) => channelById[id])
          .whereType<db.Channel>()
          .toList();
      if (resolved.isNotEmpty) {
        if (count == foIndex) {
          group = g;
          members = resolved;
          break;
        }
        count++;
      }
    }
    final primary = members.first;
    final isExpanded = _expandedFailoverGroups.contains(group.id);

    // Find EPG channel from any member
    db.Channel? epgMember;
    for (final m in members) {
      if (_getEpgId(m) != null) {
        epgMember = m;
        break;
      }
    }

    // Check if any member is currently playing
    final ps = ref.read(playerServiceProvider);
    final isGroupPlaying = members.any(
      (m) =>
          ps.currentChannelId == m.id ||
          (ps.currentChannelId == null && ps.currentUrl == m.streamUrl),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Main group row — same layout as regular guide row
        Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.gameButtonA) {
              _playFailoverGroup(group, members);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowRight && !isExpanded) {
              setState(() => _expandedFailoverGroups.add(group.id));
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft && isExpanded) {
              setState(() => _expandedFailoverGroups.remove(group.id));
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.contextMenu ||
                key == LogicalKeyboardKey.f5) {
              _showFailoverGroupActions(group);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _playFailoverGroup(group, members),
                onSecondaryTapUp: (_) => _showFailoverGroupActions(group),
                onDoubleTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedFailoverGroups.remove(group.id);
                    } else {
                      _expandedFailoverGroups.add(group.id);
                    }
                  });
                },
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: isGroupPlaying
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.2)
                        : focused
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.1)
                        : null,
                    border: Border(
                      bottom: const BorderSide(
                        color: Colors.white10,
                        width: 0.5,
                      ),
                      left: BorderSide(
                        color: const Color(0xFF6C5CE7),
                        width: isGroupPlaying
                            ? 3
                            : focused
                            ? 3
                            : 2,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      // Fixed channel info panel
                      Container(
                        width: 200,
                        decoration: const BoxDecoration(
                          border: Border(
                            right: BorderSide(
                              color: Colors.white10,
                              width: 0.5,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child:
                                  primary.tvgLogo != null &&
                                      primary.tvgLogo!.isNotEmpty
                                  ? Image.network(
                                      primary.tvgLogo!,
                                      width: 44,
                                      height: 28,
                                      fit: BoxFit.contain,
                                      cacheWidth: 128,
                                      errorBuilder: (_, __, ___) => Container(
                                        width: 44,
                                        height: 28,
                                        color: const Color(0xFF16213E),
                                        child: const Icon(
                                          Icons.bolt,
                                          size: 14,
                                          color: Colors.amber,
                                        ),
                                      ),
                                    )
                                  : Container(
                                      width: 44,
                                      height: 28,
                                      color: const Color(0xFF16213E),
                                      child: const Icon(
                                        Icons.bolt,
                                        size: 14,
                                        color: Colors.amber,
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.bolt,
                                        size: 10,
                                        color: Colors.amber,
                                      ),
                                      const SizedBox(width: 2),
                                      Flexible(
                                        child: Text(
                                          group.name,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '${members.length} streams',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: Colors.white30,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            InkWell(
                              onTap: () {
                                setState(() {
                                  if (isExpanded) {
                                    _expandedFailoverGroups.remove(group.id);
                                  } else {
                                    _expandedFailoverGroups.add(group.id);
                                  }
                                });
                              },
                              child: Icon(
                                isExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Programme blocks from EPG member
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            if (epgMember == null) {
                              return const Center(
                                child: Text(
                                  'No EPG',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white24,
                                  ),
                                ),
                              );
                            }
                            return ClipRect(
                              child: Stack(
                                clipBehavior: Clip.hardEdge,
                                children: [
                                  Positioned(
                                    left: -hOffset,
                                    top: 0,
                                    bottom: 0,
                                    width: totalWidth,
                                    child: _buildGuideRowProgrammes(
                                      epgMember,
                                      database,
                                      dayStart,
                                      dayEnd,
                                      totalMinutes: totalMinutes,
                                      totalWidth: totalWidth,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // Expanded member rows
        if (isExpanded)
          ...members.asMap().entries.map((entry) {
            final idx = entry.key;
            final ch = entry.value;
            final ps = ref.read(playerServiceProvider);
            final isPlaying =
                ps.currentChannelId == ch.id ||
                (ps.currentChannelId == null && ps.currentUrl == ch.streamUrl);
            return Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.select ||
                    key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.gameButtonA) {
                  _playFailoverGroup(group, members, playChannel: ch);
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.contextMenu ||
                    key == LogicalKeyboardKey.f5) {
                  _showMemberActions(group, ch);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Builder(
                builder: (context) {
                  final focused = Focus.of(context).hasFocus;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        _playFailoverGroup(group, members, playChannel: ch),
                    onSecondaryTapUp: (_) => _showMemberActions(group, ch),
                    child: Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: isPlaying
                            ? const Color(0xFF6C5CE7).withValues(alpha: 0.2)
                            : focused
                            ? const Color(0xFF6C5CE7).withValues(alpha: 0.1)
                            : const Color(0xFF0D1117),
                        border: const Border(
                          bottom: BorderSide(color: Colors.white10, width: 0.5),
                        ),
                      ),
                      padding: const EdgeInsets.only(left: 24),
                      child: Row(
                        children: [
                          Text(
                            '#${idx + 1}',
                            style: const TextStyle(
                              color: Colors.white24,
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(width: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: SizedBox(
                              width: 34,
                              height: 22,
                              child:
                                  ch.tvgLogo != null && ch.tvgLogo!.isNotEmpty
                                  ? Image.network(
                                      ch.tvgLogo!,
                                      fit: BoxFit.contain,
                                      cacheWidth: 120,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.tv,
                                        size: 12,
                                        color: Colors.white24,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.tv,
                                      size: 12,
                                      color: Colors.white24,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _channelDisplayName(ch),
                              style: TextStyle(
                                color: isPlaying
                                    ? Colors.white
                                    : Colors.white54,
                                fontSize: 11,
                                fontWeight: isPlaying
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isPlaying)
                            const Icon(
                              Icons.play_arrow_rounded,
                              color: Color(0xFF6C5CE7),
                              size: 14,
                            ),
                          Text(
                            _getProviderName(ch.providerId),
                            style: const TextStyle(
                              color: Colors.white24,
                              fontSize: 9,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          }),
      ],
    );
  }

  Widget _buildMultiSelectBar() {
    return FocusTraversalGroup(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF6C5CE7), width: 1),
          boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 8)],
        ),
        child: Row(
          children: [
            Text(
              '${_multiSelectedChannelIds.length} selected',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const Spacer(),
            Focus(
              child: Builder(
                builder: (ctx) {
                  final focused = Focus.of(ctx).hasFocus;
                  return TextButton(
                    style: focused
                        ? TextButton.styleFrom(
                            side: const BorderSide(
                              color: Color(0xFF6C5CE7),
                              width: 2,
                            ),
                          )
                        : null,
                    onPressed: () => setState(() {
                      _multiSelectMode = false;
                      _multiSelectedChannelIds.clear();
                    }),
                    child: const Text('Cancel'),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            if (_failoverGroups.isNotEmpty)
              Focus(
                child: Builder(
                  builder: (ctx) {
                    final focused = Focus.of(ctx).hasFocus;
                    return FilledButton.icon(
                      onPressed: _multiSelectedChannelIds.isNotEmpty
                          ? _addToExistingFailoverGroup
                          : null,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add to Smart Channel'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2D3436),
                        side: focused
                            ? const BorderSide(color: Colors.white, width: 2)
                            : null,
                      ),
                    );
                  },
                ),
              ),
            if (_failoverGroups.isNotEmpty) const SizedBox(width: 8),
            Focus(
              autofocus: Platform.isAndroid,
              child: Builder(
                builder: (ctx) {
                  final focused = Focus.of(ctx).hasFocus;
                  return FilledButton.icon(
                    onPressed: _multiSelectedChannelIds.length >= 2
                        ? _createFailoverGroupFromSelection
                        : null,
                    icon: const Icon(Icons.bolt, size: 16),
                    label: const Text('New Smart Channel'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6C5CE7),
                      side: focused
                          ? const BorderSide(color: Colors.white, width: 2)
                          : null,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Failover group creation from multi-select
  // ---------------------------------------------------------------------------

  Future<void> _createFailoverGroupFromSelection() async {
    if (_multiSelectedChannelIds.length < 2) return;
    final controller = TextEditingController();
    // Pre-fill with the first selected channel's name
    final firstChannel = _allChannels
        .where((c) => _multiSelectedChannelIds.contains(c.id))
        .firstOrNull;
    if (firstChannel != null) {
      controller.text = _channelDisplayName(firstChannel);
    }
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Create Smart Channel',
          style: TextStyle(color: Colors.white),
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_multiSelectedChannelIds.length} channels selected. '
                'Streams will auto-switch when buffering is detected.',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Group Name',
                  hintText: 'e.g. ESPN Smart',
                  hintStyle: TextStyle(color: Colors.white24),
                ),
                onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    // Dispose after the dialog exit animation completes to avoid
    // "TextEditingController used after being disposed" errors.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name == null || name.isEmpty || !mounted) return;

    final database = ref.read(databaseProvider);
    final group = await database.createFailoverGroup(name);
    // Preserve selection order as priority
    final orderedIds = _filteredChannels
        .where((c) => _multiSelectedChannelIds.contains(c.id))
        .map((c) => c.id)
        .toList();
    await database.addChannelsToFailoverGroup(group.id, orderedIds);

    setState(() {
      _multiSelectMode = false;
      _multiSelectedChannelIds.clear();
    });
    await _reloadFailoverGroups();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Smart channel "$name" created with ${orderedIds.length} streams',
          ),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          width: 350,
        ),
      );
    }
  }

  Future<void> _addToExistingFailoverGroup() async {
    if (_multiSelectedChannelIds.isEmpty) return;
    final selected = await showModalBottomSheet<db.FailoverGroup>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Add to Smart Channel',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            ..._failoverGroups.map((g) {
              final count = _failoverGroupMembers[g.id]?.length ?? 0;
              return ListTile(
                leading: const Icon(Icons.bolt, color: Colors.amber),
                title: Text(
                  g.name,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '$count channels',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, g),
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;

    final database = ref.read(databaseProvider);
    final existing = _failoverGroupMembers[selected.id] ?? [];
    final newIds = _filteredChannels
        .where(
          (c) =>
              _multiSelectedChannelIds.contains(c.id) &&
              !existing.contains(c.id),
        )
        .map((c) => c.id)
        .toList();
    if (newIds.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'All selected streams are already in this smart channel',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            width: 350,
          ),
        );
      }
      return;
    }
    await database.addChannelsToFailoverGroup(selected.id, newIds);

    setState(() {
      _multiSelectMode = false;
      _multiSelectedChannelIds.clear();
    });
    await _reloadFailoverGroups();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added ${newIds.length} stream${newIds.length == 1 ? '' : 's'} to "${selected.name}"',
          ),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          width: 350,
        ),
      );
    }
  }

  Widget _buildFailoverGroupRow(
    db.FailoverGroup group,
    List<db.Channel> members,
  ) {
    final isExpanded = _expandedFailoverGroups.contains(group.id);
    // Use first member for logo and EPG
    final primary = members.isNotEmpty ? members.first : null;
    String? epgText;
    for (final m in members) {
      epgText = _getChannelNowPlaying(m);
      if (epgText != null) break;
    }
    // Check if any member of this group is currently playing
    final ps = ref.read(playerServiceProvider);
    final isPlaying = members.any(
      (m) =>
          ps.currentChannelId == m.id ||
          (ps.currentChannelId == null && ps.currentUrl == m.streamUrl),
    );
    return Column(
      children: [
        Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            // CENTER/SELECT → play the Smart Channel
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.gameButtonA) {
              if (!_multiSelectMode && members.isNotEmpty) {
                _playFailoverGroup(group, members);
              }
              return KeyEventResult.handled;
            }
            // RIGHT → expand, LEFT → collapse/focus sidebar
            if (key == LogicalKeyboardKey.arrowRight && !isExpanded) {
              setState(() => _expandedFailoverGroups.add(group.id));
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              if (isExpanded) {
                setState(() => _expandedFailoverGroups.remove(group.id));
                return KeyEventResult.handled;
              }
              _sidebarAllItemFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            // MENU / long-press context → show group actions
            if (key == LogicalKeyboardKey.contextMenu ||
                key == LogicalKeyboardKey.f5) {
              _showFailoverGroupActions(group);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return InkWell(
                onTap: () {
                  if (_multiSelectMode) return;
                  if (members.isNotEmpty) _playFailoverGroup(group, members);
                },
                onSecondaryTap: () => _showFailoverGroupActions(group),
                onDoubleTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedFailoverGroups.remove(group.id);
                    } else {
                      _expandedFailoverGroups.add(group.id);
                    }
                  });
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: isPlaying
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.25)
                        : focused
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.15)
                        : null,
                    border: Border.all(
                      color: isPlaying
                          ? const Color(0xFF6C5CE7)
                          : focused
                          ? const Color(0xFF6C5CE7).withValues(alpha: 0.7)
                          : const Color(0xFF6C5CE7).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      // Channel logo from primary member
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child:
                              primary?.tvgLogo != null &&
                                  primary!.tvgLogo!.isNotEmpty
                              ? Image.network(
                                  primary.tvgLogo!,
                                  fit: BoxFit.contain,
                                  cacheWidth: 160,
                                  errorBuilder: (_, __, ___) => Container(
                                    color: const Color(0xFF16213E),
                                    child: const Icon(
                                      Icons.bolt,
                                      size: 18,
                                      color: Colors.amber,
                                    ),
                                  ),
                                )
                              : Container(
                                  color: const Color(0xFF16213E),
                                  child: const Icon(
                                    Icons.bolt,
                                    size: 18,
                                    color: Colors.amber,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Name + EPG
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.bolt,
                                  size: 12,
                                  color: Colors.amber,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    group.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              '${members.length} streams · smart channel',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (epgText != null)
                              Text(
                                epgText,
                                style: const TextStyle(
                                  color: Color(0xFF6C5CE7),
                                  fontSize: 11,
                                ),
                                overflow: TextOverflow.ellipsis,
                              )
                            else if (_epgLoading)
                              const Text(
                                'Loading guide…',
                                style: TextStyle(
                                  color: Colors.white24,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                          ],
                        ),
                      ),
                      // Expand/collapse chevron
                      InkWell(
                        onTap: () {
                          setState(() {
                            if (isExpanded) {
                              _expandedFailoverGroups.remove(group.id);
                            } else {
                              _expandedFailoverGroups.add(group.id);
                            }
                          });
                        },
                        child: Icon(
                          isExpanded ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (isExpanded)
          ...members.asMap().entries.map((entry) {
            final idx = entry.key;
            final ch = entry.value;
            final ps = ref.read(playerServiceProvider);
            final isPlaying =
                ps.currentChannelId == ch.id ||
                (ps.currentChannelId == null && ps.currentUrl == ch.streamUrl);
            return Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.select ||
                      key == LogicalKeyboardKey.enter ||
                      key == LogicalKeyboardKey.gameButtonA) {
                    _playFailoverGroup(group, members, playChannel: ch);
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowLeft) {
                    _sidebarAllItemFocusNode.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.contextMenu ||
                      key == LogicalKeyboardKey.f5) {
                    _showMemberActions(group, ch);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Builder(
                  builder: (context) {
                    final focused = Focus.of(context).hasFocus;
                    return InkWell(
                      onTap: () {
                        _playFailoverGroup(group, members, playChannel: ch);
                      },
                      onSecondaryTap: () => _showMemberActions(group, ch),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: isPlaying
                              ? const Color(0xFF6C5CE7).withValues(alpha: 0.2)
                              : focused
                              ? const Color(0xFF6C5CE7).withValues(alpha: 0.1)
                              : null,
                          borderRadius: BorderRadius.circular(6),
                          border: focused
                              ? Border.all(
                                  color: const Color(
                                    0xFF6C5CE7,
                                  ).withValues(alpha: 0.5),
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            Text(
                              '#${idx + 1}',
                              style: const TextStyle(
                                color: Colors.white24,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(
                                width: 36,
                                height: 24,
                                child:
                                    ch.tvgLogo != null && ch.tvgLogo!.isNotEmpty
                                    ? Image.network(
                                        ch.tvgLogo!,
                                        fit: BoxFit.contain,
                                        cacheWidth: 120,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(
                                              Icons.tv,
                                              size: 14,
                                              color: Colors.white24,
                                            ),
                                      )
                                    : const Icon(
                                        Icons.tv,
                                        size: 14,
                                        color: Colors.white24,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _channelDisplayName(ch),
                                    style: TextStyle(
                                      color: isPlaying
                                          ? Colors.white
                                          : Colors.white60,
                                      fontSize: 13,
                                      fontWeight: isPlaying
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (_getProviderName(
                                    ch.providerId,
                                  ).isNotEmpty)
                                    Text(
                                      _getProviderName(ch.providerId),
                                      style: const TextStyle(
                                        color: Colors.white24,
                                        fontSize: 10,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                            if (isPlaying)
                              const Icon(
                                Icons.play_arrow_rounded,
                                color: Color(0xFF6C5CE7),
                                size: 16,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          }),
      ],
    );
  }

  /// Reload failover group state from DB and update UI immediately.
  Future<void> _reloadFailoverGroups() async {
    final database = ref.read(databaseProvider);
    final foGroups = await database.getAllFailoverGroups();
    final foGroupMembers = <int, List<String>>{};
    for (final g in foGroups) {
      final members = await database.getFailoverGroupMembers(g.id);
      foGroupMembers[g.id] = members.map((m) => m.channelId).toList();
    }
    if (!mounted) return;
    setState(() {
      _failoverGroups = foGroups;
      _failoverGroupMembers = foGroupMembers;
      _applyFilters(); // Re-filter to hide/unhide grouped channels
    });
  }

  void _playFailoverGroup(
    db.FailoverGroup group,
    List<db.Channel> members, {
    db.Channel? playChannel,
  }) {
    if (members.isEmpty) return;
    final target = playChannel ?? members.first;

    final playerService = ref.read(playerServiceProvider);

    playerService.play(
      target.streamUrl,
      channelId: target.id,
      epgChannelId: _getEpgId(target),
      tvgId: target.tvgId,
      channelName: target.name,
      vanityName: _vanityNames[target.id],
      originalName: target.tvgName,
    );

    // Always update preview — grouped channels are filtered out of
    // _filteredChannels so indexWhere returns -1; update state regardless.
    // Clear _selectedIndex so no individual channel row stays highlighted.
    setState(() {
      _selectedIndex = -1;
      _previewChannel = target;
    });
    _showInfoOverlay(target, _selectedIndex);
    _saveSession();
  }

  void _showMemberActions(db.FailoverGroup group, db.Channel channel) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.play_circle_outline,
                color: Colors.white70,
              ),
              title: Text(
                'Play ${_channelDisplayName(channel)}',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(ctx);
                final globalIdx = _filteredChannels.indexWhere(
                  (c) => c.id == channel.id,
                );
                if (globalIdx >= 0) _selectChannel(globalIdx);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.remove_circle_outline,
                color: Colors.orangeAccent,
              ),
              title: const Text(
                'Remove from Smart Channel',
                style: TextStyle(color: Colors.orangeAccent),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final database = ref.read(databaseProvider);
                await database.removeChannelFromFailoverGroup(
                  group.id,
                  channel.id,
                );
                await _reloadFailoverGroups();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Removed "${_channelDisplayName(channel)}" from "${group.name}"',
                      ),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                      width: 350,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFailoverGroupActions(db.FailoverGroup group) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.play_circle_outline,
                color: Colors.white70,
              ),
              title: const Text(
                'Play Smart Channel',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(ctx);
                final members = (_failoverGroupMembers[group.id] ?? [])
                    .map(
                      (id) => _allChannels.where((c) => c.id == id).firstOrNull,
                    )
                    .whereType<db.Channel>()
                    .toList();
                _playFailoverGroup(group, members);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white70),
              title: const Text(
                'Rename',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final controller = TextEditingController(text: group.name);
                final newName = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A2E),
                    title: const Text(
                      'Rename Smart Channel',
                      style: TextStyle(color: Colors.white),
                    ),
                    content: TextFormField(
                      controller: controller,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.pop(ctx, controller.text.trim()),
                        child: const Text('Rename'),
                      ),
                    ],
                  ),
                );
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => controller.dispose(),
                );
                if (newName != null && newName.isNotEmpty && mounted) {
                  final database = ref.read(databaseProvider);
                  await database.renameFailoverGroup(group.id, newName);
                  _reloadFailoverGroups();
                }
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Delete Smart Channel',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A2E),
                    title: const Text(
                      'Delete Smart Channel?',
                      style: TextStyle(color: Colors.white),
                    ),
                    content: Text(
                      'Delete "${group.name}"? The individual streams will be kept.',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  final database = ref.read(databaseProvider);
                  await database.deleteFailoverGroup(group.id);
                  _reloadFailoverGroups();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Favorite list interactions
  // ---------------------------------------------------------------------------

  /// Bottom sheet to add/remove a channel from favorite lists.
  Future<void> _renameChannel(db.Channel channel) async {
    final currentVanity = _vanityNames[channel.id];
    final controller = TextEditingController(
      text: currentVanity ?? channel.name,
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Display Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Original: ${channel.tvgName ?? channel.name}',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
          ],
        ),
        actions: [
          if (currentVanity != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, '\x00RESET'),
              child: const Text('Reset to Original'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (result == null) return;

    if (result == '\x00RESET') {
      // Remove vanity name — revert to original
      _vanityNames.remove(channel.id);
    } else if (result.isNotEmpty && result != channel.name) {
      _vanityNames[channel.id] = result;
    } else {
      return;
    }

    // Persist vanity names
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('channel_vanity_names', jsonEncode(_vanityNames));

    if (!mounted) return;
    setState(() {});
  }

  /// Show inline EPG mapping dialog for a single channel.
  Future<void> _showInlineEpgMapping(db.Channel channel) async {
    final database = ref.read(databaseProvider);
    // Load all EPG channels from all enabled sources
    final sources = await database.getAllEpgSources();
    final candidates = <_EpgCandidate>[];
    for (final src in sources) {
      if (!src.enabled) continue;
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        candidates.add(
          _EpgCandidate(ch.channelId, ch.displayName, src.id, src.name),
        );
      }
    }

    if (!mounted) return;
    final searchCtrl = TextEditingController();
    final result = await showDialog<_EpgCandidate>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = searchCtrl.text.toLowerCase();
          final filtered = query.isEmpty
              ? candidates
              : candidates
                    .where(
                      (c) =>
                          c.displayName.toLowerCase().contains(query) ||
                          c.channelId.toLowerCase().contains(query),
                    )
                    .toList();
          return AlertDialog(
            title: Text('Map: ${channel.name}'),
            content: SizedBox(
              width: 400,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search EPG channels...',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${filtered.length} EPG channels',
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        return ListTile(
                          dense: true,
                          title: Text(c.displayName),
                          subtitle: Text(
                            '${c.channelId} • ${c.sourceName}',
                            style: const TextStyle(fontSize: 10),
                          ),
                          onTap: () => Navigator.pop(ctx, c),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
    searchCtrl.dispose();

    if (result != null && mounted) {
      await database.upsertMapping(
        db.EpgMappingsCompanion.insert(
          channelId: channel.id,
          providerId: channel.providerId,
          epgChannelId: result.channelId,
          epgSourceId: result.sourceId,
          confidence: const Value(1.0),
          source: const Value('manual'),
          locked: const Value(true),
        ),
      );
      await _loadChannels(); // Refresh to pick up new mapping
    }
  }

  /// Show dialog to set EPG timeshift for a channel.
  Future<void> _showTimeshiftDialog(db.Channel channel) async {
    final current = _epgTimeshifts[channel.id] ?? 0;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        int selected = current;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Timeshift EPG'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  channel.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Shift programme times by:',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => setDialogState(() => selected--),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '${selected > 0 ? '+' : ''}${selected}h',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      onPressed: () => setDialogState(() => selected++),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  selected == 0
                      ? 'No shift'
                      : 'Programmes shifted ${selected > 0 ? 'forward' : 'back'} ${selected.abs()}h',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
            actions: [
              if (current != 0)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 0),
                  child: const Text('Reset'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, selected),
                child: const Text('Apply'),
              ),
            ],
          ),
        );
      },
    );
    if (result != null && result != current) {
      setState(() {
        if (result == 0) {
          _epgTimeshifts.remove(channel.id);
        } else {
          _epgTimeshifts[channel.id] = result;
        }
      });
      // Persist timeshifts
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEpgTimeshifts, jsonEncode(_epgTimeshifts));
      _refreshNowPlaying();
    }
  }

  Future<void> _showFavoriteListSheet(db.Channel channel) async {
    final database = ref.read(databaseProvider);
    final listsForChannel = await database.getListsForChannel(channel.id);
    final checkedIds = listsForChannel.map((l) => l.id).toSet();

    if (!mounted) return;
    Timer? autoCloseTimer;
    void resetAutoClose(NavigatorState nav) {
      autoCloseTimer?.cancel();
      autoCloseTimer = Timer(const Duration(seconds: 5), () {
        if (nav.canPop()) nav.pop();
      });
    }

    bool autoCloseStarted = false;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        if (!autoCloseStarted) {
          autoCloseStarted = true;
          resetAutoClose(Navigator.of(ctx));
        }
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: Colors.amber,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Add "${channel.name}" to list',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_favoriteLists.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          'No favorite lists yet',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ),
                    ),
                  ..._favoriteLists.map((list) {
                    final isInList = checkedIds.contains(list.id);
                    return CheckboxListTile(
                      dense: true,
                      value: isInList,
                      activeColor: const Color(0xFFE17055),
                      title: Text(
                        '★ ${list.name}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      onChanged: (val) async {
                        if (val == true) {
                          await database.addChannelToList(list.id, channel.id);
                          checkedIds.add(list.id);
                        } else {
                          await database.removeChannelFromList(
                            list.id,
                            channel.id,
                          );
                          checkedIds.remove(list.id);
                        }
                        setSheetState(() {});
                        resetAutoClose(Navigator.of(ctx));
                      },
                    );
                  }),
                  const Divider(color: Colors.white12),
                  TextButton.icon(
                    onPressed: () async {
                      autoCloseTimer?.cancel();
                      final name = await _showCreateListDialog();
                      if (name != null && name.isNotEmpty) {
                        final newList = await database.createFavoriteList(name);
                        await database.addChannelToList(newList.id, channel.id);
                        checkedIds.add(newList.id);
                        // Reload lists
                        final updated = await database.getAllFavoriteLists();
                        setState(() => _favoriteLists = updated);
                        setSheetState(() {});
                      }
                      if (ctx.mounted) resetAutoClose(Navigator.of(ctx));
                    },
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Create new list'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.cyanAccent,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
    autoCloseTimer?.cancel();
    // Refresh favorited state after sheet closes
    final favIds = await database.getAllFavoritedChannelIds();
    if (mounted) {
      setState(() {
        _favoritedChannelIds = favIds;
        _applyFilters();
      });
    }
  }

  /// Dialog to create a new favorite list — returns the name or null.
  Future<String?> _showCreateListDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text(
          'New Favorite List',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. Sports, News, Kids',
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: Colors.white12,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text(
              'Create',
              style: TextStyle(color: Colors.cyanAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// Dialog to manage (create/rename/delete) favorite lists.
  Future<void> _showManageFavoritesDialog() async {
    final database = ref.read(databaseProvider);
    var lists = List<db.FavoriteList>.from(_favoriteLists);

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF16213E),
              title: Row(
                children: [
                  const Icon(Icons.star_rounded, color: Colors.amber, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Manage Favorite Lists',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.add_rounded,
                      color: Colors.cyanAccent,
                      size: 20,
                    ),
                    tooltip: 'Create new list',
                    onPressed: () async {
                      final name = await _showCreateListDialog();
                      if (name != null && name.isNotEmpty) {
                        await database.createFavoriteList(name);
                        lists = await database.getAllFavoriteLists();
                        setDialogState(() {});
                      }
                    },
                  ),
                ],
              ),
              content: SizedBox(
                width: 340,
                child: lists.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No favorite lists yet.\nTap + to create one.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38),
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        shrinkWrap: true,
                        itemCount: lists.length,
                        onReorder: (oldIdx, newIdx) async {
                          if (newIdx > oldIdx) newIdx--;
                          final item = lists.removeAt(oldIdx);
                          lists.insert(newIdx, item);
                          setDialogState(() {});
                          // Persist new sort order
                          for (var i = 0; i < lists.length; i++) {
                            await (database.update(
                              database.favoriteLists,
                            )..where((t) => t.id.equals(lists[i].id))).write(
                              db.FavoriteListsCompanion(sortOrder: Value(i)),
                            );
                          }
                        },
                        itemBuilder: (ctx, index) {
                          final list = lists[index];
                          return ListTile(
                            key: ValueKey(list.id),
                            leading: const Icon(
                              Icons.drag_handle_rounded,
                              color: Colors.white38,
                              size: 18,
                            ),
                            title: Text(
                              '★ ${list.name}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit_rounded,
                                    size: 16,
                                    color: Colors.white38,
                                  ),
                                  tooltip: 'Rename',
                                  onPressed: () async {
                                    final newName = await _showRenameDialog(
                                      list.name,
                                    );
                                    if (newName != null && newName.isNotEmpty) {
                                      await database.renameFavoriteList(
                                        list.id,
                                        newName,
                                      );
                                      lists = await database
                                          .getAllFavoriteLists();
                                      setDialogState(() {});
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 16,
                                    color: Colors.redAccent,
                                  ),
                                  tooltip: 'Delete',
                                  onPressed: () async {
                                    final confirmed =
                                        await _showDeleteConfirmation(
                                          list.name,
                                        );
                                    if (confirmed == true) {
                                      await database.deleteFavoriteList(
                                        list.id,
                                      );
                                      lists = await database
                                          .getAllFavoriteLists();
                                      setDialogState(() {});
                                    }
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    'Done',
                    style: TextStyle(color: Colors.cyanAccent),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    // Refresh lists after dialog closes
    final updated = await database.getAllFavoriteLists();
    final favIds = await database.getAllFavoritedChannelIds();
    if (mounted) {
      setState(() {
        _favoriteLists = updated;
        _favoritedChannelIds = favIds;
        _applyFilters();
      });
    }
  }

  Future<String?> _showRenameDialog(String currentName) async {
    final controller = TextEditingController(text: currentName);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF16213E),
          title: const Text(
            'Rename List',
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white12,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text(
                'Rename',
                style: TextStyle(color: Colors.cyanAccent),
              ),
            ),
          ],
        ),
      );
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  Future<bool?> _showDeleteConfirmation(String listName) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text(
          'Delete List?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Are you sure you want to delete "$listName"?\nChannels will not be deleted.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Inline guide view
  // ---------------------------------------------------------------------------

  static const _pixelsPerMinute = 3.0;

  Widget _buildGuideView() {
    if (_filteredChannels.isEmpty) {
      return const Center(
        child: Text(
          'No channels match your filter',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    final database = ref.read(databaseProvider);
    // Timeline spans a few hours of past (reachable by dragging left) up to a
    // day of future, so there's always enough width to scroll the current time
    // to the left edge (the default view).
    final dayStart = DateTime.now().subtract(const Duration(hours: 3));
    final dayEnd = DateTime.now().add(const Duration(hours: 24));

    final totalMinutes = dayEnd.difference(dayStart).inMinutes;
    final totalWidth = totalMinutes * _pixelsPerMinute;

    // Auto-scroll to "now" when guide view opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_guideScrollController.hasClients &&
          _guideScrollController.position.pixels == 0.0) {
        final now = DateTime.now();
        final nowMinFromStart = now.difference(dayStart).inMinutes;
        // Default view: keep ~30 minutes before "now" visible on the left so
        // the currently-airing programme isn't clipped; further past is
        // reachable by dragging left.
        final target = ((nowMinFromStart - 30) * _pixelsPerMinute).clamp(
          0.0,
          _guideScrollController.position.maxScrollExtent,
        );
        _guideScrollController.jumpTo(target);
      }
    });

    final now = DateTime.now();
    final nowMinFromStart = now.difference(dayStart).inMinutes;
    final nowOffset = nowMinFromStart * _pixelsPerMinute;

    return Column(
      children: [
        // Time ruler row with "now" marker
        SizedBox(
          height: 28,
          child: Row(
            children: [
              const SizedBox(width: 200),
              Expanded(
                child: SingleChildScrollView(
                  controller: _guideScrollController,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: totalWidth,
                    child: Stack(
                      children: [
                        // Hour labels
                        ...() {
                          final labels = <Widget>[];
                          var t = DateTime(
                            dayStart.year,
                            dayStart.month,
                            dayStart.day,
                            dayStart.hour,
                          );
                          if (t.isBefore(dayStart))
                            t = t.add(const Duration(hours: 1));
                          while (t.isBefore(dayEnd)) {
                            final offsetMin = t.difference(dayStart).inMinutes;
                            labels.add(
                              Positioned(
                                left: offsetMin * _pixelsPerMinute,
                                top: 0,
                                bottom: 0,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _formatTime(t),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                            t = t.add(const Duration(hours: 1));
                          }
                          return labels;
                        }(),
                        // "Now" marker with time label
                        Positioned(
                          left: nowOffset - 18,
                          top: 0,
                          bottom: 0,
                          child: SizedBox(
                            width: 36,
                            child: Center(
                              child: Text(
                                _formatTime(now),
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        // Channel rows — single ListView, each item has name + programmes
        Expanded(
          child: GestureDetector(
            onHorizontalDragUpdate: (details) {
              if (_guideScrollController.hasClients) {
                final newOffset =
                    (_guideScrollController.offset - details.delta.dx).clamp(
                      0.0,
                      _guideScrollController.position.maxScrollExtent,
                    );
                _guideScrollController.jumpTo(newOffset);
              }
              _resetGuideIdleTimer(dayStart);
            },
            onHorizontalDragEnd: (_) => _resetGuideIdleTimer(dayStart),
            child: ListenableBuilder(
              listenable: _guideScrollController,
              builder: (context, _) {
                final hOffset = _guideScrollController.hasClients
                    ? _guideScrollController.offset
                    : 0.0;
                return Stack(
                  children: [
                    ListView.builder(
                      itemCount:
                          _filteredChannels.length + _guideFailoverGroupCount,
                      itemBuilder: (context, index) {
                        // Inject failover group rows at the top
                        if (index < _guideFailoverGroupCount) {
                          return _buildGuideFailoverGroupRow(
                            index,
                            database,
                            hOffset,
                            dayStart,
                            dayEnd,
                            totalMinutes: totalMinutes,
                            totalWidth: totalWidth,
                          );
                        }
                        index = index - _guideFailoverGroupCount;
                        final channel = _filteredChannels[index];
                        final isFav = _favoritedChannelIds.contains(channel.id);
                        final isSelected = index == _selectedIndex;
                        return Focus(
                          focusNode: index == 0 ? _firstChannelFocusNode : null,
                          autofocus: index == 0 && Platform.isAndroid,
                          onFocusChange: (hasFocus) {
                            if (hasFocus && Platform.isAndroid)
                              _selectChannel(index);
                          },
                          onKeyEvent: (node, event) {
                            final key = event.logicalKey;
                            final isCenterKey =
                                key == LogicalKeyboardKey.select ||
                                key == LogicalKeyboardKey.enter ||
                                key == LogicalKeyboardKey.gameButtonA;

                            // Long-press CENTER on TV remote → enter/toggle multi-select
                            if (Platform.isAndroid && isCenterKey) {
                              if (event is KeyDownEvent) {
                                _longPressChannelId = channel.id;
                                _longPressTimer?.cancel();
                                _longPressTimer = Timer(
                                  const Duration(milliseconds: 400),
                                  () {
                                    if (!mounted) return;
                                    setState(() {
                                      if (!_multiSelectMode) {
                                        _multiSelectMode = true;
                                        _multiSelectedChannelIds = {channel.id};
                                      } else {
                                        if (_multiSelectedChannelIds.contains(
                                          channel.id,
                                        )) {
                                          _multiSelectedChannelIds.remove(
                                            channel.id,
                                          );
                                        } else {
                                          _multiSelectedChannelIds.add(
                                            channel.id,
                                          );
                                        }
                                      }
                                    });
                                    _longPressChannelId = null;
                                  },
                                );
                                return KeyEventResult.handled;
                              }
                              if (event is KeyUpEvent) {
                                final wasLongPress =
                                    _longPressChannelId == null;
                                _longPressTimer?.cancel();
                                _longPressTimer = null;
                                _longPressChannelId = null;
                                if (wasLongPress) return KeyEventResult.handled;
                                if (_multiSelectMode) {
                                  setState(() {
                                    if (_multiSelectedChannelIds.contains(
                                      channel.id,
                                    )) {
                                      _multiSelectedChannelIds.remove(
                                        channel.id,
                                      );
                                    } else {
                                      _multiSelectedChannelIds.add(channel.id);
                                    }
                                  });
                                } else {
                                  _goFullscreen(channel);
                                }
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.handled;
                            }

                            if (event is! KeyDownEvent)
                              return KeyEventResult.ignored;
                            if (isCenterKey) {
                              if (_multiSelectMode) {
                                setState(() {
                                  if (_multiSelectedChannelIds.contains(
                                    channel.id,
                                  )) {
                                    _multiSelectedChannelIds.remove(channel.id);
                                  } else {
                                    _multiSelectedChannelIds.add(channel.id);
                                  }
                                });
                              } else {
                                _goFullscreen(channel);
                              }
                              return KeyEventResult.handled;
                            }
                            if (key == LogicalKeyboardKey.arrowLeft) {
                              _sidebarAllItemFocusNode.requestFocus();
                              return KeyEventResult.handled;
                            }
                            // BACK exits multi-select mode
                            if (_multiSelectMode &&
                                key == LogicalKeyboardKey.goBack) {
                              setState(() {
                                _multiSelectMode = false;
                                _multiSelectedChannelIds.clear();
                              });
                              return KeyEventResult.handled;
                            }
                            // MENU/contextMenu/F5 → toggle multi-select
                            if (key == LogicalKeyboardKey.contextMenu ||
                                key == LogicalKeyboardKey.f5) {
                              setState(() {
                                if (!_multiSelectMode) {
                                  _multiSelectMode = true;
                                  _multiSelectedChannelIds = {channel.id};
                                } else {
                                  if (_multiSelectedChannelIds.contains(
                                    channel.id,
                                  )) {
                                    _multiSelectedChannelIds.remove(channel.id);
                                  } else {
                                    _multiSelectedChannelIds.add(channel.id);
                                  }
                                }
                              });
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: Builder(
                            builder: (context) {
                              final hasFocus = Focus.of(context).hasFocus;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  // Check modifier keys for multi-select
                                  final hwPressed = HardwareKeyboard
                                      .instance
                                      .logicalKeysPressed;
                                  // ignore: deprecated_member_use
                                  final rawPressed =
                                      RawKeyboard.instance.keysPressed;
                                  final shiftOrCmd =
                                      hwPressed.contains(
                                        LogicalKeyboardKey.shiftLeft,
                                      ) ||
                                      hwPressed.contains(
                                        LogicalKeyboardKey.shiftRight,
                                      ) ||
                                      hwPressed.contains(
                                        LogicalKeyboardKey.metaLeft,
                                      ) ||
                                      hwPressed.contains(
                                        LogicalKeyboardKey.metaRight,
                                      ) ||
                                      rawPressed.contains(
                                        LogicalKeyboardKey.shiftLeft,
                                      ) ||
                                      rawPressed.contains(
                                        LogicalKeyboardKey.shiftRight,
                                      ) ||
                                      rawPressed.contains(
                                        LogicalKeyboardKey.metaLeft,
                                      ) ||
                                      rawPressed.contains(
                                        LogicalKeyboardKey.metaRight,
                                      );
                                  try {
                                    File(
                                      '/tmp/click_debug.log',
                                    ).writeAsStringSync(
                                      '${DateTime.now()} GUIDE-TAP ch=${channel.name} shift=$shiftOrCmd multiMode=$_multiSelectMode hw=${hwPressed.map((k) => k.debugName).join(",")}\n',
                                      mode: FileMode.append,
                                    );
                                  } catch (_) {}
                                  if (shiftOrCmd) {
                                    setState(() {
                                      if (!_multiSelectMode) {
                                        _multiSelectMode = true;
                                        _multiSelectedChannelIds = {channel.id};
                                      } else {
                                        if (_multiSelectedChannelIds.contains(
                                          channel.id,
                                        )) {
                                          _multiSelectedChannelIds.remove(
                                            channel.id,
                                          );
                                        } else {
                                          _multiSelectedChannelIds.add(
                                            channel.id,
                                          );
                                        }
                                      }
                                    });
                                  } else if (_multiSelectMode) {
                                    setState(() {
                                      if (_multiSelectedChannelIds.contains(
                                        channel.id,
                                      )) {
                                        _multiSelectedChannelIds.remove(
                                          channel.id,
                                        );
                                      } else {
                                        _multiSelectedChannelIds.add(
                                          channel.id,
                                        );
                                      }
                                    });
                                  } else {
                                    _selectChannel(index);
                                  }
                                },
                                onSecondaryTapUp: (details) =>
                                    _showGuideChannelMenu(
                                      channel,
                                      details.globalPosition,
                                    ),
                                onLongPress: _multiSelectMode
                                    ? null
                                    : () {
                                        if (Platform.isAndroid) {
                                          setState(() {
                                            _multiSelectMode = true;
                                            _multiSelectedChannelIds = {
                                              channel.id,
                                            };
                                          });
                                        }
                                      },
                                child: Container(
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color:
                                        (_multiSelectMode &&
                                            _multiSelectedChannelIds.contains(
                                              channel.id,
                                            ))
                                        ? const Color(
                                            0xFF6C5CE7,
                                          ).withValues(alpha: 0.25)
                                        : isSelected
                                        ? const Color(
                                            0xFF6C5CE7,
                                          ).withValues(alpha: 0.25)
                                        : hasFocus
                                        ? const Color(
                                            0xFF6C5CE7,
                                          ).withValues(alpha: 0.15)
                                        : Colors.transparent,
                                    border: Border(
                                      bottom: const BorderSide(
                                        color: Colors.white10,
                                        width: 0.5,
                                      ),
                                      left: isSelected
                                          ? const BorderSide(
                                              color: Color(0xFF6C5CE7),
                                              width: 3,
                                            )
                                          : hasFocus
                                          ? const BorderSide(
                                              color: Color(0xFF6C5CE7),
                                              width: 2,
                                            )
                                          : BorderSide.none,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      if (_multiSelectMode)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 4,
                                            right: 4,
                                          ),
                                          child: Icon(
                                            _multiSelectedChannelIds.contains(
                                                  channel.id,
                                                )
                                                ? Icons.check_box
                                                : Icons.check_box_outline_blank,
                                            size: 18,
                                            color:
                                                _multiSelectedChannelIds
                                                    .contains(channel.id)
                                                ? const Color(0xFF6C5CE7)
                                                : Colors.white38,
                                          ),
                                        ),
                                      // Fixed channel name
                                      Container(
                                        width: 200,
                                        decoration: const BoxDecoration(
                                          border: Border(
                                            right: BorderSide(
                                              color: Colors.white10,
                                              width: 0.5,
                                            ),
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                        child: Row(
                                          children: [
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              child:
                                                  channel.tvgLogo != null &&
                                                      channel
                                                          .tvgLogo!
                                                          .isNotEmpty
                                                  ? Image.network(
                                                      channel.tvgLogo!,
                                                      width: 44,
                                                      height: 28,
                                                      fit: BoxFit.contain,
                                                      cacheWidth: 128,
                                                      errorBuilder:
                                                          (
                                                            _,
                                                            __,
                                                            ___,
                                                          ) => Container(
                                                            width: 44,
                                                            height: 28,
                                                            color: const Color(
                                                              0xFF16213E,
                                                            ),
                                                            child: const Icon(
                                                              Icons.tv,
                                                              size: 14,
                                                              color: Colors
                                                                  .white24,
                                                            ),
                                                          ),
                                                    )
                                                  : Container(
                                                      width: 44,
                                                      height: 28,
                                                      color: const Color(
                                                        0xFF16213E,
                                                      ),
                                                      child: const Icon(
                                                        Icons.tv,
                                                        size: 14,
                                                        color: Colors.white24,
                                                      ),
                                                    ),
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    channel.name,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: isSelected
                                                          ? Colors.white
                                                          : Colors.white70,
                                                      fontWeight: isSelected
                                                          ? FontWeight.bold
                                                          : FontWeight.normal,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  Text(
                                                    [
                                                      _getProviderName(
                                                        channel.providerId,
                                                      ),
                                                      if (channel.groupTitle !=
                                                              null &&
                                                          channel
                                                              .groupTitle!
                                                              .isNotEmpty)
                                                        channel.groupTitle!,
                                                    ].join(' · '),
                                                    style: const TextStyle(
                                                      fontSize: 9,
                                                      color: Colors.white30,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  if (isFav)
                                                    const Icon(
                                                      Icons.star_rounded,
                                                      color: Colors.amber,
                                                      size: 12,
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Programme blocks — clipped + translated
                                      Expanded(
                                        child: LayoutBuilder(
                                          builder: (context, constraints) {
                                            return ClipRect(
                                              child: Stack(
                                                clipBehavior: Clip.hardEdge,
                                                children: [
                                                  Positioned(
                                                    left: -hOffset,
                                                    top: 0,
                                                    bottom: 0,
                                                    width: totalWidth,
                                                    child:
                                                        _buildGuideRowProgrammes(
                                                          channel,
                                                          database,
                                                          dayStart,
                                                          dayEnd,
                                                          totalMinutes:
                                                              totalMinutes,
                                                          totalWidth:
                                                              totalWidth,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }, // Builder builder
                          ), // Builder
                        ); // Focus
                      },
                    ),
                    // "Now" vertical line overlay
                    Positioned(
                      left: 200 + nowOffset - hOffset,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          width: 1.5,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _showGuideChannelMenu(db.Channel channel, Offset position) {
    final isFav = _favoritedChannelIds.contains(channel.id);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'play',
          child: Row(
            children: [
              const Icon(Icons.play_arrow, size: 18),
              const SizedBox(width: 8),
              const Text('Play'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'fullscreen',
          child: Row(
            children: [
              const Icon(Icons.fullscreen, size: 18),
              const SizedBox(width: 8),
              const Text('Fullscreen'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'favorite',
          child: Row(
            children: [
              Icon(
                isFav ? Icons.star : Icons.star_border,
                size: 18,
                color: Colors.amber,
              ),
              const SizedBox(width: 8),
              Text(isFav ? 'Remove from Favorites' : 'Add to Favorites...'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'epg_map',
          child: Row(
            children: [
              const Icon(Icons.link, size: 18),
              const SizedBox(width: 8),
              const Text('Map to EPG...'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'reminder',
          child: Row(
            children: [
              const Icon(Icons.alarm, size: 18),
              const SizedBox(width: 8),
              const Text('Set Reminder'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'record',
          child: Row(
            children: [
              const Icon(
                Icons.fiber_manual_record,
                size: 18,
                color: Colors.red,
              ),
              const SizedBox(width: 8),
              const Text('Record'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              const Icon(Icons.edit, size: 18),
              const SizedBox(width: 8),
              const Text('Rename Channel'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'timeshift',
          child: Row(
            children: [
              const Icon(Icons.schedule, size: 18),
              const SizedBox(width: 8),
              Text(
                'Timeshift EPG${_epgTimeshifts.containsKey(channel.id) ? ' (${_epgTimeshifts[channel.id]! > 0 ? '+' : ''}${_epgTimeshifts[channel.id]!}h)' : ''}',
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'debug',
          child: Row(
            children: [
              const Icon(Icons.bug_report, size: 18),
              const SizedBox(width: 8),
              const Text('Debug Info'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null || !mounted) return;
      switch (value) {
        case 'play':
          final idx = _filteredChannels.indexOf(channel);
          if (idx >= 0) _selectChannel(idx);
        case 'fullscreen':
          final idx = _filteredChannels.indexOf(channel);
          if (idx >= 0) {
            _selectChannel(idx);
            _goFullscreen(channel);
          }
        case 'favorite':
          _showFavoriteListSheet(channel);
        case 'epg_map':
          _showInlineEpgMapping(channel);
        case 'reminder':
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reminders coming soon')),
          );
        case 'record':
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recording coming soon')),
          );
        case 'rename':
          _renameChannel(channel);
        case 'timeshift':
          _showTimeshiftDialog(channel);
        case 'debug':
          final ps = ref.read(playerServiceProvider);
          ChannelDebugDialog.show(
            context,
            channel,
            ps,
            mappedEpgId: _getEpgId(channel),
            originalName: channel.tvgName ?? channel.name,
            currentProviderName: ref
                .read(streamAlternativesProvider)
                .providerName(channel.providerId),
            alternatives: _getFailoverAlts(channel),
          );
      }
    });
  }

  Widget _buildGuideRowProgrammes(
    db.Channel channel,
    db.AppDatabase database,
    DateTime dayStart,
    DateTime dayEnd, {
    required int totalMinutes,
    required double totalWidth,
  }) {
    final epgId = _getEpgId(channel);
    if (epgId == null) {
      return const Center(
        child: Text(
          'No EPG',
          style: TextStyle(fontSize: 10, color: Colors.white24),
        ),
      );
    }

    final shiftHours = _epgTimeshifts[channel.id] ?? 0;
    final fetchShift = Duration(hours: shiftHours);

    // Reuse the same future across rebuilds. `dayStart` moves every build
    // (DateTime.now()), so bucket the key to the hour. Roll over hourly /
    // across days; clearing on rollover bounds cache growth.
    final bucket = DateTime(
      dayStart.year,
      dayStart.month,
      dayStart.day,
      dayStart.hour,
    ).millisecondsSinceEpoch;
    if (_programmeCacheBucket != bucket) {
      _programmeCacheBucket = bucket;
      _programmeFutureCache.clear();
    }
    final cacheKey = '$epgId|$shiftHours|$bucket';

    var programmesFuture = _programmeFutureCache[cacheKey];
    if (programmesFuture == null) {
      final created = database.getProgrammes(
        epgChannelId: epgId,
        start: dayStart.subtract(fetchShift),
        end: dayEnd.subtract(fetchShift),
      );
      _programmeFutureCache[cacheKey] = created;
      // Pin only successful, non-empty results. Drop empty/error so the next
      // build retries once EPG data lands (prevents pinning a premature empty).
      created
          .then((list) {
            if (list.isEmpty &&
                identical(_programmeFutureCache[cacheKey], created)) {
              _programmeFutureCache.remove(cacheKey);
            }
          })
          .catchError((Object _) {
            if (identical(_programmeFutureCache[cacheKey], created)) {
              _programmeFutureCache.remove(cacheKey);
            }
          });
      programmesFuture = created;
    }

    return FutureBuilder<List<db.EpgProgramme>>(
      future: programmesFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(
            child: Text(
              'No EPG data',
              style: TextStyle(fontSize: 10, color: Colors.white24),
            ),
          );
        }

        final programmes = snapshot.data!;
        final now = DateTime.now();
        final shift = Duration(hours: _epgTimeshifts[channel.id] ?? 0);

        return SizedBox(
          width: totalWidth,
          child: Stack(
            children: programmes.map((prog) {
              final shiftedStart = prog.start.add(shift);
              final shiftedStop = prog.stop.add(shift);
              final startMin = shiftedStart
                  .difference(dayStart)
                  .inMinutes
                  .clamp(0, totalMinutes);
              final endMin = shiftedStop
                  .difference(dayStart)
                  .inMinutes
                  .clamp(0, totalMinutes);
              final durationMin = (endMin - startMin).clamp(1, totalMinutes);
              final left = startMin * _pixelsPerMinute;
              final width = durationMin * _pixelsPerMinute;
              final isCurrent =
                  now.isAfter(shiftedStart) && now.isBefore(shiftedStop);

              // For the current programme, clamp text so it stays visible
              // when the cell starts before the visible scroll area
              double textPadLeft = 4.0;
              if (isCurrent && _guideScrollController.hasClients) {
                final scrollOffset = _guideScrollController.position.pixels;
                if (left < scrollOffset && left + width > scrollOffset) {
                  textPadLeft = (scrollOffset - left) + 4.0;
                  // Don't push text past 60% of cell width
                  textPadLeft = textPadLeft.clamp(4.0, width * 0.6);
                }
              }

              return Positioned(
                left: left,
                width: width,
                top: 2,
                bottom: 2,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 0.5),
                  padding: EdgeInsets.only(
                    left: textPadLeft,
                    right: 4,
                    top: 2,
                    bottom: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? const Color(0xFF6C5CE7).withValues(alpha: 0.3)
                        : const Color(0xFF16213E),
                    borderRadius: BorderRadius.circular(3),
                    border: isCurrent
                        ? Border.all(color: const Color(0xFF6C5CE7), width: 1)
                        : null,
                  ),
                  child: Text(
                    prog.title,
                    style: TextStyle(
                      fontSize: 10,
                      color: isCurrent ? Colors.white : Colors.white54,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  void _renameFavoriteList(db.FavoriteList list) async {
    final controller = TextEditingController(text: list.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Rename List', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 300,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'List name',
              hintStyle: TextStyle(color: Colors.white38),
            ),
            onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (newName != null && newName.isNotEmpty && newName != list.name) {
      if (!mounted) return;
      final database = ref.read(databaseProvider);
      await database.renameFavoriteList(list.id, newName);
      if (!mounted) return;
      _loadChannels();
    }
  }
}

/// Helper for inline EPG mapping dialog.
class _EpgCandidate {
  final String channelId;
  final String displayName;
  final String sourceId;
  final String sourceName;
  const _EpgCandidate(
    this.channelId,
    this.displayName,
    this.sourceId,
    this.sourceName,
  );
}

/// Reads mpv properties to show resolution, aspect ratio, and audio channel badges.
class _StreamInfoBadges extends StreamInfoBadges {
  const _StreamInfoBadges({required super.playerService});
}

/// Compact, periodically-refreshing technical badges (resolution, fps, codec,
/// audio channels) used in the inline preview overlay's top bar.
class _PreviewInfoBadges extends StatefulWidget {
  final dynamic playerService;
  const _PreviewInfoBadges({required this.playerService});

  @override
  State<_PreviewInfoBadges> createState() => _PreviewInfoBadgesState();
}

class _PreviewInfoBadgesState extends State<_PreviewInfoBadges> {
  Timer? _timer;
  String? _resolution;
  String? _fps;
  String? _codec;
  String? _audio;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final ps = widget.playerService;
    final results = await Future.wait<String?>([
      ps.getMpvProperty('video-params/h') as Future<String?>,
      ps.getMpvProperty('estimated-vf-fps') as Future<String?>,
      ps.getMpvProperty('video-codec') as Future<String?>,
      ps.getMpvProperty('audio-params/channel-count') as Future<String?>,
    ]);
    if (!mounted) return;
    setState(() {
      final h = int.tryParse(results[0] ?? '') ?? 0;
      _resolution = h >= 2160 ? '4K' : (h > 0 ? '${h}p' : null);
      final fps = double.tryParse(results[1] ?? '');
      _fps = fps != null ? '${fps.toStringAsFixed(0)} fps' : null;
      final codec = results[2] ?? '';
      _codec = codec.isNotEmpty ? codec.split(' ').first.toUpperCase() : null;
      final aCh = int.tryParse(results[3] ?? '') ?? 0;
      _audio = aCh == 2
          ? '2.0'
          : aCh == 6
          ? '5.1'
          : aCh == 8
          ? '7.1'
          : aCh == 1
          ? 'Mono'
          : (aCh > 0 ? '${aCh}ch' : null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final badges = <String>[
      ?_resolution,
      ?_fps,
      ?_codec,
      ?_audio,
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: badges
          .map(
            (b) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white24, width: 0.5),
              ),
              child: Text(
                b,
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

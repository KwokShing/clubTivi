import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:shared_preferences/shared_preferences.dart';

import 'player_service.dart';

/// Adaptive per-stream buffer manager.
///
/// Monitors `demuxer-cache-duration` to gauge stream health and adjusts
/// mpv buffer properties bidirectionally across three tiers:
///   - **fast**:       Small buffer, fast channel switching (good streams)
///   - **normal**:     Default balanced buffer
///   - **aggressive**: Large buffer for flaky streams
///
/// Tier is persisted per stream URL so returning to a channel uses the
/// learned profile immediately. Tiers float both ways based on a rolling
/// window of buffer health observations.
class AdaptiveBufferManager {
  static const _prefsKey = 'adaptive_buffer_profiles';

  // Buffer tier definitions (mpv properties)
  //
  // VOD tiers: never pause playback on empty buffer — keep playing and let
  // the stream recover naturally or trigger auto-failover instead. Large
  // readahead is fine because VOD playlists expose the whole file.
  // Tiers differ only in readahead aggressiveness.
  //
  // Byte caps are the real memory ceiling. Live streams misclassified as VOD
  // (any non-.m3u8 URL) previously inherited 800M forward + 200M back = ~1 GB
  // of demuxer cache that mpv pins for the whole session — which reads as a
  // runaway memory leak. Caps are kept modest here so total demuxer memory
  // stays bounded (well under ~300 MB) regardless of classification; tiers
  // still float readahead to trade latency for resilience on flaky streams.
  static const _tierConfig = <String, Map<String, String>>{
    'fast': {
      'cache': 'yes',
      'cache-secs': '60',
      'cache-pause': 'no',
      'cache-pause-initial': 'no',
      'cache-pause-wait': '0',
      'demuxer-max-bytes': '96M',
      'demuxer-max-back-bytes': '32M',
      'demuxer-readahead-secs': '60',
    },
    'normal': {
      'cache': 'yes',
      'cache-secs': '120',
      'cache-pause': 'no',
      'cache-pause-initial': 'no',
      'cache-pause-wait': '0',
      'demuxer-max-bytes': '160M',
      'demuxer-max-back-bytes': '48M',
      'demuxer-readahead-secs': '120',
    },
    'aggressive': {
      'cache': 'yes',
      'cache-secs': '180',
      'cache-pause': 'no',
      'cache-pause-initial': 'no',
      'cache-pause-wait': '0',
      'demuxer-max-bytes': '256M',
      'demuxer-max-back-bytes': '64M',
      'demuxer-readahead-secs': '180',
    },
  };

  // Live tier definitions (mpv properties)
  //
  // Live HLS exposes only a short sliding window (often ~30-40s), so huge
  // readahead/cache targets are pointless and can never be reached. More
  // importantly, heavy live streams (e.g. 4K60 10-bit HEVC ~20 Mbps) need a
  // primed buffer before the first frame — mirroring bare mpv's defaults:
  //   - cache-pause-initial: build a small buffer before starting playback
  //   - cache-pause: re-buffer on underrun instead of stuttering forever
  // Prolonged stalls still surface through the buffering stream and trigger
  // auto-failover, so failover behavior is preserved.
  static const _liveTierConfig = <String, Map<String, String>>{
    'fast': {
      'cache': 'yes',
      'cache-secs': '20',
      'cache-pause': 'yes',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': '1',
      'demuxer-max-bytes': '96M',
      'demuxer-max-back-bytes': '32M',
      'demuxer-readahead-secs': '10',
    },
    'normal': {
      'cache': 'yes',
      'cache-secs': '30',
      'cache-pause': 'yes',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': '1',
      'demuxer-max-bytes': '128M',
      'demuxer-max-back-bytes': '48M',
      'demuxer-readahead-secs': '20',
    },
    'aggressive': {
      'cache': 'yes',
      'cache-secs': '60',
      'cache-pause': 'yes',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': '2',
      'demuxer-max-bytes': '256M',
      'demuxer-max-back-bytes': '64M',
      'demuxer-readahead-secs': '40',
    },
  };

  static const _tierOrder = ['fast', 'normal', 'aggressive'];

  /// Seconds of stable buffer before downgrading tier.
  static const _downgradeAfterStableSecs = 60;

  /// Number of low-buffer observations before upgrading tier.
  static const _upgradeAfterStallCount = 3;

  /// Cache duration below which we consider the buffer stressed.
  static const _lowBufferThreshold = 1.5;

  /// Cache duration above which we consider the buffer healthy.
  static const _healthyBufferThreshold = 4.0;

  Timer? _monitorTimer;
  String _currentTier = 'normal';
  String? _currentUrl;

  /// Whether the active stream is live (HLS without ENDLIST / short window).
  /// Selects the live tier table, which primes a small buffer before play.
  bool _isLive = false;

  // Health tracking — reset per stream
  int _stableSeconds = 0;
  int _stallCount = 0;

  /// Current tier for display/debugging.
  String get currentTier => _currentTier;

  /// Apply buffer settings for a stream URL and begin monitoring.
  ///
  /// [isLive] selects the live tier table (small buffer + initial pause) so
  /// heavy live streams prime properly; VOD keeps the large-readahead tiers.
  Future<void> applyForStream(
    String url,
    PlayerService ps, {
    bool isLive = false,
  }) async {
    _monitorTimer?.cancel();
    _currentUrl = url;
    _isLive = isLive;
    _stableSeconds = 0;
    _stallCount = 0;

    // Load saved tier or default to 'normal'
    _currentTier = await _loadTier(url);
    await _applyTier(_currentTier, ps);
    _startMonitoring(url, ps);
  }

  /// Stop monitoring (call on stream stop or dispose).
  void stop() {
    _monitorTimer?.cancel();
    _currentUrl = null;
  }

  // ---------------------------------------------------------------------------
  // Monitoring loop
  // ---------------------------------------------------------------------------

  void _startMonitoring(String url, PlayerService ps) {
    _monitorTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_currentUrl != url) return; // stream changed

      final raw = await ps.getMpvProperty('demuxer-cache-duration');
      final cacheSecs = double.tryParse(raw ?? '');
      if (cacheSecs == null) return; // not available yet

      if (cacheSecs < _lowBufferThreshold) {
        // Buffer stressed
        _stallCount++;
        _stableSeconds = 0;

        if (_stallCount >= _upgradeAfterStallCount) {
          final upgraded = _upgradeTier();
          if (upgraded) {
            await _applyTier(_currentTier, ps);
            await _saveTier(url, _currentTier);
            _stallCount = 0;
          }
        }
      } else if (cacheSecs > _healthyBufferThreshold) {
        // Buffer healthy
        _stableSeconds += 2;
        _stallCount = (_stallCount > 0) ? _stallCount - 1 : 0;

        if (_stableSeconds >= _downgradeAfterStableSecs) {
          final downgraded = _downgradeTier();
          if (downgraded) {
            await _applyTier(_currentTier, ps);
            await _saveTier(url, _currentTier);
          }
          _stableSeconds = 0;
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Tier management
  // ---------------------------------------------------------------------------

  /// Move to a higher buffer tier. Returns true if tier changed.
  bool _upgradeTier() {
    final idx = _tierOrder.indexOf(_currentTier);
    if (idx < _tierOrder.length - 1) {
      _currentTier = _tierOrder[idx + 1];
      return true;
    }
    return false;
  }

  /// Move to a lower buffer tier. Returns true if tier changed.
  bool _downgradeTier() {
    final idx = _tierOrder.indexOf(_currentTier);
    if (idx > 0) {
      _currentTier = _tierOrder[idx - 1];
      return true;
    }
    return false;
  }

  Future<void> _applyTier(String tier, PlayerService ps) async {
    final table = _isLive ? _liveTierConfig : _tierConfig;
    final config = table[tier] ?? table['normal']!;
    for (final entry in config.entries) {
      await _setMpvProperty(ps, entry.key, entry.value);
    }
  }

  Future<void> _setMpvProperty(PlayerService ps, String key, String value) async {
    try {
      final np = ps.player.platform;
      if (np is native_player.NativePlayer) {
        await np.setProperty(key, value);
      }
    } catch (_) {
      // Property might not be settable mid-stream — that's OK
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence (SharedPreferences)
  // ---------------------------------------------------------------------------

  /// Use a short hash of the URL as key to keep storage compact.
  String _urlKey(String url) => url.hashCode.toRadixString(36);

  Future<String> _loadTier(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      if (json != null) {
        final map = jsonDecode(json) as Map<String, dynamic>;
        final tier = map[_urlKey(url)] as String?;
        if (tier != null && _tierConfig.containsKey(tier)) return tier;
      }
    } catch (e) {
      debugPrint('[AdaptiveBuffer] Failed to load tier: $e');
    }
    return 'normal';
  }

  Future<void> _saveTier(String url, String tier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      final map = json != null
          ? (jsonDecode(json) as Map<String, dynamic>)
          : <String, dynamic>{};
      map[_urlKey(url)] = tier;
      // Keep only last 200 entries to avoid unbounded growth
      if (map.length > 200) {
        final keys = map.keys.toList();
        for (var i = 0; i < keys.length - 200; i++) {
          map.remove(keys[i]);
        }
      }
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (e) {
      debugPrint('[AdaptiveBuffer] Failed to save tier: $e');
    }
  }
}

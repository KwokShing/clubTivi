import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'adaptive_buffer.dart';
import 'stream_proxy.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../../data/services/stream_health_tracker.dart';

/// Manages video playback with stream failover support.
class PlayerService {
  Player? _player;
  VideoController? _videoController;
  final AdaptiveBufferManager _bufferManager = AdaptiveBufferManager();
  bool _isBuffering = false;
  DateTime? _bufferStartTime;
  StreamSubscription<Tracks>? _tracksSub;

  // Buffer health tracking (persists across info dialog opens)
  final List<bool> bufferHistory = List.filled(60, false, growable: true);
  int bufferEventCount = 0;
  int bufferingSeconds = 0;
  bool _trackingBuffering = false;
  Timer? _bufferTrackTimer;
  StreamSubscription<bool>? _bufferTrackSub;
  StreamSubscription<bool>? _completedSub; // auto-resume on segment end

  /// Whether the current stream is live (HLS without ENDLIST / short window).
  /// Drives live-tuned buffering and throttled EOF handling.
  bool _isLiveStream = false;
  bool get isLiveStream => _isLiveStream;

  /// Timestamp of the last EOF-triggered reload (used to throttle live reloads).
  DateTime? _lastEofReload;

  /// Buffer stall threshold before triggering failover.
  static const bufferStallThreshold = Duration(seconds: 3);

  // Auto-failover state
  String? _currentUrl;
  String? _currentChannelId;
  String? _currentEpgChannelId;
  String? _currentTvgId;
  String? _currentChannelName;
  String? _currentVanityName;
  String? _currentOriginalName;
  StreamAlternativesService? _alternatives;
  StreamHealthTracker? _healthTracker;
  Timer? _failoverCheckTimer;
  int _consecutiveLowBuffer = 0;
  /// When the current stream started opening — used for a startup grace period
  /// so heavy streams (4K60) that take several seconds to prime aren't treated
  /// as stalled and prematurely warm-preloaded / failed over.
  DateTime? _playbackStartedAt;
  Timer? _audioCheckTimer;
  final StreamProxy _streamProxy = StreamProxy();
  bool _proxyActive = false;

  // ── Warm failover: background pre-buffer player ──
  Player? _warmPlayer;
  String? _warmUrl;
  bool _warmReady = false;
  StreamSubscription<bool>? _warmBufferSub;
  Timer? _warmTimeoutTimer;

  /// Broadcast current stream URL changes (for UI like failover dialog).
  final _currentUrlController = StreamController<String?>.broadcast();
  Stream<String?> get currentUrlStream => _currentUrlController.stream;
  String? get currentUrl => _currentUrl;
  String? get currentChannelId => _currentChannelId;

  /// Callback invoked when auto-failover switches streams.
  /// Provides the provider name or URL fragment for UI toast.
  void Function(String message)? onFailover;

  /// The channel ID that failover most recently switched to, if available.
  String? lastFailoverChannelId;

  bool _playerReady = false;
  final _playerReadyCompleter = Completer<void>();

  Player get player {
    if (_player == null) {
      _player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
      );
      _initPlayer(_player!);
    }
    return _player!;
  }

  Future<void> _initPlayer(Player p) async {
    final np = p.platform;
    if (np is native_player.NativePlayer) {
      // Downmix surround to stereo for output compatibility
      await np.setProperty('audio-channels', 'stereo');
      // Normalize volume when downmixing surround to stereo
      await np.setProperty('audio-normalize-downmix', 'yes');
      // EBU R128 loudness normalization — keeps volume consistent across streams
      await np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
      // Disable SPDIF passthrough which can cause silent output
      await np.setProperty('audio-spdif', '');
      // Volume
      await np.setProperty('volume', '100');
      await np.setProperty('mute', 'no');
      // Auto-reconnect at EOF for segmented/intermittent streams (ffmpeg level).
      // This keeps the same demuxer alive so there's no black flash on reconnect.
      await np.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=2',
      );
      // Android TV: enable hardware decoding and optimize buffering
      if (Platform.isAndroid) {
        await np.setProperty('hwdec', 'mediacodec-copy');
        await np.setProperty('vo', 'gpu');
        await np.setProperty('framedrop', 'vo');
      } else if (Platform.isIOS || Platform.isMacOS) {
        await np.setProperty('hwdec', 'videotoolbox');
      } else if (Platform.isWindows || Platform.isLinux) {
        await np.setProperty('hwdec', 'auto');
      }
    }
    await p.setVolume(100);
    _playerReady = true;
    _playerReadyCompleter.complete();
  }

  /// Wait for player properties to be applied before playback.
  Future<void> _ensureReady() async {
    if (!_playerReady) {
      // Access player to trigger creation if needed
      player; // ignore: unnecessary_statements
      await _playerReadyCompleter.future;
    }
  }

  VideoController get videoController {
    // Explicitly enable hardware-accelerated video output (HEVC Main10 / 4K60
    // decode on the GPU). This is media_kit's default, but stating it here
    // documents intent and keeps it from being silently changed. hwdec itself
    // is left at the platform default and further tuned via mpv properties in
    // _initPlayer.
    _videoController ??= VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    return _videoController!;
  }

  /// Inject services for auto-failover (call once at startup).
  void configureFailover(
    StreamAlternativesService alternatives,
    StreamHealthTracker health,
  ) {
    _alternatives = alternatives;
    _healthTracker = health;
  }

  // Failover group override: manual alternatives from user-created groups
  List<String>? _failoverGroupUrls;

  /// Start playing a stream URL with optional channel metadata for failover.
  Future<void> play(
    String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
    List<String>? failoverGroupUrls,
  }) async {
    _isBuffering = false;
    _bufferStartTime = null;
    _consecutiveLowBuffer = 0;
    _playbackStartedAt = DateTime.now();
    _audioCheckTimer?.cancel();
    _currentUrl = url;
    _currentChannelId = channelId;
    _currentEpgChannelId = epgChannelId;
    _currentTvgId = tvgId;
    _currentChannelName = channelName;
    _currentVanityName = vanityName;
    _currentOriginalName = originalName;
    _failoverGroupUrls = failoverGroupUrls;
    _tracksSub?.cancel();
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _proxyActive = false;
    try {
      await _streamProxy.stop();
      await _ensureReady();
      // Open immediately with the live-tuned buffer tier (primes a small
      // initial buffer; also the right profile for heavy streams). We do NOT
      // block playback on the live-detection HTTP probe — that added several
      // seconds of startup latency. Detection runs in the background below and
      // downgrades to the VOD (large-readahead) tier only if it's actually VOD.
      _isLiveStream = true;
      await _bufferManager.applyForStream(url, this, isLive: true);
      await player.open(Media(url));
      await player.setVolume(100.0);
    } catch (e) {
      debugPrint('[Player] Error starting playback: $e');
      return;
    }

    // Refine live vs VOD off the critical path.
    _refineStreamProfile(url);

    // Check for missing audio after a brief delay and retry through
    // ffmpeg proxy if needed (fixes EAC-3 with non-standard codec tags)
    _scheduleAudioCheck(url);

    // ffmpeg reconnect handles most streams. For streams that truly hit EOF
    // (server closes connection), reload via loadfile to keep the last frame
    // visible (no black flash) then resume playback.
    _completedSub?.cancel();
    _completedSub = player.stream.completed.listen((completed) async {
      if (!completed || _currentUrl == null) return;
      // For live streams the edge can briefly report completed while the
      // playlist refreshes. ffmpeg reconnect + auto-failover handle real
      // outages, so throttle reloads to avoid a tight reload loop.
      if (_isLiveStream) {
        final now = DateTime.now();
        if (_lastEofReload != null &&
            now.difference(_lastEofReload!) < const Duration(seconds: 5)) {
          return;
        }
        _lastEofReload = now;
      }
      debugPrint('[Player] EOF reached, reloading: $_currentUrl');
      final platform = player.platform;
      if (platform is native_player.NativePlayer) {
        try {
          // loadfile replace keeps the video output texture (no black flash)
          await platform.command(['loadfile', _currentUrl!, 'replace']);
          // Ensure playback resumes (keep-open may have paused it)
          await player.play();
        } catch (_) {
          await player.open(Media(_currentUrl!));
        }
      } else {
        await player.open(Media(_currentUrl!));
      }
    });

    // Reset and start buffer tracking for the new stream
    bufferHistory.fillRange(0, 60, false);
    bufferEventCount = 0;
    bufferingSeconds = 0;
    startBufferTracking();
    _startFailoverMonitor();
  }

  /// Check audio tracks after playback starts; retry through ffmpeg proxy
  /// if no real audio tracks are detected.
  ///
  /// Heavy streams (4K60) can take several seconds before mpv reports audio
  /// tracks, so poll a few times over ~12s before concluding there is no
  /// audio — a single early check produced false negatives that needlessly
  /// routed working streams through the proxy.
  void _scheduleAudioCheck(String originalUrl) {
    _audioCheckTimer?.cancel();
    var attempts = 0;
    _audioCheckTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      attempts++;
      if (_proxyActive || _currentUrl != originalUrl) {
        timer.cancel();
        return;
      }

      final tracks = player.state.tracks;
      final realAudio = tracks.audio
          .where((a) => a.id != 'auto' && a.id != 'no')
          .length;
      if (realAudio > 0) {
        debugPrint('[Player] Audio OK: $realAudio tracks detected');
        timer.cancel();
        return;
      }

      // Still no audio — keep waiting up to ~12s before giving up, since
      // heavy streams report tracks late.
      if (attempts >= 4) {
        timer.cancel();
        debugPrint(
          '[Player] No audio tracks after ${attempts * 3}s, '
          'trying ffmpeg proxy for $originalUrl',
        );
        _retryWithProxy(originalUrl);
      }
    });
  }

  /// Re-open the stream through the local ffmpeg proxy.
  Future<void> _retryWithProxy(String originalUrl) async {
    if (_proxyActive) return; // Avoid recursive retry
    try {
      final proxyUrl = await _streamProxy.start(originalUrl);
      if (proxyUrl == null) {
        debugPrint(
          '[Player] ffmpeg proxy unavailable, keeping direct playback',
        );
        return;
      }
      // Verify the stream URL hasn't changed while we were starting the proxy
      if (_currentUrl != originalUrl) {
        await _streamProxy.stop();
        return;
      }
      _proxyActive = true;
      debugPrint('[Player] Switching to proxied stream: $proxyUrl');
      await player.open(Media(proxyUrl));
      await _bufferManager.applyForStream(originalUrl, this,
          isLive: _isLiveStream);
      await player.setVolume(100.0);
    } catch (e) {
      debugPrint('[Player] Proxy retry failed: $e');
    }
  }

  /// Whether audio tracks are available on the current stream.
  Stream<bool> get hasAudioStream =>
      player.stream.tracks.map((t) => t.audio.length > 1);

  /// Number of audio tracks.
  Stream<int> get audioTrackCountStream =>
      player.stream.tracks.map((t) => t.audio.length);

  /// Stop playback.
  Future<void> stop() async {
    _bufferManager.stop();
    _audioCheckTimer?.cancel();
    _failoverCheckTimer?.cancel();
    await player.stop();
  }

  /// Pause playback.
  Future<void> pause() async {
    await player.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    await player.play();
  }

  /// Set volume (0.0 - 100.0).
  Future<void> setVolume(double volume) async {
    await player.setVolume(volume.clamp(0.0, 100.0));
  }

  /// Stream of buffering state changes.
  Stream<bool> get bufferingStream => player.stream.buffering;

  /// Stream of playback position.
  Stream<Duration> get positionStream => player.stream.position;

  /// Stream of duration.
  Stream<Duration> get durationStream => player.stream.duration;

  /// Stream of whether playback is playing.
  Stream<bool> get playingStream => player.stream.playing;

  /// Check if buffer stall exceeds threshold (for failover trigger).
  bool get shouldFailover {
    if (!_isBuffering || _bufferStartTime == null) return false;
    return DateTime.now().difference(_bufferStartTime!) > bufferStallThreshold;
  }

  /// Called when buffering state changes — used by failover engine.
  void onBufferingChanged(bool buffering) {
    if (buffering && !_isBuffering) {
      _isBuffering = true;
      _bufferStartTime = DateTime.now();
    } else if (!buffering) {
      _isBuffering = false;
      _bufferStartTime = null;
    }
  }

  /// Refine the live/VOD profile in the background after playback has started,
  /// without blocking initial open. If the stream turns out to be VOD, switch
  /// from the optimistic live tier to the large-readahead VOD tier.
  void _refineStreamProfile(String url) {
    _detectLive(url).then((live) {
      if (_currentUrl != url) return; // stream changed meanwhile
      if (_isLiveStream == live) return; // already correct (live assumed)
      _isLiveStream = live;
      if (!live) {
        _bufferManager.applyForStream(url, this, isLive: false);
      }
    });
  }

  /// Detect whether [url] is a live stream (HLS playlist without
  /// `#EXT-X-ENDLIST`). Only HLS (`.m3u8`) URLs are probed; anything else is
  /// treated as VOD. Network/parse failures fall back to VOD so a slow probe
  /// never blocks playback. Bounded by a short timeout.
  Future<bool> _detectLive(String url) async {
    if (!url.toLowerCase().contains('.m3u8')) return false;
    try {
      final headers = await _probeHeaders();
      final uri = Uri.parse(url);
      var body = await _fetchPlaylist(uri, headers);
      if (body == null) return false;

      // Master playlist → resolve and probe the first variant.
      if (body.contains('#EXT-X-STREAM-INF')) {
        final variant = _firstVariantUri(uri, body);
        if (variant != null) {
          final variantBody = await _fetchPlaylist(variant, headers);
          if (variantBody != null) body = variantBody;
        }
      }

      final isMediaPlaylist = body.contains('#EXTINF');
      final hasEndList = body.contains('#EXT-X-ENDLIST');
      final live = isMediaPlaylist && !hasEndList;
      debugPrint('[Player] Live detection: $live for $url');
      return live;
    } catch (e) {
      debugPrint('[Player] Live detection failed (assuming VOD): $e');
      return false;
    }
  }

  /// Fetch a playlist body with a short timeout. Returns null on failure.
  Future<String?> _fetchPlaylist(Uri uri, Map<String, String> headers) async {
    try {
      final resp = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) return resp.body;
    } catch (_) {}
    return null;
  }

  /// Resolve the first variant URI from a master playlist.
  Uri? _firstVariantUri(Uri base, String master) {
    final lines = master.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        for (var j = i + 1; j < lines.length; j++) {
          final line = lines[j].trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          return base.resolve(line);
        }
      }
    }
    return null;
  }

  /// Build request headers for playlist probing, honoring the user's
  /// configured playback User-Agent when one is set.
  Future<Map<String, String>> _probeHeaders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ua = prefs.getString('playback_user_agent');
      if (ua != null && ua.isNotEmpty && ua != 'Default') {
        return {'User-Agent': ua};
      }
    } catch (_) {}
    return const {};
  }

  /// Read an mpv property from the underlying native player.
  /// Returns null if unavailable (e.g. on web or before player init).
  Future<String?> getMpvProperty(String name) async {
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      try {
        return await np.getProperty(name);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Take a screenshot via mpv's screenshot-to-file command.
  Future<String?> takeScreenshot(String path) async {
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      try {
        await np.setProperty('screenshot-format', 'png');
        await np.command(['screenshot-to-file', path, 'video']);
        return path;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Current adaptive buffer manager for UI access.
  AdaptiveBufferManager get bufferManager => _bufferManager;

  /// Start tracking buffer events and accumulating buffering time.
  void startBufferTracking() {
    if (_trackingBuffering) return;
    _trackingBuffering = true;

    _bufferTrackSub?.cancel();
    _bufferTrackSub = player.stream.buffering.listen((isBuffering) {
      bufferHistory.removeAt(0);
      bufferHistory.add(isBuffering);
      if (isBuffering && !_isBuffering) bufferEventCount++;
    });

    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (player.state.buffering) bufferingSeconds++;
    });
  }

  // ── Auto-failover monitor ──────────────────────────────────────────────

  void _startFailoverMonitor() {
    _failoverCheckTimer?.cancel();
    _failoverCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_currentUrl == null) return;
      if (_alternatives == null &&
          (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty))
        return;

      final raw = await getMpvProperty('demuxer-cache-duration');
      final cacheSecs = double.tryParse(raw ?? '');
      if (cacheSecs == null) return;

      // If the stream is reconnecting at EOF (segmented stream boundary),
      // don't treat the brief cache drop as a stall → avoid false failover.
      final eofReached = await getMpvProperty('eof-reached');
      if (eofReached == 'yes') {
        _consecutiveLowBuffer = 0;
        return;
      }

      // Record health sample
      _healthTracker?.recordBufferSample(_currentUrl!, cacheSecs);

      // Startup grace: heavy streams (4K60 10-bit HEVC ~20Mbps) legitimately
      // take several seconds to prime their initial buffer. Don't treat low
      // buffer as a stall during this window, or we warm-preload a second
      // decode / fail over before the stream ever gets a chance to start.
      if (_playbackStartedAt != null &&
          DateTime.now().difference(_playbackStartedAt!) <
              const Duration(seconds: 15)) {
        return;
      }

      if (cacheSecs < 1.0) {
        _consecutiveLowBuffer++;
        if (_consecutiveLowBuffer >= 2 && !_warmReady && _warmPlayer == null) {
          // 4+ seconds of low buffer → start pre-buffering alternative (warm)
          _startWarmPreload();
        }
        if (_consecutiveLowBuffer >= 3) {
          // 6+ seconds of critically low buffer → failover
          _healthTracker?.recordStall(_currentUrl!);
          await _autoFailover();
        }
      } else {
        _consecutiveLowBuffer = 0;
        // Buffer recovered — dispose warm player if not yet used
        if (_warmPlayer != null && !_warmReady) {
          _disposeWarmPlayer();
        }
      }
    });
  }

  /// Get failover alternative URLs, preferring manual group URLs over auto-detected.
  List<String> _getFailoverAlternatives() {
    if (_currentUrl == null) return [];

    // Prefer manually-defined failover group URLs
    if (_failoverGroupUrls != null && _failoverGroupUrls!.isNotEmpty) {
      return _failoverGroupUrls!.where((u) => u != _currentUrl).toList();
    }

    // Fall back to auto-detected alternatives
    if (_alternatives == null) return [];
    return _alternatives!.getAlternatives(
      channelId: _currentChannelId ?? '',
      epgChannelId: _currentEpgChannelId,
      tvgId: _currentTvgId,
      channelName: _currentChannelName,
      vanityName: _currentVanityName,
      originalName: _currentOriginalName,
      excludeUrl: _currentUrl!,
    );
  }

  /// Start pre-buffering the best alternative stream in a hidden player.
  void _startWarmPreload() {
    if (_currentUrl == null) return;

    final alts = _getFailoverAlternatives();
    if (alts.isEmpty) return;

    final warmUrl = alts.first;
    debugPrint('[Failover] Warm pre-buffering: $warmUrl');
    _warmUrl = warmUrl;
    _warmReady = false;

    _warmPlayer = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );

    // Configure warm player: muted, with loudnorm, no video output
    final np = _warmPlayer!.platform;
    if (np is native_player.NativePlayer) {
      np.setProperty('vid', 'no'); // disable video decoding
      np.setProperty('audio-channels', 'stereo');
      np.setProperty('audio-normalize-downmix', 'yes');
      np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
      np.setProperty('volume', '0'); // silent
    }

    // Listen for buffering state — when it stops buffering, stream is ready
    _warmBufferSub?.cancel();
    bool initialBuffering = true;
    _warmBufferSub = _warmPlayer!.stream.buffering.listen((buffering) {
      if (initialBuffering && buffering) return; // still loading
      if (initialBuffering && !buffering) {
        initialBuffering = false;
        _warmReady = true;
        _warmTimeoutTimer?.cancel();
        debugPrint('[Failover] Warm player ready: $_warmUrl');
      }
    });

    _warmPlayer!.open(Media(warmUrl));

    // Timeout: if warm player doesn't become ready in 10s, dispose it
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = Timer(const Duration(seconds: 10), () {
      if (!_warmReady) {
        debugPrint('[Failover] Warm pre-buffer timed out');
        _disposeWarmPlayer();
      }
    });
  }

  /// Dispose the warm pre-buffer player and clean up.
  void _disposeWarmPlayer() {
    _warmBufferSub?.cancel();
    _warmBufferSub = null;
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = null;
    _warmPlayer?.dispose();
    _warmPlayer = null;
    _warmUrl = null;
    _warmReady = false;
  }

  Future<void> _autoFailover() async {
    if (_currentUrl == null) return;
    if (_alternatives == null &&
        (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty))
      return;

    // If warm player is ready, do an instant switch
    if (_warmReady && _warmPlayer != null && _warmUrl != null) {
      debugPrint('[Failover] Instant switch to warm-buffered: $_warmUrl');
      final newUrl = _warmUrl!;
      _consecutiveLowBuffer = 0;
      _failoverCheckTimer?.cancel();

      // Dispose warm player (we'll re-open on main player)
      _disposeWarmPlayer();

      // Switch main player to the pre-buffered URL
      _currentUrl = newUrl;
      _proxyActive = false;
      await _streamProxy.stop();
      await player.open(Media(newUrl));
      await _bufferManager.applyForStream(newUrl, this, isLive: _isLiveStream);
      _startFailoverMonitor();

      _currentUrlController.add(newUrl);
      lastFailoverChannelId = _alternatives?.channelIdForUrl(newUrl);
      onFailover?.call('⚡ Switched stream (warm)');
      return;
    }

    // Cold failover: find best alternative and switch directly
    final alts = _getFailoverAlternatives();

    if (alts.isEmpty) return;

    final newUrl = alts.first;
    _consecutiveLowBuffer = 0;

    // Switch stream (keep channel metadata — it's the same content)
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _currentUrl = newUrl;
    _proxyActive = false;
    await _streamProxy.stop();
    await player.open(Media(newUrl));
    await _bufferManager.applyForStream(newUrl, this, isLive: _isLiveStream);
    _startFailoverMonitor();

    _currentUrlController.add(newUrl);
    lastFailoverChannelId = _alternatives?.channelIdForUrl(newUrl);
    onFailover?.call('⚡ Switched stream');
  }

  void dispose() {
    try {
      _bufferManager.stop();
      _tracksSub?.cancel();
      _audioCheckTimer?.cancel();
      _bufferTrackSub?.cancel();
      _completedSub?.cancel();
      _bufferTrackTimer?.cancel();
      _failoverCheckTimer?.cancel();
      _disposeWarmPlayer();
      _healthTracker?.save();
      _streamProxy.stop();
      _player?.dispose();
    } catch (e) {
      debugPrint('[Player] Error during dispose: $e');
    }
  }
}

/// Riverpod provider for the player service (singleton).
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  // Inject failover services
  try {
    final alternatives = ref.read(streamAlternativesProvider);
    final health = ref.read(streamHealthTrackerProvider);
    service.configureFailover(alternatives, health);
  } catch (_) {
    // Services may not be available yet — failover will be disabled
  }
  ref.onDispose(() => service.dispose());
  return service;
});

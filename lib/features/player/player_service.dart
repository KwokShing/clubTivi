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

/// Manages video playback.
class PlayerService {
  Player? _player;
  VideoController? _videoController;
  final AdaptiveBufferManager _bufferManager = AdaptiveBufferManager();
  StreamSubscription<Tracks>? _tracksSub;

  // Buffer health tracking (persists across info dialog opens)
  final List<bool> bufferHistory = List.filled(60, false, growable: true);
  int bufferEventCount = 0;
  int bufferingSeconds = 0;
  bool _trackingBuffering = false;
  Timer? _bufferTrackTimer;
  StreamSubscription<bool>? _bufferTrackSub;
  StreamSubscription<bool>? _completedSub; // auto-resume on segment end

  // ── Load timeout: fail a stream that never starts within a grace window ──
  static const _loadTimeout = Duration(seconds: 15);
  Timer? _loadTimeoutTimer;
  StreamSubscription<Duration>? _loadStartSub;
  bool _playbackStarted = false;
  bool _loadTimedOut = false;
  bool get loadTimedOut => _loadTimedOut;
  final _loadTimeoutController = StreamController<bool>.broadcast();

  /// Emits `true` when a stream fails to start playing within [_loadTimeout]
  /// (loading is then stopped), and `false` when a new load begins.
  Stream<bool> get loadTimeoutStream => _loadTimeoutController.stream;

  /// Whether the current stream is live (HLS without ENDLIST / short window).
  /// Drives live-tuned buffering and throttled EOF handling.
  bool _isLiveStream = false;
  bool get isLiveStream => _isLiveStream;

  /// Timestamp of the last EOF-triggered reload (used to throttle live reloads).
  DateTime? _lastEofReload;

  // Current playback tracking
  String? _currentUrl;
  String? _currentChannelId;

  String? get currentUrl => _currentUrl;
  String? get currentChannelId => _currentChannelId;

  bool _playerReady = false;
  final _playerReadyCompleter = Completer<void>();

  Player get player {
    if (_player == null) {
      _player = Player(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
          // Demuxer cache is bounded by the adaptive buffer tiers; keep the
          // media_kit-level buffer modest so total playback memory stays low.
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      _initPlayer(_player!);
    }
    return _player!;
  }

  /// Best-effort mpv property set — never throws, so a single unsupported
  /// property can't abort player initialization (which would leave
  /// `_ensureReady` hanging and playback never starting).
  Future<void> _set(
    native_player.NativePlayer np,
    String key,
    String value,
  ) async {
    try {
      await np.setProperty(key, value);
    } catch (e) {
      debugPrint('[Player] setProperty $key failed: $e');
    }
  }

  Future<void> _initPlayer(Player p) async {
    final np = p.platform;
    if (np is native_player.NativePlayer) {
      // ── Core decode path ──────────────────────────────────────────────
      // Mirror the minimal, proven-working reference config. hwdec=auto lets
      // mpv pick the platform HW decoder (d3d11va / videotoolbox / mediacodec)
      // for 4K HEVC; interpolation off + audio video-sync keep first-frame
      // latency low and avoid heavy GPU work that stalls 4K startup.
      final hwdec = Platform.isAndroid ? 'mediacodec-copy' : 'auto';
      await _set(np, 'hwdec', hwdec);
      await _set(np, 'interpolation', 'no');
      await _set(np, 'video-sync', 'audio');

      // ── Audio normalization (app feature, audio-only) ─────────────────
      // Best-effort: these shape audio output only and never block video.
      await _set(np, 'audio-channels', 'stereo');
      await _set(np, 'audio-normalize-downmix', 'yes');
      await _set(np, 'af', 'loudnorm=I=-14:TP=-1:LRA=13');
      await _set(np, 'volume', '100');
      await _set(np, 'mute', 'no');
    }
    await p.setVolume(100);
    _playerReady = true;
    if (!_playerReadyCompleter.isCompleted) _playerReadyCompleter.complete();
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
    // Configure the video output exactly like the proven-working reference:
    // hwdec=auto here wires media_kit's hardware video pipeline (ANGLE/D3D11
    // on Windows, VideoToolbox on Apple) to the GPU HEVC decoder. Setting it
    // on the controller — not just as a bare mpv property — is what makes 4K
    // HEVC frames actually reach the texture.
    _videoController ??= VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        hwdec: 'auto',
        enableHardwareAcceleration: true,
      ),
    );
    return _videoController!;
  }

  /// Start playing a stream URL with optional channel metadata.
  Future<void> play(
    String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
  }) async {
    _currentUrl = url;
    _currentChannelId = channelId;
    _tracksSub?.cancel();
    try {
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
    _startLoadTimeout();
  }

  /// Arm a timeout that stops a stream which never starts playing within
  /// [_loadTimeout]. Cancelled automatically once playback actually begins
  /// (the position advances). Surfaces via [loadTimeoutStream] so the play
  /// window can show a "Loading timed out" message.
  void _startLoadTimeout() {
    _loadTimeoutTimer?.cancel();
    _loadStartSub?.cancel();
    _playbackStarted = false;
    if (_loadTimedOut) {
      _loadTimedOut = false;
      _loadTimeoutController.add(false);
    }
    // Playback is considered "started" once frames flow (position advances).
    _loadStartSub = player.stream.position.listen((pos) {
      if (pos > Duration.zero) {
        _playbackStarted = true;
        _loadTimeoutTimer?.cancel();
        _loadStartSub?.cancel();
        _loadStartSub = null;
      }
    });
    _loadTimeoutTimer = Timer(_loadTimeout, () {
      // Already playing smoothly → not a timeout.
      if (_playbackStarted ||
          (player.state.playing && !player.state.buffering)) {
        return;
      }
      debugPrint(
        '[Player] Load timeout after ${_loadTimeout.inSeconds}s — stopping',
      );
      _loadTimedOut = true;
      _loadTimeoutController.add(true);
      _loadStartSub?.cancel();
      _loadStartSub = null;
      // Stop loading the stalled stream (player instance kept for retry).
      player.stop();
    });
  }

  void _cancelLoadTimeout() {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = null;
    _loadStartSub?.cancel();
    _loadStartSub = null;
    if (_loadTimedOut) {
      _loadTimedOut = false;
      _loadTimeoutController.add(false);
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
    _cancelLoadTimeout();
    // Tear down buffer-tracking so its timer/subscription don't keep firing
    // (and keep the player's stream alive) after playback has stopped.
    _bufferTrackSub?.cancel();
    _bufferTrackSub = null;
    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = null;
    _completedSub?.cancel();
    _completedSub = null;
    _trackingBuffering = false;
    await player.stop();
    // Clear current-channel tracking so re-selecting the same channel after a
    // stop will (re)load it instead of being skipped as "already playing".
    _currentUrl = null;
    _currentChannelId = null;
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
    final lower = url.toLowerCase();
    // Explicit VOD container files → treat as VOD (large readahead is fine,
    // the whole file is seekable).
    if (RegExp(r'\.(mp4|mkv|avi|mov|webm|m4v|flv|mpg|mpeg)(\?|$)')
        .hasMatch(lower)) {
      return false;
    }
    // Non-HLS streams (raw MPEG-TS, tokenized/extensionless live URLs) can't
    // be probed for #EXT-X-ENDLIST. Default them to LIVE so they use the
    // small, low-latency live buffer instead of the large VOD readahead
    // profile — otherwise an infinite live stream fills the VOD demuxer cache
    // and pins hundreds of MB for the whole session.
    if (!lower.contains('.m3u8')) return true;
    try {
      final headers = await _probeHeaders();
      final uri = Uri.parse(url);
      var body = await _fetchPlaylist(uri, headers);
      if (body == null) return true; // probe failed → assume live (small buffer)

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
      final live = !isMediaPlaylist || !hasEndList;
      debugPrint('[Player] Live detection: $live for $url');
      return live;
    } catch (e) {
      debugPrint('[Player] Live detection failed (assuming live): $e');
      return true;
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
      if (isBuffering) bufferEventCount++;
    });

    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (player.state.buffering) bufferingSeconds++;
    });
  }

  void dispose() {
    try {
      _bufferManager.stop();
      _tracksSub?.cancel();
      _bufferTrackSub?.cancel();
      _completedSub?.cancel();
      _bufferTrackTimer?.cancel();
      _loadTimeoutTimer?.cancel();
      _loadStartSub?.cancel();
      _loadTimeoutController.close();
      _player?.dispose();
    } catch (e) {
      debugPrint('[Player] Error during dispose: $e');
    }
  }
}

/// Riverpod provider for the player service (singleton).
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  ref.onDispose(() => service.dispose());
  return service;
});

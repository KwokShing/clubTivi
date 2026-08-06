import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'adaptive_buffer.dart';
import 'subtitle_settings.dart';

/// Manages video playback.
class PlayerService {
  PlayerService() {
    // Read subtitle preferences up front so every playback path — inline
    // preview included — starts with the user's choice, not mpv's default of
    // silently auto-selecting the first subtitle track.
    _loadSubtitlePrefs();
  }

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

  // ── Black-frame recovery ────────────────────────────────────────────────
  /// How long to allow for the first video frame before assuming the hardware
  /// decoder is not going to produce one.
  static const _blackFrameGrace = Duration(seconds: 6);
  Timer? _blackFrameTimer;

  /// URL that already fell back to software decoding, so the watchdog retries
  /// each stream at most once.
  String? _swDecodeFallbackUrl;

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
  bool _videoOutputReady = false;

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
      final hwdec = _hwdec;
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
    await _ensureVideoOutput();
  }

  /// Attach the video output *before* any media is opened.
  ///
  /// media_kit starts mpv with `vid=no` ("prevent redundant video decoding")
  /// and only [VideoController] flips it to `vo=libmpv` + `vid=auto` when it is
  /// constructed. `Player.open()` waits for that handshake, but only once a
  /// controller exists — so opening a stream before the first `Video` widget
  /// has been built decodes audio only and leaves the output black. Switching
  /// `vid` afterwards does not reliably re-attach a hardware-decoded video
  /// track (HEVC especially), so the frame never appears.
  ///
  /// Creating the controller here makes every playback path — inline preview,
  /// fullscreen player, files, VOD — open media with video already wired up.
  Future<void> _ensureVideoOutput() async {
    if (_videoOutputReady) return;
    try {
      // The getter marks the video output as attached on the player.
      final controller = videoController;
      // media_kit defers platform-controller creation to a post-frame
      // callback, so make sure a frame is actually scheduled.
      SchedulerBinding.instance.ensureVisualUpdate();
      await controller.platform.future.timeout(const Duration(seconds: 10));
      _videoOutputReady = true;
    } catch (e) {
      // Never block playback on video-output setup; audio-only is still better
      // than nothing and the next attempt will retry.
      debugPrint('[Player] Video output attach failed: $e');
    }
  }

  /// The mpv hardware-decoding mode for this platform. Android needs
  /// `mediacodec-copy` (plain `mediacodec` hands back frames media_kit can't
  /// map into a Flutter texture); everywhere else `auto` lets mpv pick
  /// d3d11va / videotoolbox / vaapi.
  static String get _hwdec =>
      Platform.isAndroid ? 'mediacodec-copy' : 'auto';

  VideoController get videoController {
    // Configure the video output exactly like the proven-working reference:
    // hwdec here wires media_kit's hardware video pipeline (ANGLE/D3D11 on
    // Windows, VideoToolbox on Apple) to the GPU HEVC decoder. Setting it on
    // the controller — not just as a bare mpv property — is what makes 4K HEVC
    // frames actually reach the texture. The controller re-applies `hwdec`
    // when it attaches, so it must carry the same value as `_initPlayer` or it
    // would silently override it.
    _videoController ??= VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: _hwdec,
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
    // An empty URL would make mpv tear down the current video output and show
    // a black screen. Ignore it so an incompletely-configured caller can't
    // kill playback that is already running.
    if (url.trim().isEmpty) {
      debugPrint('[Player] Ignoring play() with empty URL');
      return;
    }
    _currentUrl = url;
    _currentChannelId = channelId;
    _tracksSub?.cancel();
    try {
      await _ensureReady();
      await _restoreHardwareDecoding();
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

    // Re-assert subtitle handling: opening new media resets mpv's per-file
    // subtitle state, and a stale sub-delay from the previous channel would
    // otherwise desync the new one.
    await setSubtitleDelay(0);
    await applySubtitleStyle(subtitleSettings);
    if (!subtitleSettings.autoEnable) {
      // mpv defaults to `sid=auto`, which quietly turns on the first subtitle
      // track. Left alone, subtitles would appear while the CC control still
      // reads "off". Pin it off so the UI and what's on screen agree; the CC
      // button and the auto-enable preference are the only ways in.
      await player.setSubtitleTrack(SubtitleTrack.no());
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
    _armBlackFrameWatchdog();
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
    _blackFrameTimer?.cancel();
    _blackFrameTimer = null;
    if (_loadTimedOut) {
      _loadTimedOut = false;
      _loadTimeoutController.add(false);
    }
  }

  /// Detect "audio plays but the picture is black".
  ///
  /// Some hardware decoders (notably d3d11va with 10-bit HEVC) accept the
  /// stream and then never deliver a mappable frame: mpv reports playback and
  /// audio is fine, but `dwidth`/`dheight` stay empty so the texture has
  /// nothing to show. Recover once by falling back to software decoding for
  /// this stream instead of leaving the user on a black screen.
  void _armBlackFrameWatchdog() {
    _blackFrameTimer?.cancel();
    final url = _currentUrl;
    if (url == null) return;
    _blackFrameTimer = Timer(_blackFrameGrace, () async {
      if (_currentUrl != url || _swDecodeFallbackUrl == url) return;
      // Only act when audio is genuinely progressing — otherwise this is an
      // ordinary connection problem and the load timeout owns it.
      if (!player.state.playing) return;
      final hasVideoTrack = player.state.tracks.video
          .any((t) => t.id != 'no' && t.id != 'auto');
      if (!hasVideoTrack) return; // audio-only stream: black is correct
      final w = player.state.width ?? 0;
      final h = player.state.height ?? 0;
      if (w > 0 && h > 0) return; // frames are flowing

      debugPrint(
        '[Player] Video track present but no frames — '
        'retrying with software decoding',
      );
      _swDecodeFallbackUrl = url;
      final np = player.platform;
      if (np is native_player.NativePlayer) {
        await _set(np, 'hwdec', 'no');
      }
      if (_currentUrl != url) return;
      try {
        await player.open(Media(url));
        await player.setVolume(100.0);
      } catch (e) {
        debugPrint('[Player] Software-decode retry failed: $e');
      }
    });
  }

  /// Restore hardware decoding for a newly selected stream after a previous
  /// stream had to fall back to software decoding.
  Future<void> _restoreHardwareDecoding() async {
    if (_swDecodeFallbackUrl == null) return;
    _swDecodeFallbackUrl = null;
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      await _set(np, 'hwdec', _hwdec);
    }
  }

  /// Whether audio tracks are available on the current stream.
  Stream<bool> get hasAudioStream =>
      player.stream.tracks.map((t) => t.audio.length > 1);

  /// Number of audio tracks.
  Stream<int> get audioTrackCountStream =>
      player.stream.tracks.map((t) => t.audio.length);

  // ── Subtitles ───────────────────────────────────────────────────────────

  /// The style last handed to [applySubtitleStyle], re-applied after every
  /// [play] because opening new media can reset mpv's subtitle properties.
  SubtitleSettings? _subtitleStyle;

  /// The subtitle preferences in effect, falling back to defaults until prefs
  /// have been read or the UI has pushed a change.
  SubtitleSettings get subtitleSettings =>
      _subtitleStyle ?? const SubtitleSettings();

  Future<void> _loadSubtitlePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Don't clobber a style the UI already pushed while prefs were loading.
      _subtitleStyle ??= SubtitleSettings.fromPrefs(prefs);
    } catch (_) {
      // Subtitles are a display preference; defaults are an acceptable result.
    }
  }

  /// Stream of the current subtitle lines (empty while nothing is displayed).
  Stream<List<String>> get subtitleStream => player.stream.subtitle;

  /// Number of selectable subtitle tracks on the current stream (mpv's `auto`
  /// and `no` pseudo-tracks excluded).
  Stream<int> get subtitleTrackCountStream => player.stream.tracks.map(
        (t) => t.subtitle.where((s) => s.id != 'auto' && s.id != 'no').length,
      );

  /// Push [settings] down to mpv.
  ///
  /// Only meaningful for [SubtitleRenderer.player]: it flips `sub-visibility`
  /// on so mpv draws into the video (the one way to see bitmap DVB/PGS
  /// subtitles, which carry no text for the Flutter renderer) and maps the
  /// style options onto mpv's equivalents. With [SubtitleRenderer.flutter] the
  /// mpv overlay is switched back off so the two renderers never stack.
  ///
  /// `sub-text` keeps updating either way, so the Flutter renderer works
  /// regardless of `sub-visibility`.
  Future<void> applySubtitleStyle(SubtitleSettings settings) async {
    _subtitleStyle = settings;
    // Don't spin up mpv just to store a preference — the Settings screen calls
    // this while nothing is playing. [play] re-applies the cached style.
    if (_player == null) return;
    final np = player.platform;
    if (np is! native_player.NativePlayer) return;

    final mpvDraws = settings.renderer == SubtitleRenderer.player;
    await _set(np, 'sub-visibility', mpvDraws ? 'yes' : 'no');
    // Pick up `movie.srt` next to `movie.mkv` for local files and VOD.
    await _set(np, 'sub-auto', 'fuzzy');
    if (!mpvDraws) return;

    // mpv sizes subtitles relative to its own default, so express the chosen
    // pixel size as a scale factor against the widget renderer's default.
    final scale = (settings.fontSize / 32.0).clamp(0.4, 2.5);
    await _set(np, 'sub-scale', scale.toStringAsFixed(2));
    await _set(np, 'sub-color', _mpvColor(settings.colorValue));
    await _set(np, 'sub-bold', settings.bold ? 'yes' : 'no');
    // mpv 0.38 renamed sub-border-* to sub-outline-*; the old names remain as
    // deprecated aliases. Set both so the outline works on whichever libmpv
    // build ships with media_kit — unknown properties are ignored by [_set].
    final border = settings.outline ? '2.5' : '0';
    await _set(np, 'sub-border-size', border);
    await _set(np, 'sub-outline-size', border);
    await _set(np, 'sub-border-color', '#FF000000');
    await _set(np, 'sub-outline-color', '#FF000000');
    await _set(
      np,
      'sub-back-color',
      _mpvColor(0x000000, alpha: settings.backgroundOpacity),
    );
    // sub-pos is a percentage of frame height measured from the top, so a
    // larger bottom offset means a smaller value.
    final posFromBottom =
        (settings.bottomOffset / 1080.0 * 100).clamp(0.0, 40.0);
    await _set(np, 'sub-pos', (100 - posFromBottom).round().toString());
  }

  /// Format an ARGB int as mpv's `#AARRGGBB` colour literal.
  static String _mpvColor(int argb, {double? alpha}) {
    final a = ((alpha ?? 1.0).clamp(0.0, 1.0) * 255).round();
    final rgb = argb & 0xFFFFFF;
    return '#${a.toRadixString(16).padLeft(2, '0')}'
            '${rgb.toRadixString(16).padLeft(6, '0')}'
        .toUpperCase();
  }

  /// Shift subtitles in time relative to the video, in seconds. Positive
  /// values show them later.
  Future<void> setSubtitleDelay(double seconds) async {
    if (_player == null) return;
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      await _set(np, 'sub-delay', seconds.toStringAsFixed(2));
    }
  }

  /// Current subtitle delay in seconds, or 0 when it can't be read.
  Future<double> getSubtitleDelay() async {
    if (_player == null) return 0.0;
    final value = await getMpvProperty('sub-delay');
    return double.tryParse(value ?? '') ?? 0.0;
  }

  /// Load and select an external subtitle file (`.srt`, `.ass`, `.vtt`, …).
  ///
  /// Goes through [Player.setSubtitleTrack] so media_kit stays the owner of
  /// the selected-track state and its subtitle-text stream keeps flowing.
  Future<void> loadExternalSubtitle(String path, {String? title}) async {
    final uri = Uri.tryParse(path);
    final isRemote = uri != null && (uri.isScheme('http') || uri.isScheme('https'));
    await player.setSubtitleTrack(
      SubtitleTrack.uri(
        isRemote ? path : Uri.file(path).toString(),
        title: title,
      ),
    );
    if (_subtitleStyle != null) await applySubtitleStyle(_subtitleStyle!);
  }

  /// Pick the subtitle track that best matches [preferredLanguage] (ISO 639
  /// code) and select it. Falls back to the first available track when the
  /// preference is empty or unmatched. Returns the selected track, or null when
  /// the stream carries no subtitles.
  Future<SubtitleTrack?> selectPreferredSubtitle(
    String preferredLanguage,
  ) async {
    final tracks = player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    if (tracks.isEmpty) return null;

    SubtitleTrack? match;
    if (preferredLanguage.isNotEmpty) {
      final wanted = preferredLanguage.toLowerCase();
      for (final t in tracks) {
        final lang = (t.language ?? '').toLowerCase();
        final title = (t.title ?? '').toLowerCase();
        // Stream metadata is inconsistent: `eng`, `en`, `English (CC)` all
        // occur, so accept a prefix match on either field.
        if (lang.startsWith(wanted) ||
            wanted.startsWith(lang) && lang.isNotEmpty ||
            title.contains(wanted)) {
          match = t;
          break;
        }
      }
    }
    final chosen = match ?? tracks.first;
    await player.setSubtitleTrack(chosen);
    return chosen;
  }

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
      _blackFrameTimer?.cancel();
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

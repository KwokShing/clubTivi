import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/stream_alternatives_service.dart';
import '../../features/providers/provider_manager.dart' show databaseProvider;
import '../casting/cast_service.dart';
import '../casting/cast_dialog.dart';
import '../channels/channel_debug_dialog.dart';
import 'player_control_bar.dart';
import 'player_service.dart';
import 'stream_info_badges.dart';
import 'subtitle_settings.dart';
import 'subtitle_style_sheet.dart';
import 'fullscreen_helper.dart';

/// Full-screen video player with overlay controls and keyboard navigation.
class PlayerScreen extends ConsumerStatefulWidget {
  final String streamUrl;
  final String channelName;
  final String? channelLogo;
  final List<String> alternativeUrls;
  final List<Map<String, dynamic>> channels;
  final int currentIndex;

  /// Whether to enter OS-level fullscreen as soon as the player opens.
  /// Only the explicit "go fullscreen" action sets this — opening a file, a
  /// recording or a VOD stream stays windowed so the user decides when (and
  /// whether) to go fullscreen.
  final bool startFullscreen;

  const PlayerScreen({
    super.key,
    required this.streamUrl,
    required this.channelName,
    this.channelLogo,
    this.alternativeUrls = const [],
    this.channels = const [],
    this.currentIndex = 0,
    this.startFullscreen = false,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  bool _showOverlay = false;
  int _currentUrlIndex = 0;
  bool _showChannelList = false;
  Offset? _lastMousePosition;
  bool _isFavorite = false;
  // Tracks whether this screen currently has the window in fullscreen, so the
  // toggle can restore the windowed state and dispose only undoes what it did.
  bool _isFullscreen = false;
  // When enabled in Settings, show the current stream URL over the video.
  bool _showStreamUrl = false;

  // Channel switching state
  late int _channelIndex;
  late String _currentChannelName;
  late String? _currentChannelLogo;

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeTimer;

  // Overlay timer
  Timer? _overlayTimer;
  bool _controlBarHovered = false;

  // EPG state
  String? _nowPlayingTitle;
  String? _nowPlayingTime;
  String? _nowDescription;
  String? _nextTitle;
  String? _nextTime;
  String? _groupTitle;
  String? _providerName;

  // Favorite lists
  List<db.FavoriteList> _favoriteLists = [];

  // Track selection state
  bool _subtitlesEnabled = false;
  List<SubtitleTrack> _subtitleTracks = [];
  List<AudioTrack> _audioTracks = [];

  /// Guards the "enable subtitles automatically" pass so it runs at most once
  /// per stream. Track lists arrive incrementally while a stream opens, so
  /// without this the auto-select would fight a user who turns subtitles off.
  bool _autoSubtitleDone = false;

  /// Set when the user explicitly toggles subtitles, which suppresses
  /// auto-select for the rest of this stream.
  bool _subtitleChoiceIsManual = false;

  /// Listener on the shared subtitle preferences, held so it can be detached
  /// in [dispose] — the controller outlives this screen.
  VoidCallback? _subtitleSettingsListener;

  // Subscription to the shared player's track stream. Held so it can be
  // cancelled on dispose — the player is a long-lived singleton, so an
  // uncancelled listener would leak this State across playback sessions.
  StreamSubscription<Tracks>? _tracksSub;

  @override
  void initState() {
    super.initState();
    _channelIndex = widget.currentIndex;
    _currentChannelName = widget.channelName;
    _currentChannelLogo = widget.channelLogo;
    if (widget.channels.isNotEmpty) {
      final ch = widget.channels[_channelIndex];
      _groupTitle = ch['groupTitle']?.toString();
      _providerName = ref
          .read(streamAlternativesProvider)
          .providerName(ch['providerId']?.toString() ?? '');
    }
    if (widget.startFullscreen) {
      FullscreenHelper.enterFullscreen();
    }
    _isFullscreen = widget.startFullscreen;
    _startPlayback();
    _loadEpgInfo();
    _loadFavoriteState();
    _loadShowStreamUrl();
    _applySubtitleSettings();
  }

  /// Push the stored subtitle preferences to mpv, and keep pushing them as the
  /// user edits them.
  ///
  /// Needed on entry because the player is a singleton that may have been
  /// started elsewhere (the inline preview) before these preferences were
  /// loaded from disk.
  void _applySubtitleSettings() {
    final controller = ref.read(subtitleSettingsProvider);
    _subtitleSettingsListener = () {
      if (!mounted) return;
      ref.read(playerServiceProvider).applySubtitleStyle(controller.settings);
    };
    controller.addListener(_subtitleSettingsListener!);
    _subtitleSettingsListener!();
  }

  Future<void> _loadShowStreamUrl() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _showStreamUrl = prefs.getBool('show_stream_url') ?? false);
    }
  }

  void _copyStreamUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Stream URL copied'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Compact, copyable stream-URL pill shown over the video. Single line,
  /// ellipsized (URLs are long), with a copy button; tapping anywhere copies.
  Widget _buildStreamUrlBar(String? url) {
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _copyStreamUrl(url),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_rounded, size: 15, color: Colors.white54),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.copy_rounded,
                  size: 15,
                  color: Colors.white54,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadFavoriteState() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String? ?? '';
    if (channelId.isEmpty) return;
    final database = ref.read(databaseProvider);
    final lists = await database.getAllFavoriteLists();
    final listsForChannel = await database.getListsForChannel(channelId);
    if (mounted) {
      setState(() {
        _favoriteLists = lists;
        _isFavorite = listsForChannel.isNotEmpty;
      });
    }
  }

  Future<void> _loadEpgInfo() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final epgId = ch['epgId'] as String?;
    if (epgId == null || epgId.isEmpty) {
      if (mounted) {
        setState(() {
          _nowPlayingTitle = null;
          _nowPlayingTime = null;
          _nowDescription = null;
          _nextTitle = null;
          _nextTime = null;
        });
      }
      return;
    }

    final database = ref.read(databaseProvider);
    final now = DateTime.now();
    final programmes = await database.getProgrammes(
      epgChannelId: epgId,
      start: now.subtract(const Duration(hours: 1)),
      end: now.add(const Duration(hours: 6)),
    );

    if (!mounted) return;

    db.EpgProgramme? current;
    db.EpgProgramme? next;
    for (final p in programmes) {
      if (now.isAfter(p.start) && now.isBefore(p.stop)) {
        current = p;
      } else if (current != null && next == null && now.isBefore(p.start)) {
        next = p;
        break;
      }
    }

    setState(() {
      _nowPlayingTitle = current?.title;
      _nowPlayingTime = current != null
          ? '${_fmtTime(current.start)} – ${_fmtTime(current.stop)}'
          : null;
      _nowDescription = current?.description;
      _nextTitle = next?.title;
      _nextTime = next != null
          ? '${_fmtTime(next.start)} – ${_fmtTime(next.stop)}'
          : null;
    });
  }

  String _fmtTime(DateTime t) {
    final tod = TimeOfDay.fromDateTime(t);
    final hour = tod.hourOfPeriod == 0 ? 12 : tod.hourOfPeriod;
    final min = tod.minute.toString().padLeft(2, '0');
    final period = tod.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$min $period';
  }

  void _startPlayback() {
    final playerService = ref.read(playerServiceProvider);
    final urls = [widget.streamUrl, ...widget.alternativeUrls];
    final requested = urls[_currentUrlIndex];

    // Nothing to open — the caller navigated here without a URL. Keep whatever
    // the shared player is already showing instead of opening an empty media,
    // which would tear down the video output and leave a black screen.
    if (requested.isEmpty) {
      _attachTrackListener(playerService);
      return;
    }

    // Reuse the already-running stream only when it is the one we were asked
    // for; otherwise (a different channel, or a VOD/file) start it fresh.
    final alreadyPlayingRequested =
        playerService.currentUrl == requested &&
        (playerService.player.state.playing ||
            playerService.player.state.buffering);

    if (!alreadyPlayingRequested) {
      playerService.play(
        requested,
        channelId: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['id'] as String?
            : null,
        epgChannelId: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['epgChannelId'] as String?
            : null,
        tvgId: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['tvgId'] as String?
            : null,
        channelName: _currentChannelName,
        vanityName: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['vanityName'] as String?
            : null,
        originalName: widget.channels.isNotEmpty
            ? widget.channels[_channelIndex]['tvgName'] as String?
            : null,
      );
    }

    _attachTrackListener(playerService);
  }

  /// Load track info once tracks become available. Cancels any previous
  /// subscription first so re-entry (e.g. channel switch) doesn't stack
  /// listeners on the singleton player.
  void _attachTrackListener(PlayerService playerService) {
    _tracksSub?.cancel();
    _tracksSub = playerService.player.stream.tracks.listen((tracks) {
      if (mounted) _loadTrackInfo();
    });
  }

  Future<void> _showCastPicker() async {
    final device = await showCastDialog(context, ref);
    if (device != null && mounted) {
      final castService = ref.read(castServiceProvider);
      final urls = [widget.streamUrl, ...widget.alternativeUrls];
      final success = await castService.castTo(
        device,
        urls[_currentUrlIndex],
        title: widget.channelName,
      );
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Casting to ${device.name}'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 2),
          ),
        );
        setState(() {});
      }
    }
  }

  void _loadTrackInfo() {
    final player = ref.read(playerServiceProvider).player;
    final tracks = player.state.tracks;
    setState(() {
      _subtitleTracks = tracks.subtitle
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      _audioTracks = tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      _subtitlesEnabled =
          player.state.track.subtitle.id != 'no' &&
          player.state.track.subtitle.id != 'auto';
    });
    _maybeAutoEnableSubtitles();
  }

  /// Turn on the preferred subtitle track when the user asked for subtitles to
  /// come up by themselves. Runs once per stream and never overrides a manual
  /// choice.
  Future<void> _maybeAutoEnableSubtitles() async {
    if (_autoSubtitleDone || _subtitleChoiceIsManual) return;
    if (_subtitleTracks.isEmpty) return;
    final settings = ref.read(subtitleSettingsProvider).settings;
    if (!settings.autoEnable) return;

    _autoSubtitleDone = true;
    final selected = await ref
        .read(playerServiceProvider)
        .selectPreferredSubtitle(settings.preferredLanguage);
    if (!mounted || selected == null) return;
    setState(() => _subtitlesEnabled = true);
  }

  void _toggleSubtitles() {
    final playerService = ref.read(playerServiceProvider);
    _subtitleChoiceIsManual = true;
    if (_subtitlesEnabled) {
      playerService.player.setSubtitleTrack(SubtitleTrack.no());
      setState(() => _subtitlesEnabled = false);
      return;
    }
    if (_subtitleTracks.isEmpty) {
      // Nothing to switch on. Open the picker instead of dead-ending: from
      // there the user can attach a subtitle file or adjust styling, and it
      // keeps the feature reachable with a remote (no long-press needed).
      _showSubtitlePicker();
      return;
    }
    // Honour the preferred language rather than blindly taking track 1.
    final language =
        ref.read(subtitleSettingsProvider).settings.preferredLanguage;
    playerService.selectPreferredSubtitle(language);
    setState(() => _subtitlesEnabled = true);
  }

  /// Let the user attach a subtitle file to the current stream. Useful for VOD
  /// and recordings whose subtitles ship separately.
  Future<void> _loadExternalSubtitle() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt', 'sub', 'txt'],
      );
    } catch (e) {
      debugPrint('[Player] Subtitle file picker failed: $e');
    }
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    _subtitleChoiceIsManual = true;
    try {
      await ref.read(playerServiceProvider).loadExternalSubtitle(path);
      if (!mounted) return;
      setState(() => _subtitlesEnabled = true);
      _loadTrackInfo();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load subtitle file: $e'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showSubtitlePicker() {
    _loadTrackInfo();
    final player = ref.read(playerServiceProvider).player;
    final currentId = player.state.track.subtitle.id;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.closed_caption, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Subtitles',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_subtitleTracks.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'This stream has no subtitle tracks. You can still load a '
                    'subtitle file.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.block,
                  color: currentId == 'no'
                      ? Colors.greenAccent
                      : Colors.white54,
                  size: 20,
                ),
                title: const Text(
                  'Off',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                trailing: currentId == 'no'
                    ? const Icon(
                        Icons.check,
                        color: Colors.greenAccent,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  player.setSubtitleTrack(SubtitleTrack.no());
                  setState(() => _subtitlesEnabled = false);
                  Navigator.of(ctx).pop();
                },
              ),
              ..._subtitleTracks.map((t) {
                final isActive = t.id == currentId;
                return ListTile(
                  dense: true,
                  title: Text(
                    t.title ?? t.language ?? t.id,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: t.language != null
                      ? Text(
                          t.language!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        )
                      : null,
                  trailing: isActive
                      ? const Icon(
                          Icons.check,
                          color: Colors.greenAccent,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    _subtitleChoiceIsManual = true;
                    player.setSubtitleTrack(t);
                    setState(() => _subtitlesEnabled = true);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
              const Divider(height: 12, color: Colors.white12),
              ListTile(
                dense: true,
                leading: const Icon(
                  Icons.note_add_outlined,
                  color: Colors.white54,
                  size: 20,
                ),
                title: const Text(
                  'Load subtitle file…',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  'SRT, ASS, VTT',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _loadExternalSubtitle();
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(
                  Icons.tune_rounded,
                  color: Colors.white54,
                  size: 20,
                ),
                title: const Text(
                  'Appearance & sync…',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                subtitle: const Text(
                  'Size, colour, position, delay',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  showSubtitleStyleSheet(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAudioPicker() {
    _loadTrackInfo();
    final player = ref.read(playerServiceProvider).player;
    final currentId = player.state.track.audio.id;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.audiotrack, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Audio Tracks',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._audioTracks.map((t) {
                final isActive = t.id == currentId;
                return ListTile(
                  dense: true,
                  title: Text(
                    t.title ?? t.language ?? t.id,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: t.language != null
                      ? Text(
                          t.language!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        )
                      : null,
                  trailing: isActive
                      ? const Icon(
                          Icons.check,
                          color: Colors.greenAccent,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    player.setAudioTrack(t);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _autoHideOverlay() {
    _overlayTimer?.cancel();
    if (_controlBarHovered) return; // keep visible while mouse is over controls
    _overlayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  void _showControls() {
    if (!_showOverlay) setState(() => _showOverlay = true);
    _autoHideOverlay();
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) _autoHideOverlay();
  }

  // ---- Keyboard controls ----

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isAndroid = Platform.isAndroid;

    // Escape / Backspace / Back → close the channel list first, then leave
    // fullscreen (for a windowed player), then exit the player. Escape should
    // never drop the user out of the app while the window is still fullscreen.
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack) {
      if (_showChannelList) {
        setState(() => _showChannelList = false);
        return KeyEventResult.handled;
      }
      if (_isFullscreen && !widget.startFullscreen) {
        _toggleFullscreen();
        return KeyEventResult.handled;
      }
      _exitPlayer();
      return KeyEventResult.handled;
    }

    // F / F11 → toggle fullscreen
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }

    // C → toggle subtitles, Shift+C → pick a track / open styling. C follows
    // the "closed caption" convention; S is already the search shortcut
    // elsewhere in the app.
    if (key == LogicalKeyboardKey.keyC) {
      HardwareKeyboard.instance.isShiftPressed
          ? _showSubtitlePicker()
          : _toggleSubtitles();
      _showControls();
      return KeyEventResult.handled;
    }

    // Z / X → nudge subtitle timing (mpv's own bindings).
    if (key == LogicalKeyboardKey.keyZ || key == LogicalKeyboardKey.keyX) {
      _nudgeSubtitleDelay(key == LogicalKeyboardKey.keyZ ? -0.5 : 0.5);
      return KeyEventResult.handled;
    }

    // Select / Enter → toggle overlay
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _toggleOverlay();
      return KeyEventResult.handled;
    }

    // Channel switching: use channelUp/Down on Android, arrows elsewhere
    if (key == LogicalKeyboardKey.channelUp ||
        (!isAndroid && key == LogicalKeyboardKey.arrowUp)) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.channelDown ||
        (!isAndroid && key == LogicalKeyboardKey.arrowDown)) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }

    // Volume: only on non-Android (D-pad arrows needed for focus on Android)
    if (!isAndroid && key == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    if (!isAndroid && key == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Leave the player route, restoring the window in [dispose].
  void _exitPlayer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      GoRouter.of(context).canPop()
          ? GoRouter.of(context).pop()
          : GoRouter.of(context).go('/');
    });
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      // This route was opened *as* the fullscreen presentation of a channel,
      // so its windowed form is the small inline preview on the screen below —
      // not a player stretched across the whole app window. Leaving fullscreen
      // therefore means going back; dispose() restores the window size.
      if (widget.startFullscreen) {
        _exitPlayer();
        return;
      }
      FullscreenHelper.exitFullscreen();
      if (mounted) setState(() => _isFullscreen = false);
      return;
    }
    await FullscreenHelper.enterFullscreen();
    if (mounted) setState(() => _isFullscreen = true);
  }

  void _switchChannel(int delta) {
    if (widget.channels.isEmpty) return;
    setState(() {
      _channelIndex = (_channelIndex + delta) % widget.channels.length;
      if (_channelIndex < 0) _channelIndex += widget.channels.length;
      final ch = widget.channels[_channelIndex];
      _currentChannelName = ch['name'] as String? ?? '';
      _currentChannelLogo = ch['tvgLogo'] as String?;
      _groupTitle = ch['groupTitle']?.toString();
      _providerName = ref
          .read(streamAlternativesProvider)
          .providerName(ch['providerId']?.toString() ?? '');
      _currentUrlIndex = 0;
      _showOverlay = true;
      // A new stream brings its own tracks, so the auto-enable pass and any
      // manual override from the previous channel no longer apply.
      _autoSubtitleDone = false;
      _subtitleChoiceIsManual = false;
      _subtitleTracks = [];
      _subtitlesEnabled = false;
    });
    final ch = widget.channels[_channelIndex];
    ref
        .read(playerServiceProvider)
        .play(
          ch['streamUrl'] as String? ?? '',
          channelId: ch['id'] as String?,
          epgChannelId: ch['epgChannelId'] as String?,
          tvgId: ch['tvgId'] as String?,
          channelName: ch['name'] as String?,
        );
    _autoHideOverlay();
    _loadEpgInfo();
    _loadFavoriteState();
  }

  /// Shift subtitle timing by [delta] seconds and confirm the new offset, since
  /// the effect is otherwise invisible until the next line of dialogue.
  Future<void> _nudgeSubtitleDelay(double delta) async {
    final playerService = ref.read(playerServiceProvider);
    final next = ((await playerService.getSubtitleDelay()) + delta)
        .clamp(-30.0, 30.0);
    await playerService.setSubtitleDelay(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Subtitle delay ${next >= 0 ? '+' : ''}${next.toStringAsFixed(1)}s',
        ),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _adjustVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 100.0);
      _showVolumeOverlay = true;
    });
    ref.read(playerServiceProvider).setVolume(_volume);
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  @override
  void dispose() {
    _tracksSub?.cancel();
    if (_subtitleSettingsListener != null) {
      ref.read(subtitleSettingsProvider).removeListener(
            _subtitleSettingsListener!,
          );
    }
    _overlayTimer?.cancel();
    _volumeTimer?.cancel();
    if (_isFullscreen) {
      FullscreenHelper.exitFullscreen();
    }
    super.dispose();
  }

  /// Vertical space the control bar occupies. Subtitles are pushed up by this
  /// much while the overlay is visible. Matches the offset used by the stream
  /// URL pill below.
  static const double _controlBarHeight = 96;

  @override
  Widget build(BuildContext context) {
    final playerService = ref.watch(playerServiceProvider);
    final subtitleSettings = ref.watch(subtitleSettingsProvider).settings;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          onHover: (event) {
            // Only show overlay if mouse actually moved (avoid constant re-trigger on Windows)
            if (_lastMousePosition != null &&
                (event.position - _lastMousePosition!).distance < 2) {
              return;
            }
            _lastMousePosition = event.position;
            if (!_showOverlay) {
              setState(() => _showOverlay = true);
              _autoHideOverlay();
            }
          },
          child: GestureDetector(
            onTap: _toggleOverlay,
            onDoubleTap: _toggleFullscreen,
            // Transient, fast-toggling video overlays (control bar, info banner,
            // volume popup) constantly add/remove subtrees. On Windows this
            // churns the semantics tree and spams accessibility_bridge with
            // "Failed to update ui::AXTree" errors. Excluding the player's
            // transient chrome from semantics stops that spam; the video
            // surface itself carries no meaningful semantics anyway.
            child: ExcludeSemantics(
              child: Stack(
                fit: StackFit.expand,
                children: [
                // Video — fill entire screen. Subtitles are drawn by the
                // Video widget's own subtitle view using the user's styling;
                // while the control bar is up they are lifted clear of it so
                // the chrome never sits on top of a line of dialogue.
                Video(
                  controller: playerService.videoController,
                  controls: NoVideoControls,
                  subtitleViewConfiguration: subtitleSettings.viewConfiguration(
                    extraBottomPadding: _showOverlay ? _controlBarHeight : 0,
                  ),
                ),

                // Centered buffering indicator — shown while the stream is
                // (re)buffering, auto-hidden the moment playback resumes.
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
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const SizedBox(
                              width: 48,
                              height: 48,
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

                // Load-timeout message — shown when a stream fails to start
                // playing within the load timeout window.
                Center(
                  child: StreamBuilder<bool>(
                    stream: playerService.loadTimeoutStream,
                    initialData: playerService.loadTimedOut,
                    builder: (context, snapshot) {
                      if (snapshot.data != true) {
                        return const SizedBox.shrink();
                      }
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white70,
                              size: 40,
                            ),
                            SizedBox(height: 10),
                            Text(
                              'Loading timed out',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // TiviMate-style control bar overlay
                PlayerControlBar(
                  visible: _showOverlay,
                  onInteraction: _showControls,
                  onHoverChanged: (hovering) {
                    _controlBarHovered = hovering;
                    if (hovering) {
                      _overlayTimer?.cancel();
                      if (!_showOverlay) setState(() => _showOverlay = true);
                    } else {
                      _autoHideOverlay();
                    }
                  },
                  isCasting: ref.read(castServiceProvider).isCasting,
                  isFavorite: _isFavorite,
                  hasSubtitles: _subtitleTracks.isNotEmpty,
                  subtitlesEnabled: _subtitlesEnabled,
                  onSubtitleToggle: _toggleSubtitles,
                  onSubtitleSelect: _showSubtitlePicker,
                  audioTrackCount: _audioTracks.length,
                  onAudioSelect: _showAudioPicker,
                  onCastTap: () => _showCastPicker(),
                  onBackTap: _exitPlayer,
                  onScreenshot: _takeScreenshot,
                  onFavorite: _toggleFavorite,
                  onPip: _enterPip,
                  onInfo: _showInfoDialog,
                  onRename: _renameCurrentChannel,
                  onSettings: () => GoRouter.of(context).push('/settings'),
                  onChannelList: () =>
                      setState(() => _showChannelList = !_showChannelList),
                  onFullscreenToggle: _toggleFullscreen,
                  isFullscreen: _isFullscreen,
                ),

                // Stream URL bar (enabled via Settings → Show Stream URL).
                // Shown with the controls, above the control bar; tap to copy.
                if (_showOverlay && _showStreamUrl)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 96,
                    child: Center(
                      child: _buildStreamUrlBar(playerService.currentUrl),
                    ),
                  ),

                // Channel info overlay (top, shown alongside control bar)
                if (_showOverlay) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(48, 4, 12, 12),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black87,
                            Colors.black54,
                            Colors.transparent,
                          ],
                          stops: [0.0, 0.7, 1.0],
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Col 1: Channel name + group
                          if (_currentChannelLogo != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Image.network(
                                _currentChannelLogo!,
                                width: 24,
                                height: 24,
                                cacheWidth: 96,
                                fit: BoxFit.contain,
                                errorBuilder: (c, e, s) => const SizedBox(),
                              ),
                            ),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _currentChannelName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (_groupTitle != null &&
                                    _groupTitle!.isNotEmpty)
                                  Text(
                                    _groupTitle!,
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Col 2: Programme name + time + next
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_nowPlayingTitle != null) ...[
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.play_circle_outline,
                                        size: 14,
                                        color: Colors.cyanAccent,
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          _nowPlayingTitle!,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_nowPlayingTime != null)
                                    Text(
                                      _nowPlayingTime!,
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 11,
                                      ),
                                    ),
                                ],
                                if (_nextTitle != null) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    'Next: $_nextTitle${_nextTime != null ? '  $_nextTime' : ''}',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Col 3: Description
                          Expanded(
                            flex: 3,
                            child:
                                (_nowDescription != null &&
                                    _nowDescription!.isNotEmpty)
                                ? Text(
                                    _nowDescription!,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          const SizedBox(width: 16),
                          // Col 4: Stream badges + provider + time
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  StreamInfoBadges(
                                    playerService: ref.read(
                                      playerServiceProvider,
                                    ),
                                  ),
                                  if (_providerName != null &&
                                      _providerName!.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFF6C5CE7,
                                        ).withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: const Color(0xFF6C5CE7),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        _providerName!,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFFA29BFE),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                TimeOfDay.now().format(context),
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // Volume overlay
                if (_showVolumeOverlay)
                  Positioned(
                    top: 80,
                    right: 24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8),
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
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${_volume.round()}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Channel list overlay
                if (_showChannelList && widget.channels.isNotEmpty)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: 320,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.85),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.fromLTRB(16, 40, 8, 8),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.list,
                                  color: Colors.white70,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Channels',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white54,
                                    size: 20,
                                  ),
                                  onPressed: () =>
                                      setState(() => _showChannelList = false),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Colors.white10),
                          Expanded(
                            child: ListView.builder(
                              itemCount: widget.channels.length,
                              itemBuilder: (ctx, i) {
                                final ch = widget.channels[i];
                                final name = ch['name'] as String? ?? '';
                                final isCurrent = i == _channelIndex;
                                return ListTile(
                                  dense: true,
                                  selected: isCurrent,
                                  selectedTileColor: const Color(
                                    0xFF6C5CE7,
                                  ).withValues(alpha: 0.3),
                                  leading: ch['tvgLogo'] != null
                                      ? Image.network(
                                          ch['tvgLogo'] as String,
                                          width: 28,
                                          height: 28,
                                          cacheWidth: 96,
                                          fit: BoxFit.contain,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(
                                                Icons.tv,
                                                size: 28,
                                                color: Colors.white30,
                                              ),
                                        )
                                      : const Icon(
                                          Icons.tv,
                                          size: 28,
                                          color: Colors.white30,
                                        ),
                                  title: Text(
                                    name,
                                    style: TextStyle(
                                      color: isCurrent
                                          ? Colors.white
                                          : Colors.white70,
                                      fontWeight: isCurrent
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      fontSize: 13,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    setState(() => _showChannelList = false);
                                    if (i != _channelIndex) {
                                      _switchChannel(i - _channelIndex);
                                    }
                                  },
                                );
                              },
                            ),
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
      ),
    );
  }

  // ---- Action handlers ----

  Future<void> _takeScreenshot() async {
    final ps = ref.read(playerServiceProvider);
    try {
      final dir = Platform.isMacOS || Platform.isLinux || Platform.isWindows
          ? (await getDownloadsDirectory()) ?? await getTemporaryDirectory()
          : await getTemporaryDirectory();
      final path =
          '${dir.path}/clubtivi_screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = await ps.takeScreenshot(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result != null
                  ? 'Screenshot saved: $path'
                  : 'Screenshot not available',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screenshot failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _toggleFavorite() {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String? ?? '';
    final channelName = ch['name'] as String? ?? '';
    if (channelId.isEmpty) return;
    _showFavoriteListSheet(channelId, channelName);
  }

  Future<void> _showFavoriteListSheet(
    String channelId,
    String channelName,
  ) async {
    final database = ref.read(databaseProvider);
    final listsForChannel = await database.getListsForChannel(channelId);
    final checkedIds = listsForChannel.map((l) => l.id).toSet();

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
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
                          'Add "$channelName" to list',
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
                          await database.addChannelToList(list.id, channelId);
                          checkedIds.add(list.id);
                        } else {
                          await database.removeChannelFromList(
                            list.id,
                            channelId,
                          );
                          checkedIds.remove(list.id);
                        }
                        setSheetState(() {});
                      },
                    );
                  }),
                  const Divider(color: Colors.white12),
                  TextButton.icon(
                    onPressed: () async {
                      final name = await _showCreateListDialog();
                      if (name != null && name.isNotEmpty) {
                        final newList = await database.createFavoriteList(name);
                        await database.addChannelToList(newList.id, channelId);
                        checkedIds.add(newList.id);
                        final updated = await database.getAllFavoriteLists();
                        setState(() => _favoriteLists = updated);
                        setSheetState(() {});
                      }
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
    // Refresh favorite state after sheet closes
    final listsAfter = await database.getListsForChannel(channelId);
    if (mounted) {
      setState(() => _isFavorite = listsAfter.isNotEmpty);
    }
  }

  Future<String?> _showCreateListDialog() async {
    String name = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'New Favorite List',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. Sports, News, Kids',
            hintStyle: TextStyle(color: Colors.white38),
          ),
          onChanged: (v) => name = v,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(name.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _enterPip() async {
    // PiP not yet available on desktop — show a message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Picture-in-Picture — available on mobile'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _renameCurrentChannel() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final channelId = ch['id'] as String?;
    if (channelId == null) return;

    // Load current vanity names
    final prefs = await SharedPreferences.getInstance();
    final vanityJson = prefs.getString('channel_vanity_names');
    Map<String, String> vanityNames = {};
    if (vanityJson != null) {
      try {
        final decoded = jsonDecode(vanityJson) as Map<String, dynamic>;
        vanityNames = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (e) {
        debugPrint('[Player] Failed to parse vanity names: $e');
      }
    }

    final originalName =
        ch['tvgName']?.toString() ??
        ch['originalName']?.toString() ??
        ch['name']?.toString() ??
        '';
    final currentVanity = vanityNames[channelId];
    final controller = TextEditingController(
      text: currentVanity ?? ch['name']?.toString() ?? originalName,
    );

    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Display Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Original: $originalName',
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
    controller.dispose();
    if (result == null) return;

    if (result == '\x00RESET') {
      vanityNames.remove(channelId);
    } else if (result.isNotEmpty && result != originalName) {
      vanityNames[channelId] = result;
    } else {
      return;
    }

    await prefs.setString('channel_vanity_names', jsonEncode(vanityNames));

    // Update in-memory channel map and displayed name
    if (!mounted) return;
    setState(() {
      widget.channels[_channelIndex]['vanityName'] = vanityNames[channelId];
      widget.channels[_channelIndex]['name'] =
          vanityNames[channelId] ?? originalName;
      _currentChannelName = vanityNames[channelId] ?? originalName;
    });
  }

  void _showInfoDialog() {
    if (widget.channels.isEmpty) return;
    try {
      final ch = widget.channels[_channelIndex];
      final channel = db.Channel(
        id: ch['id']?.toString() ?? '',
        providerId: ch['providerId']?.toString() ?? '',
        name: ch['name']?.toString() ?? '',
        groupTitle: ch['groupTitle']?.toString() ?? '',
        streamUrl: ch['streamUrl']?.toString() ?? '',
        streamType: ch['streamType']?.toString() ?? 'live',
        tvgId: ch['tvgId']?.toString(),
        tvgName: ch['tvgName']?.toString(),
        tvgLogo: ch['tvgLogo']?.toString(),
        favorite: false,
        hidden: false,
        sortOrder: 0,
      );
      final ps = ref.read(playerServiceProvider);
      final epgId = ch['epgId']?.toString();
      final alts = ref
          .read(streamAlternativesProvider)
          .getAlternativeDetails(
            channelId: ch['id']?.toString() ?? '',
            epgChannelId: epgId,
            tvgId: ch['tvgId']?.toString(),
            channelName: ch['name']?.toString(),
            vanityName: ch['vanityName']?.toString(),
            originalName: ch['tvgName']?.toString(),
            excludeUrl: ch['streamUrl']?.toString() ?? '',
          );
      ChannelDebugDialog.show(
        context,
        channel,
        ps,
        mappedEpgId: epgId,
        originalName:
            ch['tvgName']?.toString() ??
            ch['originalName']?.toString() ??
            ch['name']?.toString(),
        currentProviderName: ref
            .read(streamAlternativesProvider)
            .providerName(ch['providerId']?.toString() ?? ''),
        alternatives: alts,
      );
    } catch (e) {
      debugPrint('Error showing info dialog: $e');
    }
  }
}

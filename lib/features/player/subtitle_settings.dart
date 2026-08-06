import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who draws the subtitles.
///
/// * [flutter] — media_kit publishes the current subtitle text (mpv's
///   `sub-text`) and a Flutter widget renders it. Consistent look on every
///   platform and styleable with Flutter text styles, but text-only: bitmap
///   subtitles (DVB / PGS, common on IPTV and Blu-ray rips) carry no text and
///   therefore never appear.
/// * [player] — mpv renders subtitles into the video itself
///   (`sub-visibility=yes`). Handles bitmap subtitles and honours the
///   subtitle's own positioning; styling goes through mpv properties.
enum SubtitleRenderer { flutter, player }

/// Appearance and behaviour preferences for subtitle display.
///
/// Persisted in [SharedPreferences] so the player, the inline preview and the
/// Settings screen all agree, and so the choice survives a restart.
@immutable
class SubtitleSettings {
  /// Turn on the best-matching subtitle track automatically when a stream
  /// starts, instead of waiting for the user to press CC.
  final bool autoEnable;

  /// Preferred subtitle language as an ISO 639 code (`eng`, `chi`, …), or an
  /// empty string for "first available".
  final String preferredLanguage;

  /// Base font size in logical pixels, measured against a 1920x1080 surface.
  /// [SubtitleView] scales it down for smaller video areas.
  final double fontSize;

  /// Text colour (stored as an ARGB int so it can live in prefs).
  final int colorValue;

  /// Opacity of the box drawn behind the text, 0 (none) to 1 (opaque).
  final double backgroundOpacity;

  /// Draw a dark outline around the glyphs. Keeps text readable over bright
  /// video when the background box is off.
  final bool outline;

  final bool bold;

  /// Distance from the bottom of the video to the subtitles, in logical pixels.
  final double bottomOffset;

  final SubtitleRenderer renderer;

  const SubtitleSettings({
    this.autoEnable = false,
    this.preferredLanguage = '',
    this.fontSize = 32.0,
    this.colorValue = 0xFFFFFFFF,
    this.backgroundOpacity = 0.6,
    this.outline = true,
    this.bold = false,
    this.bottomOffset = 24.0,
    this.renderer = SubtitleRenderer.flutter,
  });

  static const fontSizeMin = 16.0;
  static const fontSizeMax = 64.0;
  static const bottomOffsetMax = 240.0;

  /// Selectable text colours — high-contrast picks that stay legible over
  /// video. Keys are used as labels in the pickers.
  static const colorChoices = <String, int>{
    'White': 0xFFFFFFFF,
    'Yellow': 0xFFFFEB3B,
    'Cyan': 0xFF4DD0E1,
    'Green': 0xFF81C784,
    'Grey': 0xFFBDBDBD,
  };

  /// Common subtitle languages, keyed by the label shown in the UI. Values are
  /// the ISO 639-2 codes mpv/ffmpeg report on stream metadata.
  static const languageChoices = <String, String>{
    'First available': '',
    'English': 'eng',
    'Chinese': 'chi',
    'Spanish': 'spa',
    'French': 'fre',
    'German': 'ger',
    'Portuguese': 'por',
    'Italian': 'ita',
    'Arabic': 'ara',
    'Russian': 'rus',
    'Japanese': 'jpn',
    'Korean': 'kor',
    'Hindi': 'hin',
  };

  Color get color => Color(colorValue);

  String get languageLabel => languageChoices.entries
      .firstWhere(
        (e) => e.value == preferredLanguage,
        orElse: () => MapEntry(preferredLanguage.toUpperCase(), preferredLanguage),
      )
      .key;

  String get colorLabel => colorChoices.entries
      .firstWhere(
        (e) => e.value == colorValue,
        orElse: () => const MapEntry('Custom', 0),
      )
      .key;

  /// The text style used by the Flutter renderer.
  TextStyle get textStyle => TextStyle(
        height: 1.3,
        fontSize: fontSize,
        letterSpacing: 0.0,
        wordSpacing: 0.0,
        color: color,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        backgroundColor: backgroundOpacity <= 0
            ? Colors.transparent
            : Colors.black.withValues(alpha: backgroundOpacity),
        // Cheap, GPU-friendly stand-in for a real stroke: four offset shadows
        // read as an outline at subtitle sizes without a second text pass.
        shadows: outline
            ? const [
                Shadow(color: Colors.black, offset: Offset(-1.5, -1.5), blurRadius: 2),
                Shadow(color: Colors.black, offset: Offset(1.5, -1.5), blurRadius: 2),
                Shadow(color: Colors.black, offset: Offset(1.5, 1.5), blurRadius: 2),
                Shadow(color: Colors.black, offset: Offset(-1.5, 1.5), blurRadius: 2),
              ]
            : null,
      );

  /// Build the config for media_kit's [SubtitleView].
  ///
  /// [extraBottomPadding] lifts the text above transient chrome (the control
  /// bar) so controls never cover a line of dialogue. When mpv is doing the
  /// drawing the view is hidden outright, otherwise both would render and the
  /// text would appear twice.
  SubtitleViewConfiguration viewConfiguration({
    double extraBottomPadding = 0,
  }) =>
      SubtitleViewConfiguration(
        visible: renderer == SubtitleRenderer.flutter,
        style: textStyle,
        padding: EdgeInsets.fromLTRB(
          16.0,
          0.0,
          16.0,
          bottomOffset + extraBottomPadding,
        ),
      );

  SubtitleSettings copyWith({
    bool? autoEnable,
    String? preferredLanguage,
    double? fontSize,
    int? colorValue,
    double? backgroundOpacity,
    bool? outline,
    bool? bold,
    double? bottomOffset,
    SubtitleRenderer? renderer,
  }) =>
      SubtitleSettings(
        autoEnable: autoEnable ?? this.autoEnable,
        preferredLanguage: preferredLanguage ?? this.preferredLanguage,
        fontSize: fontSize ?? this.fontSize,
        colorValue: colorValue ?? this.colorValue,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        outline: outline ?? this.outline,
        bold: bold ?? this.bold,
        bottomOffset: bottomOffset ?? this.bottomOffset,
        renderer: renderer ?? this.renderer,
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleSettings &&
      other.autoEnable == autoEnable &&
      other.preferredLanguage == preferredLanguage &&
      other.fontSize == fontSize &&
      other.colorValue == colorValue &&
      other.backgroundOpacity == backgroundOpacity &&
      other.outline == outline &&
      other.bold == bold &&
      other.bottomOffset == bottomOffset &&
      other.renderer == renderer;

  @override
  int get hashCode => Object.hash(
        autoEnable,
        preferredLanguage,
        fontSize,
        colorValue,
        backgroundOpacity,
        outline,
        bold,
        bottomOffset,
        renderer,
      );

  // ── Persistence ────────────────────────────────────────────────────────
  static const _kAutoEnable = 'subtitle_auto_enable';
  static const _kLanguage = 'subtitle_preferred_language';
  static const _kFontSize = 'subtitle_font_size';
  static const _kColor = 'subtitle_color';
  static const _kBackground = 'subtitle_background_opacity';
  static const _kOutline = 'subtitle_outline';
  static const _kBold = 'subtitle_bold';
  static const _kBottomOffset = 'subtitle_bottom_offset';
  static const _kRenderer = 'subtitle_renderer';

  static SubtitleSettings fromPrefs(SharedPreferences prefs) {
    const d = SubtitleSettings();
    return SubtitleSettings(
      autoEnable: prefs.getBool(_kAutoEnable) ?? d.autoEnable,
      preferredLanguage: prefs.getString(_kLanguage) ?? d.preferredLanguage,
      fontSize: (prefs.getDouble(_kFontSize) ?? d.fontSize)
          .clamp(fontSizeMin, fontSizeMax),
      colorValue: prefs.getInt(_kColor) ?? d.colorValue,
      backgroundOpacity:
          (prefs.getDouble(_kBackground) ?? d.backgroundOpacity).clamp(0.0, 1.0),
      outline: prefs.getBool(_kOutline) ?? d.outline,
      bold: prefs.getBool(_kBold) ?? d.bold,
      bottomOffset: (prefs.getDouble(_kBottomOffset) ?? d.bottomOffset)
          .clamp(0.0, bottomOffsetMax),
      renderer: prefs.getString(_kRenderer) == 'player'
          ? SubtitleRenderer.player
          : SubtitleRenderer.flutter,
    );
  }

  Future<void> saveTo(SharedPreferences prefs) async {
    await prefs.setBool(_kAutoEnable, autoEnable);
    await prefs.setString(_kLanguage, preferredLanguage);
    await prefs.setDouble(_kFontSize, fontSize);
    await prefs.setInt(_kColor, colorValue);
    await prefs.setDouble(_kBackground, backgroundOpacity);
    await prefs.setBool(_kOutline, outline);
    await prefs.setBool(_kBold, bold);
    await prefs.setDouble(_kBottomOffset, bottomOffset);
    await prefs.setString(
      _kRenderer,
      renderer == SubtitleRenderer.player ? 'player' : 'flutter',
    );
  }
}

/// Holds the current [SubtitleSettings] and writes every change through to
/// [SharedPreferences].
///
/// Shared by the player overlay (adjust while watching) and the Settings
/// screen (set the defaults), so a change in one is visible in the other
/// immediately rather than on the next app start.
class SubtitleSettingsController extends ChangeNotifier {
  SubtitleSettings _settings = const SubtitleSettings();
  bool _loaded = false;

  SubtitleSettingsController() {
    _load();
  }

  SubtitleSettings get settings => _settings;

  /// Whether prefs have been read yet. Until then [settings] holds defaults.
  bool get loaded => _loaded;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _settings = SubtitleSettings.fromPrefs(prefs);
    } catch (_) {
      // Keep defaults — subtitles are a display preference, never a hard error.
    }
    _loaded = true;
    notifyListeners();
  }

  /// Replace the settings and persist them. Listeners are notified straight
  /// away so the UI reacts without waiting on disk.
  Future<void> update(SubtitleSettings next) async {
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await next.saveTo(prefs);
    } catch (_) {}
  }

  Future<void> reset() => update(const SubtitleSettings());
}

/// App-wide subtitle preferences.
final subtitleSettingsProvider =
    ChangeNotifierProvider<SubtitleSettingsController>(
  (ref) => SubtitleSettingsController(),
);

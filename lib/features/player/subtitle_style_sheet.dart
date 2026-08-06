import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'player_service.dart';
import 'subtitle_settings.dart';

/// Open the subtitle appearance panel over the player.
///
/// Every change is applied to the running stream and persisted immediately, so
/// the user can judge the result against the video instead of guessing.
Future<void> showSubtitleStyleSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1A2E),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _SubtitleStyleSheet(),
  );
}

class _SubtitleStyleSheet extends ConsumerStatefulWidget {
  const _SubtitleStyleSheet();

  @override
  ConsumerState<_SubtitleStyleSheet> createState() =>
      _SubtitleStyleSheetState();
}

class _SubtitleStyleSheetState extends ConsumerState<_SubtitleStyleSheet> {
  double _delay = 0;

  @override
  void initState() {
    super.initState();
    ref.read(playerServiceProvider).getSubtitleDelay().then((value) {
      if (mounted) setState(() => _delay = value);
    });
  }

  /// Persist [next] and push the mpv-side properties to the running player so
  /// the change is visible behind the sheet right away.
  void _apply(SubtitleSettings next) {
    ref.read(subtitleSettingsProvider).update(next);
    ref.read(playerServiceProvider).applySubtitleStyle(next);
  }

  void _setDelay(double seconds) {
    final clamped = seconds.clamp(-10.0, 10.0);
    setState(() => _delay = clamped);
    ref.read(playerServiceProvider).setSubtitleDelay(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(subtitleSettingsProvider).settings;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  const Icon(Icons.subtitles_rounded,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Subtitle Appearance',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      _apply(const SubtitleSettings());
                      _setDelay(0);
                    },
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                shrinkWrap: true,
                children: [
                  _preview(settings),

                  _sectionLabel('Renderer'),
                  _rendererSelector(settings),

                  _sectionLabel('Text'),
                  _slider(
                    icon: Icons.format_size_rounded,
                    label: 'Size',
                    value: settings.fontSize,
                    min: SubtitleSettings.fontSizeMin,
                    max: SubtitleSettings.fontSizeMax,
                    divisions: 24,
                    display: settings.fontSize.round().toString(),
                    onChanged: (v) => _apply(settings.copyWith(fontSize: v)),
                  ),
                  _colorSelector(settings),
                  SwitchListTile(
                    dense: true,
                    secondary: const Icon(Icons.format_bold_rounded,
                        color: Colors.white70),
                    title: const Text('Bold',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                    value: settings.bold,
                    onChanged: (v) => _apply(settings.copyWith(bold: v)),
                  ),
                  SwitchListTile(
                    dense: true,
                    secondary: const Icon(Icons.border_color_rounded,
                        color: Colors.white70),
                    title: const Text('Outline',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: const Text(
                      'Dark edge around letters — helps over bright video',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    value: settings.outline,
                    onChanged: (v) => _apply(settings.copyWith(outline: v)),
                  ),

                  _sectionLabel('Placement'),
                  _slider(
                    icon: Icons.opacity_rounded,
                    label: 'Background',
                    value: settings.backgroundOpacity,
                    min: 0,
                    max: 1,
                    divisions: 10,
                    display: '${(settings.backgroundOpacity * 100).round()}%',
                    onChanged: (v) =>
                        _apply(settings.copyWith(backgroundOpacity: v)),
                  ),
                  _slider(
                    icon: Icons.vertical_align_bottom_rounded,
                    label: 'Bottom margin',
                    value: settings.bottomOffset,
                    min: 0,
                    max: SubtitleSettings.bottomOffsetMax,
                    divisions: 24,
                    display: '${settings.bottomOffset.round()} px',
                    onChanged: (v) => _apply(settings.copyWith(bottomOffset: v)),
                  ),

                  _sectionLabel('Sync'),
                  _delayRow(),

                  _sectionLabel('Behaviour'),
                  SwitchListTile(
                    dense: true,
                    secondary: const Icon(Icons.play_circle_outline_rounded,
                        color: Colors.white70),
                    title: const Text('Enable automatically',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: const Text(
                      'Turn on subtitles when a stream has them',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    value: settings.autoEnable,
                    onChanged: (v) {
                      _apply(settings.copyWith(autoEnable: v));
                      // Act on the current stream too, so the switch does
                      // something visible instead of only affecting the next
                      // channel.
                      final playerService = ref.read(playerServiceProvider);
                      v
                          ? playerService
                              .selectPreferredSubtitle(settings.preferredLanguage)
                          : playerService.player
                              .setSubtitleTrack(SubtitleTrack.no());
                    },
                  ),
                  _languageSelector(settings),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Live sample of the current style so the effect is visible even when the
  /// stream happens to have no subtitle on screen at that moment.
  Widget _preview(SubtitleSettings settings) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
        gradient: const LinearGradient(
          colors: [Color(0xFF11111B), Color(0xFF2A2A3E)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        'The quick brown fox',
        textAlign: TextAlign.center,
        // The real renderer scales text down for smaller video areas; mirror
        // that here so the preview is not wildly larger than the result.
        style: settings.textStyle.copyWith(fontSize: settings.fontSize * 0.6),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF9B8CFF),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _rendererSelector(SubtitleSettings settings) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<SubtitleRenderer>(
            segments: const [
              ButtonSegment(
                value: SubtitleRenderer.flutter,
                label: Text('App'),
                icon: Icon(Icons.text_fields_rounded, size: 16),
              ),
              ButtonSegment(
                value: SubtitleRenderer.player,
                label: Text('Player'),
                icon: Icon(Icons.movie_filter_rounded, size: 16),
              ),
            ],
            selected: {settings.renderer},
            showSelectedIcon: false,
            onSelectionChanged: (values) =>
                _apply(settings.copyWith(renderer: values.first)),
          ),
          const SizedBox(height: 6),
          Text(
            settings.renderer == SubtitleRenderer.flutter
                ? 'Text subtitles styled by the app. Bitmap subtitles '
                    '(DVB, PGS) will not show.'
                : 'Drawn into the video by the player. Needed for bitmap '
                    'subtitles; styling is approximate.',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _colorSelector(SubtitleSettings settings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.palette_rounded, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in SubtitleSettings.colorChoices.entries)
                  _ColorDot(
                    color: Color(entry.value),
                    label: entry.key,
                    selected: settings.colorValue == entry.value,
                    onTap: () =>
                        _apply(settings.copyWith(colorValue: entry.value)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _delayRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Row(
        children: [
          const Icon(Icons.av_timer_rounded, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Delay',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: 'Show 0.5s earlier',
            onPressed: () => _setDelay(_delay - 0.5),
            icon: const Icon(Icons.remove_rounded, color: Colors.white70),
          ),
          SizedBox(
            width: 64,
            child: Text(
              '${_delay >= 0 ? '+' : ''}${_delay.toStringAsFixed(1)}s',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: 'Show 0.5s later',
            onPressed: () => _setDelay(_delay + 0.5),
            icon: const Icon(Icons.add_rounded, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _languageSelector(SubtitleSettings settings) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.translate_rounded, color: Colors.white70),
      title: const Text('Preferred language',
          style: TextStyle(color: Colors.white, fontSize: 13)),
      subtitle: Text(
        settings.languageLabel,
        style: const TextStyle(color: Colors.white38, fontSize: 11),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Preferred Subtitle Language'),
            children: [
              RadioGroup<String>(
                groupValue: settings.preferredLanguage,
                onChanged: (v) => Navigator.pop(ctx, v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry
                        in SubtitleSettings.languageChoices.entries)
                      RadioListTile<String>(
                        title: Text(entry.key),
                        value: entry.value,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        if (picked != null) {
          _apply(settings.copyWith(preferredLanguage: picked));
          // Re-pick the track only when subtitles are already showing, so
          // changing the preference doesn't switch them on unasked.
          final player = ref.read(playerServiceProvider);
          final currentId = player.player.state.track.subtitle.id;
          if (currentId != 'no') {
            player.selectPreferredSubtitle(picked);
          }
        }
      },
    );
  }
}

/// Round colour swatch with a selected ring, sized for touch and D-pad focus.
class _ColorDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ColorDot({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Semantics(
          label: label,
          selected: selected,
          button: true,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.white : Colors.white24,
                  width: selected ? 3 : 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

/// Compact, periodically-refreshing technical badges (resolution, fps, codec,
/// audio channels) used in the inline preview overlay's top bar.
class PreviewInfoBadges extends StatefulWidget {
  final dynamic playerService;
  const PreviewInfoBadges({super.key, required this.playerService});

  @override
  State<PreviewInfoBadges> createState() => _PreviewInfoBadgesState();
}

class _PreviewInfoBadgesState extends State<PreviewInfoBadges> {
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

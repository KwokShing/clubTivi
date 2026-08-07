import 'package:flutter_test/flutter_test.dart';

import 'package:clubtivi/features/player/hls_subtitle_loader.dart';

/// Verbatim capture of a real segment from the TVB Plus WebVTT rendition.
/// Note the unbounded hour field: 496128:37:40.000 is absolute Unix time
/// (496128*3600 + 37*60 + 40 == 1786063060), and there is no X-TIMESTAMP-MAP.
const realSegment = '''WEBVTT

1
496128:37:40.000 --> 496128:37:42.000
主要因為當地政府「開綠燈」

1
496128:37:42.000 --> 496128:37:42.273
主要因為當地政府「開綠燈」

2
496128:37:42.461 --> 496128:37:43.942
深圳市和羅湖政府

3
496128:37:43.988 --> 496128:37:44.000
都很支持這件事
''';

void main() {
  group('parseVttTimestamp', () {
    test('parses unbounded hour fields used for absolute Unix time', () {
      expect(parseVttTimestamp('496128:37:40.000'), 1786063060.0);
    });

    test('parses ordinary HH:MM:SS.mmm', () {
      expect(parseVttTimestamp('01:02:03.500'), 3723.5);
    });

    test('parses MM:SS.mmm', () {
      expect(parseVttTimestamp('02:03.250'), 123.25);
    });

    test('accepts comma as the decimal separator', () {
      expect(parseVttTimestamp('00:00:01,500'), 1.5);
    });

    test('tolerates surrounding whitespace and CR', () {
      expect(parseVttTimestamp('  00:00:02.000\r'), 2.0);
    });

    test('rejects non-timestamps', () {
      expect(parseVttTimestamp('WEBVTT'), isNull);
      expect(parseVttTimestamp(''), isNull);
    });
  });

  group('parseWebVtt', () {
    test('extracts every cue from a real segment', () {
      final cues = parseWebVtt(realSegment);
      expect(cues, hasLength(4));
      expect(cues.first.start, 1786063060.0);
      expect(cues.first.end, 1786063062.0);
      expect(cues.first.text, '主要因為當地政府「開綠燈」');
      expect(cues.last.text, '都很支持這件事');
    });

    test('handles CRLF line endings', () {
      final cues = parseWebVtt(realSegment.replaceAll('\n', '\r\n'));
      expect(cues, hasLength(4));
      expect(cues.first.text, '主要因為當地政府「開綠燈」');
    });

    test('ignores an empty segment', () {
      expect(parseWebVtt('WEBVTT\n\n'), isEmpty);
    });

    test('ignores cue settings after the end timestamp', () {
      final cues = parseWebVtt(
        'WEBVTT\n\n00:00:01.000 --> 00:00:02.000 align:start position:50%\nhi\n',
      );
      expect(cues, hasLength(1));
      expect(cues.single.end, 2.0);
      expect(cues.single.text, 'hi');
    });

    test('keeps multi-line cue text together', () {
      final cues = parseWebVtt(
        'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nline one\nline two\n\n',
      );
      expect(cues.single.text, 'line one\nline two');
    });

    test('cue keys distinguish different cues and match identical ones', () {
      final a = parseWebVtt(realSegment);
      final b = parseWebVtt(realSegment);
      // Re-fetching an overlapping playlist window must not add duplicates.
      final deduped = {for (final c in [...a, ...b]) c.key: c};
      expect(deduped, hasLength(4));
    });
  });

  group('buildRebasedVtt', () {
    test('maps absolute cue times onto the player timeline', () {
      // mpv reported demuxer-start-time = 1786063572 for this stream.
      const timelineStart = 1786063050.0;
      final vtt = buildRebasedVtt(parseWebVtt(realSegment), timelineStart);

      expect(vtt, startsWith('WEBVTT'));
      // 1786063060 - 1786063050 == 10s in
      expect(vtt, contains('00:00:10.000 --> 00:00:12.000'));
      expect(vtt, contains('主要因為當地政府「開綠燈」'));
    });

    test('drops cues that ended before the timeline started', () {
      // Timeline starts after every cue in the sample.
      final vtt = buildRebasedVtt(parseWebVtt(realSegment), 1786064000.0);
      expect(vtt.trim(), 'WEBVTT');
    });

    test('orders cues by start time regardless of input order', () {
      final cues = [
        const VttCue(30, 31, 'third'),
        const VttCue(10, 11, 'first'),
        const VttCue(20, 21, 'second'),
      ];
      final vtt = buildRebasedVtt(cues, 0);
      expect(
        vtt.indexOf('first') < vtt.indexOf('second') &&
            vtt.indexOf('second') < vtt.indexOf('third'),
        isTrue,
      );
    });

    test('clamps a cue straddling the timeline start to zero', () {
      final vtt = buildRebasedVtt([const VttCue(5, 15, 'straddles')], 10);
      expect(vtt, contains('00:00:00.000 --> 00:00:05.000'));
    });
  });
}

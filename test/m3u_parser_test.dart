import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/datasources/parsers/m3u_parser.dart';
import 'package:clubtivi/data/models/channel.dart';

void main() {
  late M3uParser parser;

  setUp(() {
    parser = M3uParser();
  });

  group('M3uParser', () {
    test('parses basic M3U Plus playlist', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-id="ESPN.us" tvg-name="ESPN HD" tvg-logo="http://logo.com/espn.png" group-title="Sports",ESPN HD
http://example.com/live/espn
#EXTINF:-1 tvg-id="CNN.us" tvg-name="CNN" group-title="News",CNN International
http://example.com/live/cnn
''';

      final result = parser.parse(content, providerId: 'test-provider');

      expect(result.channelCount, 2);
      expect(result.hasErrors, false);

      final espn = result.channels[0];
      expect(espn.name, 'ESPN HD');
      expect(espn.tvgId, 'ESPN.us');
      expect(espn.tvgLogo, 'http://logo.com/espn.png');
      expect(espn.groupTitle, 'Sports');
      expect(espn.streamUrl, 'http://example.com/live/espn');

      final cnn = result.channels[1];
      expect(cnn.name, 'CNN International');
      expect(cnn.tvgId, 'CNN.us');
      expect(cnn.groupTitle, 'News');
    });

    test('parses display name when attribute values contain commas', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-name="MEATEATER" tvg-logo="https://ih1.redbubble.net/image.1003360281.8693/st,small,507x507-pad,600x600,f8f8f8.jpg" group-title="5",MEATEATER
http://89.187.179.148:826/anto.j/c9yJDcXyPe/118672
''';

      final result = parser.parse(content, providerId: 'test-provider');

      expect(result.channelCount, 1);
      expect(result.hasErrors, false);

      final channel = result.channels[0];
      expect(channel.name, 'MEATEATER');
      expect(channel.tvgName, 'MEATEATER');
      expect(
        channel.tvgLogo,
        'https://ih1.redbubble.net/image.1003360281.8693/st,small,507x507-pad,600x600,f8f8f8.jpg',
      );
      expect(channel.groupTitle, '5');
      expect(channel.streamUrl, 'http://89.187.179.148:826/anto.j/c9yJDcXyPe/118672');
    });

    test('preserves commas that belong to the display name itself', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-id="movie.1" group-title="VOD",Movie, The Sequel
http://example.com/movie/1.mp4
''';

      final result = parser.parse(content, providerId: 'test-provider');

      expect(result.channelCount, 1);
      expect(result.channels[0].name, 'Movie, The Sequel');
    });

    test('parses channel numbers from tvg-chno', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-id="ABC.us" tvg-chno="7",ABC
http://example.com/live/abc
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].channelNumber, 7);
    });

    test('detects VOD from group-title', () {
      const content = '''#EXTM3U
#EXTINF:-1 group-title="VOD | Action",The Matrix
http://example.com/movie/123.mp4
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].streamType, StreamType.vod);
    });

    test('detects VOD from Xtream URL pattern', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-name="Inception",Inception
http://example.com/movie/user/pass/456.mp4
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].streamType, StreamType.vod);
    });

    test('detects series from group-title', () {
      const content = '''#EXTM3U
#EXTINF:-1 group-title="Series | Drama",Breaking Bad S01E01
http://example.com/series/user/pass/789.mp4
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].streamType, StreamType.series);
    });

    test('handles missing #EXTM3U header gracefully', () {
      const content = '''#EXTINF:-1,Test Channel
http://example.com/test
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channelCount, 1);
      expect(result.hasErrors, true);
    });

    test('generates stable IDs from tvg-id', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-id="ESPN.us",ESPN
http://example.com/espn
''';

      final result = parser.parse(content, providerId: 'myProvider');
      expect(result.channels[0].id, 'myProvider_ESPN.us');
    });

    test('skips entries without a name', () {
      const content = '''#EXTM3U
#EXTINF:-1,
http://example.com/empty
#EXTINF:-1,Valid Channel
http://example.com/valid
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channelCount, 1);
      expect(result.channels[0].name, 'Valid Channel');
    });
  });

  group('M3uParser TXT (name,url + #genre#)', () {
    test('parses comma-separated channels with #genre# group headers', () {
      const content = '''央视频道,#genre#
CCTV1,http://223.247.25.207:1234/608807420\$安徽电信
CCTV1,http://101.6.130.52:1234/608807420\$北京教育
CCTV1,http://116.236.204.18:1234/608807420\$上海电信
CCTV1,http://182.61.15.163:80/608807420\$广东百度云
''';

      final result = parser.parse(content, providerId: 'p1');

      expect(result.hasErrors, false);
      expect(result.channelCount, 4);

      final first = result.channels[0];
      expect(first.name, 'CCTV1');
      expect(first.groupTitle, '央视频道');
      // The `$label` suffix is stripped from the stream URL.
      expect(first.streamUrl, 'http://223.247.25.207:1234/608807420');

      // Duplicate names get disambiguated IDs.
      final ids = result.channels.map((c) => c.id).toSet();
      expect(ids.length, 4);
    });

    test('supports multiple groups', () {
      const content = '''央视频道,#genre#
CCTV1,http://host/1
卫视频道,#genre#
湖南卫视,http://host/2
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channelCount, 2);
      expect(result.channels[0].groupTitle, '央视频道');
      expect(result.channels[1].name, '湖南卫视');
      expect(result.channels[1].groupTitle, '卫视频道');
    });

    test('handles channels before any group header', () {
      const content = '''CCTV1,http://host/1
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channelCount, 1);
      expect(result.channels[0].groupTitle, isNull);
      expect(result.channels[0].streamUrl, 'http://host/1');
    });

    test('keeps the URL when there is no \$ suffix', () {
      const content = '''群组,#genre#
Ch,http://host/stream.m3u8
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].streamUrl, 'http://host/stream.m3u8');
    });
  });
}

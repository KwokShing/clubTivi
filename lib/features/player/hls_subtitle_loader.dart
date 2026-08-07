import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;

/// One WebVTT cue, with its timestamps exactly as written in the source.
///
/// For the HLS renditions this deals with, [start] and [end] are absolute Unix
/// seconds rather than offsets into the video.
@immutable
class VttCue {
  final double start;
  final double end;
  final String text;

  const VttCue(this.start, this.end, this.text);

  /// Identity for de-duplication: live playlist windows overlap, so the same
  /// cue is fetched several times.
  String get key => '$start|$end|$text';

  @override
  String toString() => 'VttCue($start-$end, "$text")';
}

/// Parse a WebVTT document into cues, keeping timestamps as written.
///
/// Tolerates what these live renditions actually emit: CRLF endings, repeated
/// per-segment sequence numbers, unbounded hour fields (`496128:37:40.000`,
/// which is absolute Unix time), comma decimal separators and trailing cue
/// settings after the end timestamp.
List<VttCue> parseWebVtt(String body) {
  final cues = <VttCue>[];
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].contains('-->')) continue;
    final parts = lines[i].split('-->');
    if (parts.length < 2) continue;
    final start = parseVttTimestamp(parts[0]);
    // The end side may carry cue settings: "00:01.000 align:start position:50%".
    final endToken = parts[1].trim().split(RegExp(r'\s+')).first;
    final end = parseVttTimestamp(endToken);
    if (start == null || end == null) continue;

    final text = <String>[];
    for (var j = i + 1; j < lines.length; j++) {
      final line = lines[j].trim();
      if (line.isEmpty) break;
      if (line.contains('-->')) break;
      text.add(line);
    }
    if (text.isEmpty) continue;
    cues.add(VttCue(start, end, text.join('\n')));
  }
  return cues;
}

/// Parse `HH:MM:SS.mmm` or `MM:SS.mmm` into seconds. The hours field is
/// unbounded because these timestamps are absolute Unix time.
double? parseVttTimestamp(String raw) {
  final s = raw.trim();
  var m = RegExp(r'^(\d+):(\d{2}):(\d{2})[.,](\d{1,3})$').firstMatch(s);
  if (m != null) {
    return int.parse(m.group(1)!) * 3600 +
        int.parse(m.group(2)!) * 60 +
        int.parse(m.group(3)!) +
        _fractionToSeconds(m.group(4)!);
  }
  m = RegExp(r'^(\d{1,2}):(\d{2})[.,](\d{1,3})$').firstMatch(s);
  if (m != null) {
    return int.parse(m.group(1)!) * 60 +
        int.parse(m.group(2)!) +
        _fractionToSeconds(m.group(3)!);
  }
  return null;
}

double _fractionToSeconds(String frac) =>
    int.parse(frac) /
    (frac.length == 1 ? 10 : (frac.length == 2 ? 100 : 1000));

/// Format seconds as a WebVTT timestamp.
String formatVttTimestamp(double t) {
  if (t < 0) t = 0;
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final s = t % 60;
  return '${h.toString().padLeft(2, '0')}:'
      '${m.toString().padLeft(2, '0')}:'
      '${s.toStringAsFixed(3).padLeft(6, '0')}';
}

/// Rebase absolute-timed [cues] onto a player timeline starting at
/// [timelineStart] (mpv's `demuxer-start-time`) and render a WebVTT document.
///
/// Cues that end before the timeline begins are dropped.
String buildRebasedVtt(Iterable<VttCue> cues, double timelineStart) {
  final sorted = cues.toList()..sort((a, b) => a.start.compareTo(b.start));
  final sb = StringBuffer('WEBVTT\n\n');
  for (final c in sorted) {
    final end = c.end - timelineStart;
    if (end < 0) continue;
    sb.writeln('${formatVttTimestamp(c.start - timelineStart)} --> '
        '${formatVttTimestamp(end)}');
    sb.writeln(c.text);
    sb.writeln();
  }
  return sb.toString();
}

/// Loads HLS `EXT-X-MEDIA TYPE=SUBTITLES` renditions that libmpv cannot see.
///
/// The libmpv build media_kit bundles (mpv 0.36 / FFmpeg 6.0) does not create a
/// stream for a standalone WebVTT rendition — the track simply never appears,
/// so there is nothing for the player to select. Newer FFmpeg does expose it,
/// which is why the same stream shows subtitles in other players.
///
/// This fetches the rendition over HTTP instead, rebases its cues onto mpv's
/// timeline and hands the result to mpv as an in-memory external subtitle. Live
/// playlists only publish a short sliding window of segments, so the fetch and
/// injection repeat while playback continues.
///
/// ## Timeline mapping
///
/// These playlists carry no `X-TIMESTAMP-MAP`; cue timestamps are the absolute
/// wall clock, written as unbounded hours (`496128:37:40.000` is Unix time
/// 1786063060). mpv exposes the absolute start of its own timeline as
/// `demuxer-start-time`, so:
///
///     mpvTime = cueAbsoluteTime - demuxerStartTime
///
/// Wall clock cannot be used as the anchor: live latency is easily a minute,
/// which would place every cue far in the past.
class HlsSubtitleLoader {
  HlsSubtitleLoader(this._player);

  final Player _player;

  /// How often to re-fetch the rendition. Segments here run 8s and the window
  /// holds six of them, so this cannot miss one.
  static const _refreshInterval = Duration(seconds: 10);

  /// Drop cues that ended more than this far behind the playhead.
  static const _historyWindow = 60.0;

  Timer? _timer;
  String? _renditionUrl;
  double? _startTime;

  /// Cues collected so far, keyed by identity so the overlapping playlist
  /// windows don't produce duplicates.
  final Map<String, VttCue> _cues = {};

  /// mpv's numeric id for the track injected last, so it can be removed before
  /// the next one is added instead of piling up a track per refresh.
  ///
  /// Read from mpv's `sid` property, not from `state.track.subtitle.id`:
  /// [SubtitleTrack.data] uses the subtitle payload itself as the track id, so
  /// media_kit's view of it is the whole WebVTT document rather than something
  /// `sub-remove` would accept.
  String? _injectedSid;

  bool get isActive => _timer != null;

  /// Whether this loader is currently supplying the subtitle track.
  bool get hasCues => _cues.isNotEmpty;

  /// Look for a subtitle rendition that mpv did not expose, and start feeding
  /// it in if one is found.
  ///
  /// Does nothing when mpv already has a real subtitle track (normal embedded
  /// subtitles keep taking the native path) or when the playlist has no
  /// subtitle rendition. Returns true if the loader took over.
  /// Whether the injected track should be selected as soon as it exists.
  /// Mirrors the user's "show subtitles automatically" preference — adding a
  /// track always selects it in mpv, so when the preference is off the track is
  /// deselected again right after injection.
  bool _autoSelect = false;

  Future<bool> start(
    String masterUrl, {
    Map<String, String>? headers,
    bool autoSelect = false,
  }) async {
    stop();
    _autoSelect = autoSelect;

    // Only step in where mpv came up empty.
    final native = _player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .length;
    if (native > 0) return false;

    final rendition = await _findRendition(masterUrl, headers);
    if (rendition == null) return false;

    _renditionUrl = rendition;
    debugPrint('[HlsSubs] taking over rendition: $rendition');

    await _refresh(headers);
    if (_cues.isEmpty) {
      // Nothing to show — most likely a channel whose subtitle track is
      // present but idle. Keep polling; cues may start at any time.
      debugPrint('[HlsSubs] no cues yet, will keep polling');
    }
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh(headers));
    return true;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    final stale = _injectedSid;
    if (stale != null) _removeTrack(stale);
    _cues.clear();
    _renditionUrl = null;
    _startTime = null;
    _injectedSid = null;
  }

  /// Resolve the SUBTITLES rendition URI from a master playlist.
  Future<String?> _findRendition(
    String masterUrl,
    Map<String, String>? headers,
  ) async {
    try {
      final base = Uri.parse(masterUrl);
      final resp = await http
          .get(base, headers: headers)
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      for (final line in resp.body.split('\n')) {
        if (!line.startsWith('#EXT-X-MEDIA')) continue;
        if (!line.contains('TYPE=SUBTITLES')) continue;
        final m = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (m == null) continue;
        return base.resolve(m.group(1)!).toString();
      }
    } catch (e) {
      debugPrint('[HlsSubs] rendition lookup failed: $e');
    }
    return null;
  }

  Future<void> _refresh(Map<String, String>? headers) async {
    final rendition = _renditionUrl;
    if (rendition == null) return;
    try {
      final added = await _fetchCues(rendition, headers);
      if (added == 0 && _cues.isEmpty) return;
      await _inject();
    } catch (e) {
      debugPrint('[HlsSubs] refresh failed: $e');
    }
  }

  /// Fetch the rendition playlist and any segments not seen yet. Returns the
  /// number of new cues.
  Future<int> _fetchCues(
    String rendition,
    Map<String, String>? headers,
  ) async {
    final base = Uri.parse(rendition);
    final resp = await http
        .get(base, headers: headers)
        .timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) {
      debugPrint('[HlsSubs] rendition playlist ${resp.statusCode}');
      return 0;
    }

    final segments = resp.body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();

    debugPrint('[HlsSubs] rendition has ${segments.length} segments');
    var added = 0;
    for (final seg in segments) {
      final url = base.resolve(seg);
      try {
        final body = await http
            .get(url, headers: headers)
            .timeout(const Duration(seconds: 6));
        if (body.statusCode != 200) {
          debugPrint('[HlsSubs] segment ${body.statusCode}: $url');
          continue;
        }
        for (final cue in parseWebVtt(body.body)) {
          if (_cues.containsKey(cue.key)) continue;
          _cues[cue.key] = cue;
          added++;
        }
      } catch (e) {
        // A single missing segment is not worth aborting the refresh, but
        // silence here previously hid a total failure to fetch anything.
        debugPrint('[HlsSubs] segment fetch failed ($url): $e');
      }
    }
    return added;
  }

  /// Rebase the collected cues onto mpv's timeline and hand them over.
  Future<void> _inject() async {
    // demuxer-start-time is the absolute start of mpv's timeline and stays
    // fixed for the session, so it only needs reading once.
    _startTime ??= await _readStartTime();
    final start = _startTime;
    if (start == null) return;

    // Bound memory on a long-running live session.
    final position = _player.state.position.inMilliseconds / 1000.0;
    _cues.removeWhere((_, c) => c.end - start < position - _historyWindow);
    if (_cues.isEmpty) return;

    final vtt = buildRebasedVtt(_cues.values, start);

    // Adding a track always selects it in mpv, which would switch subtitles on
    // behind the user's back. Work out whether they should end up on, then
    // restore that state after the swap.
    final previous = _injectedSid;
    final shouldBeOn =
        previous == null ? _autoSelect : await _readSid() == previous;

    await _player.setSubtitleTrack(
      SubtitleTrack.data(vtt, title: 'HLS WebVTT'),
    );
    _injectedSid = await _readSid();

    if (previous != null && previous != _injectedSid) {
      await _removeTrack(previous);
    }
    if (!shouldBeOn) await _player.setSubtitleTrack(SubtitleTrack.no());
    debugPrint('[HlsSubs] injected ${_cues.length} cues '
        '(sid=$_injectedSid selected=$shouldBeOn)');
  }

  /// mpv's currently selected subtitle id (`"no"` when subtitles are off).
  Future<String?> _readSid() async {
    final np = _player.platform;
    if (np is! native_player.NativePlayer) return null;
    try {
      return await np.getProperty('sid');
    } catch (_) {
      return null;
    }
  }

  Future<double?> _readStartTime() async {
    final np = _player.platform;
    if (np is! native_player.NativePlayer) return null;
    try {
      return double.tryParse(await np.getProperty('demuxer-start-time'));
    } catch (e) {
      debugPrint('[HlsSubs] could not read demuxer-start-time: $e');
      return null;
    }
  }

  /// Drop a previously injected track so refreshes don't accumulate tracks.
  Future<void> _removeTrack(String sid) async {
    final np = _player.platform;
    if (np is! native_player.NativePlayer) return;
    try {
      await np.command(['sub-remove', sid]);
    } catch (_) {
      // Not fatal: a stale track is untidy but harmless.
    }
  }
}

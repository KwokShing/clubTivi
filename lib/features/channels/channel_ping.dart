import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Result of a reachability probe against a channel's stream host.
class _PingResult {
  const _PingResult.reachable(this.ms) : reachable = true;
  const _PingResult.unreachable() : ms = null, reachable = false;

  final int? ms;
  final bool reachable;
}

/// A minimal counting semaphore used to cap how many reachability probes run
/// at once. Without it, scrolling through a long list could open hundreds of
/// simultaneous connections and hammer both the machine and the servers.
class _PingSemaphore {
  _PingSemaphore(this.maxConcurrent);

  final int maxConcurrent;
  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else if (_active > 0) {
      _active--;
    }
  }
}

/// Probes whether a channel's stream can actually be reached by issuing a
/// streamed HTTP GET for just the first bytes and measuring the time to the
/// first response (TTFB). Unlike a bare TCP handshake this confirms the real
/// stream path exists, auth passed and the server is willing to serve data —
/// a 2xx/3xx response counts as reachable, anything else (4xx/5xx, timeout or
/// network error) counts as unreachable. Results are cached per URL for the
/// session, in-flight probes are de-duplicated, and a semaphore caps how many
/// run concurrently.
class _PingService {
  _PingService._();

  static const Duration timeout = Duration(seconds: 5);

  // Many IPTV servers reject unknown clients, so present a player-like agent.
  static const String _userAgent = 'VLC/3.0.20 LibVLC/3.0.20';

  static final http.Client _client = http.Client();
  // Probes are almost entirely idle network waits, so a higher ceiling is cheap
  // and keeps the rows currently on screen from queueing behind slow/dead hosts
  // that hold a slot for the full timeout. Enough to cover a screenful at once.
  static final _PingSemaphore _semaphore = _PingSemaphore(24);

  static final Map<String, _PingResult> _cache = <String, _PingResult>{};
  static final Map<String, Future<_PingResult>> _inFlight =
      <String, Future<_PingResult>>{};

  static _PingResult? cached(String url) => _cache[url];

  static Future<_PingResult> ping(String url) {
    final existing = _cache[url];
    if (existing != null) return Future<_PingResult>.value(existing);
    final inFlight = _inFlight[url];
    if (inFlight != null) return inFlight;

    final future = _runGuarded(url);
    _inFlight[url] = future;
    return future;
  }

  static Future<_PingResult> _runGuarded(String url) async {
    await _semaphore.acquire();
    try {
      final result = await _measure(url);
      _cache[url] = result;
      return result;
    } finally {
      _semaphore.release();
      _inFlight.remove(url);
    }
  }

  static Future<_PingResult> _measure(String url) async {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return const _PingResult.unreachable();
    }
    if (uri.host.isEmpty || !uri.hasScheme) {
      return const _PingResult.unreachable();
    }

    final request = http.Request('GET', uri)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers['Range'] = 'bytes=0-1'
      ..headers['User-Agent'] = _userAgent
      ..headers['Accept'] = '*/*';

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client.send(request).timeout(timeout);
      stopwatch.stop();
      // We only needed the headers (TTFB). Cancel the body so we never pull a
      // whole live stream down when the server ignores our Range request.
      unawaited(response.stream.listen(null).cancel());

      final code = response.statusCode;
      if (code >= 200 && code < 400) {
        return _PingResult.reachable(stopwatch.elapsedMilliseconds);
      }
      return const _PingResult.unreachable();
    } catch (_) {
      return const _PingResult.unreachable();
    }
  }
}

/// Shows a channel's reachability. Green "123 ms" text means the host answered;
/// a red dot means it timed out (>5s) or refused the connection. Like the logos
/// next to it, the probe only fires once scrolling settles on the row, so a
/// fast fling doesn't dial every host it flies past.
class ChannelPing extends StatefulWidget {
  const ChannelPing({super.key, required this.url, required this.active});

  final String url;
  final bool active;

  @override
  State<ChannelPing> createState() => _ChannelPingState();
}

class _ChannelPingState extends State<ChannelPing> {
  _PingResult? _result;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _result = _PingService.cached(widget.url);
    _maybePing();
  }

  @override
  void didUpdateWidget(ChannelPing oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tiles are recycled as the list scrolls, so the same state can be handed a
    // different channel. Reset to that channel's cached result and probe again.
    if (oldWidget.url != widget.url) {
      _result = _PingService.cached(widget.url);
      _requested = false;
    }
    _maybePing();
  }

  void _maybePing() {
    if (_result != null || _requested || !widget.active) return;
    _requested = true;
    final url = widget.url;
    _PingService.ping(url).then((result) {
      if (mounted && widget.url == url) {
        setState(() => _result = result);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result == null) {
      // Not measured yet (or currently probing): keep the slot empty.
      return const SizedBox(width: 8);
    }
    if (!result.reachable) {
      return Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Color(0xffe23c3c),
          shape: BoxShape.circle,
        ),
      );
    }
    return Text(
      '${result.ms} ms',
      style: const TextStyle(
        color: Color(0xff1faa59),
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
    );
  }
}

import '../../models/channel.dart';

/// Top-level entry point so M3U parsing can run in a background isolate via
/// `compute`, keeping the UI thread responsive for large playlists.
/// Takes (content, providerId) and returns the parsed result.
M3uResult parseM3uInBackground((String, String) args) {
  return M3uParser().parse(args.$1, providerId: args.$2);
}

/// Parses M3U and M3U Plus playlist formats.
///
/// Supports:
/// - Standard M3U (#EXTM3U / #EXTINF)
/// - M3U Plus extended attributes (tvg-id, tvg-name, tvg-logo, group-title, etc.)
/// - #EXTGRP: group directive
/// - Xtream Codes style attributes (tvg-chno, tvg-shift)
/// - Multiple URL formats (HTTP, HTTPS, RTMP, RTSP, UDP)
/// - EPG URL extraction from #EXTM3U url-tvg attribute
/// - Comma-separated "TXT" playlists where each line is `name,url` and group
///   headers look like `<group>,#genre#`
class M3uParser {
  /// Parse playlist content from a string.
  ///
  /// Automatically detects whether the content is a standard M3U/M3U Plus
  /// playlist or a comma-separated "TXT" playlist and dispatches accordingly.
  M3uResult parse(String content, {required String providerId}) {
    if (_isTxtGenreFormat(content)) {
      return _parseTxtGenre(content, providerId: providerId);
    }
    return _parseM3u(content, providerId: providerId);
  }

  /// Detect the comma-separated "TXT" playlist format.
  ///
  /// This format has no `#EXTM3U`/`#EXTINF` directives; instead each line is
  /// `name,url` and group headers are `<group>,#genre#`. We treat content as
  /// TXT when it contains no M3U directives but has at least one comma-separated
  /// line (a `#genre#` header or a `name,url` entry).
  bool _isTxtGenreFormat(String content) {
    final lines = content.split(RegExp(r'\r?\n'));
    var sawCommaLine = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      // Any real M3U directive means this is not the TXT format.
      if (line.startsWith('#EXTM3U') ||
          line.startsWith('#EXTINF') ||
          line.startsWith('#EXTGRP')) {
        return false;
      }
      if (line.startsWith('#')) continue;
      if (line.contains(',')) sawCommaLine = true;
    }
    return sawCommaLine;
  }

  /// Parse the comma-separated "TXT" playlist format.
  ///
  /// - `<group>,#genre#` sets the current group for subsequent channels.
  /// - `<name>,<url>` defines a channel. The URL may carry a `$label` suffix
  ///   (e.g. `http://host/id$安徽电信`); everything before the first `$` is used
  ///   as the stream URL.
  M3uResult _parseTxtGenre(String content, {required String providerId}) {
    final lines = content.split(RegExp(r'\r?\n'));
    final channels = <Channel>[];
    final errors = <String>[];
    final idCounts = <String, int>{};

    String? currentGroup;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) continue;

      final commaIndex = line.indexOf(',');
      if (commaIndex == -1) continue;

      final left = line.substring(0, commaIndex).trim();
      final right = line.substring(commaIndex + 1).trim();

      // Group header: `<group>,#genre#`
      if (right == '#genre#') {
        currentGroup = left.isEmpty ? null : left;
        continue;
      }

      final name = left;
      // Strip an optional `$label` suffix from the URL.
      final dollarIndex = right.indexOf(r'$');
      final url = dollarIndex == -1 ? right : right.substring(0, dollarIndex).trim();

      if (name.isEmpty || url.isEmpty) {
        errors.add('Line $i: empty name or url');
        continue;
      }

      final channel = _buildTxtChannel(
        name: name,
        url: url,
        group: currentGroup,
        providerId: providerId,
        idCounts: idCounts,
      );
      channels.add(channel);
    }

    return M3uResult(channels: channels, errors: errors);
  }

  Channel _buildTxtChannel({
    required String name,
    required String url,
    required String? group,
    required String providerId,
    required Map<String, int> idCounts,
  }) {
    final baseId = '${providerId}_${name}_${group ?? ''}';
    final count = (idCounts[baseId] ?? 0) + 1;
    idCounts[baseId] = count;
    final channelId = count == 1 ? baseId : '${baseId}_$count';

    return Channel(
      id: channelId,
      providerId: providerId,
      name: name,
      groupTitle: _emptyToNull(group),
      streamUrl: url,
      streamType: _inferStreamType(
        group != null ? {'group-title': group} : const {},
        url,
      ),
    );
  }

  /// Parse M3U content from a string.
  M3uResult _parseM3u(String content, {required String providerId}) {
    final lines = content.split(RegExp(r'\r?\n'));
    final channels = <Channel>[];
    final errors = <String>[];
    String? epgUrl;

    // Track how many times each base ID has been seen to disambiguate duplicates
    final idCounts = <String, int>{};

    String? currentExtInf;
    String? extGrp; // #EXTGRP: fallback group
    int order = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.isEmpty) continue;

      // Extract EPG URL from #EXTM3U header
      if (line.startsWith('#EXTM3U')) {
        epgUrl = _extractEpgUrl(line);
        continue;
      }

      // #EXTGRP: provides a fallback group for the next channel
      if (line.startsWith('#EXTGRP:')) {
        extGrp = line.substring('#EXTGRP:'.length).trim();
        continue;
      }

      if (line.startsWith('#EXTINF')) {
        currentExtInf = line;
        continue;
      }

      // Skip other directives
      if (line.startsWith('#')) continue;

      // Any non-# non-empty line is treated as a URL
      final url = line;
      if (url.isEmpty) continue;

      try {
        final channel = _parseEntry(
          currentExtInf,
          url,
          providerId,
          order,
          idCounts,
          extGrp,
        );
        channels.add(channel);
        order++;
      } catch (e) {
        errors.add('Line $i: $e');
      }

      // Reset per-channel state
      currentExtInf = null;
      extGrp = null;
    }

    return M3uResult(channels: channels, errors: errors, epgUrl: epgUrl);
  }

  /// Extract url-tvg or x-tvg-url from #EXTM3U header line.
  String? _extractEpgUrl(String headerLine) {
    final urlTvg = RegExp(r'url-tvg="([^"]+)"').firstMatch(headerLine);
    if (urlTvg != null) return urlTvg.group(1);
    final xTvg = RegExp(r'x-tvg-url="([^"]+)"').firstMatch(headerLine);
    if (xTvg != null) return xTvg.group(1);
    return null;
  }

  Channel _parseEntry(
    String? extInf,
    String url,
    String providerId,
    int order,
    Map<String, int> idCounts,
    String? extGrp,
  ) {
    final attrs = extInf != null
        ? _parseAttributes(extInf)
        : <String, String>{};
    final displayName = extInf != null ? _parseDisplayName(extInf) : '';

    // Name: prefer display name (after comma), then tvg-name, then URL as last resort
    final name = displayName.isNotEmpty
        ? displayName
        : (attrs['tvg-name'] ?? '').isNotEmpty
        ? attrs['tvg-name']!
        : url;

    // Group: prefer group-title attribute, then #EXTGRP directive, then "Ungrouped"
    final group = (attrs['group-title'] ?? '').isNotEmpty
        ? attrs['group-title']!
        : (extGrp ?? '').isNotEmpty
        ? extGrp!
        : null;

    // Generate a stable unique ID:
    // Use tvg-id if available, fallback to name + group
    // Append occurrence count for duplicates
    final tvgId = attrs['tvg-id'];
    String baseId;
    if (tvgId != null && tvgId.isNotEmpty) {
      baseId = '${providerId}_$tvgId';
    } else {
      baseId = '${providerId}_${name}_${group ?? ''}';
    }

    final count = (idCounts[baseId] ?? 0) + 1;
    idCounts[baseId] = count;
    final channelId = count == 1 ? baseId : '${baseId}_$count';

    // Parse channel number
    int? channelNumber;
    final chnoStr = attrs['tvg-chno'];
    if (chnoStr != null && chnoStr.isNotEmpty) {
      channelNumber = int.tryParse(chnoStr);
    }

    return Channel(
      id: channelId,
      providerId: providerId,
      name: name,
      tvgId: _emptyToNull(tvgId),
      tvgName: _emptyToNull(attrs['tvg-name']),
      tvgLogo: _emptyToNull(attrs['tvg-logo']),
      groupTitle: _emptyToNull(group),
      channelNumber: channelNumber,
      streamUrl: url,
      streamType: _inferStreamType(attrs, url),
    );
  }

  /// Parse M3U Plus extended attributes from an #EXTINF line.
  Map<String, String> _parseAttributes(String extInf) {
    final attrs = <String, String>{};
    // Match key="value" pairs (double quotes)
    final regex = RegExp(r'([\w-]+)="([^"]*)"');
    for (final match in regex.allMatches(extInf)) {
      attrs[match.group(1)!.toLowerCase()] = match.group(2)!;
    }
    // Also try single-quoted attributes
    final singleQuote = RegExp(r"([\w-]+)='([^']*)'");
    for (final match in singleQuote.allMatches(extInf)) {
      attrs.putIfAbsent(match.group(1)!.toLowerCase(), () => match.group(2)!);
    }
    return attrs;
  }

  /// Extract the display name from an #EXTINF line.
  ///
  /// The #EXTINF format is `#EXTINF:<duration> <attributes>,<display-name>`.
  /// The display name is everything after the *first comma that sits outside
  /// of any quoted attribute value*. Using the first unquoted comma (instead of
  /// `lastIndexOf(',')`) means attribute values that themselves contain commas
  /// — e.g. `tvg-logo="https://.../st,small,600x600,f8f8f8.jpg"` — no longer
  /// corrupt the parsed name. It also correctly preserves display names that
  /// legitimately contain commas.
  String _parseDisplayName(String extInf) {
    final commaIndex = _unquotedCommaIndex(extInf);
    if (commaIndex == -1 || commaIndex == extInf.length - 1) return '';
    return extInf.substring(commaIndex + 1).trim();
  }

  /// Find the index of the first comma in [line] that is not enclosed in either
  /// double or single quotes. Returns -1 if there is no such comma.
  int _unquotedCommaIndex(String line) {
    var inDouble = false;
    var inSingle = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (ch == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (ch == ',' && !inDouble && !inSingle) {
        return i;
      }
    }
    return -1;
  }

  StreamType _inferStreamType(Map<String, String> attrs, String url) {
    final groupTitle = (attrs['group-title'] ?? '').toLowerCase();
    if (groupTitle.contains('vod') || groupTitle.contains('movie')) {
      return StreamType.vod;
    }
    if (groupTitle.contains('series')) {
      return StreamType.series;
    }
    if (url.contains('/movie/')) return StreamType.vod;
    if (url.contains('/series/')) return StreamType.series;
    return StreamType.live;
  }

  String? _emptyToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}

/// Result of parsing an M3U playlist.
class M3uResult {
  final List<Channel> channels;
  final List<String> errors;
  final String? epgUrl;

  const M3uResult({
    required this.channels,
    this.errors = const [],
    this.epgUrl,
  });

  bool get hasErrors => errors.isNotEmpty;
  int get channelCount => channels.length;
}

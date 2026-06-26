import '../../models/channel.dart';

/// Parses M3U and M3U Plus playlist formats.
///
/// Supports:
/// - Standard M3U (#EXTM3U / #EXTINF)
/// - M3U Plus extended attributes (tvg-id, tvg-name, tvg-logo, group-title, etc.)
/// - #EXTGRP: group directive
/// - Xtream Codes style attributes (tvg-chno, tvg-shift)
/// - Multiple URL formats (HTTP, HTTPS, RTMP, RTSP, UDP)
/// - EPG URL extraction from #EXTM3U url-tvg attribute
class M3uParser {
  /// Parse M3U content from a string.
  M3uResult parse(String content, {required String providerId}) {
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

  /// Extract the display name (after the last comma in #EXTINF line).
  String _parseDisplayName(String extInf) {
    final commaIndex = extInf.lastIndexOf(',');
    if (commaIndex == -1 || commaIndex == extInf.length - 1) return '';
    return extInf.substring(commaIndex + 1).trim();
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

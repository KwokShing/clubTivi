/// Pure, stateless helpers for matching IPTV channels to EPG/XMLTV data.
///
/// These were extracted verbatim from `channels_screen.dart` to shrink that
/// file and make the matching rules independently testable. They hold no state
/// and depend only on their string inputs.
library;

/// Extract a broadcast call-sign sort key from a channel name.
///
/// Channels with call signs (W/K + 2-3 letters) sort first (returned
/// uppercase); others sort by cleaned name (lowercase) so they come after.
String callSignSortKey(String name) {
  // Strip provider prefixes like "US-P|", "US: ", "UK- ", "CA-", "MX-"
  var s = name.replaceAll(RegExp(r'^[A-Z]{2}[\s:-]*[A-Z]*\|'), '');
  s = s.replaceAll(
    RegExp(r'^(US|UK|CA|MX)[\s:-]+', caseSensitive: false),
    '',
  );
  // Strip bracketed tags [US], [SP], [H]
  s = s.replaceAll(RegExp(r'\[.*?\]'), '');
  // Strip quality tags
  s = s.replaceAll(
    RegExp(r'\b(HD|FHD|SHD|SD|4K|UHD)\b', caseSensitive: false),
    '',
  );
  // Strip common location names
  s = s.replaceAll(
    RegExp(
      r'\b(New York|Los Angeles|Chicago|Houston|Phoenix|Philadelphia|San Antonio|San Diego|Dallas|San Jose|Austin|Jacksonville|Fort Worth|Columbus|Charlotte|Indianapolis|San Francisco|Seattle|Denver|Washington|Nashville|Oklahoma City|El Paso|Boston|Portland|Las Vegas|Memphis|Louisville|Baltimore|Milwaukee|Albuquerque|Tucson|Fresno|Mesa|Sacramento|Atlanta|Kansas City|Colorado Springs|Omaha|Raleigh|Long Beach|Virginia Beach|Miami|Oakland|Minneapolis|Tampa|Tulsa|Arlington|New Orleans|Cleveland|Orlando|Cincinnati|Pittsburgh|Detroit|St\.? Louis)\b',
      caseSensitive: false,
    ),
    '',
  );
  s = s.trim();
  // Try to find a broadcast call sign: W or K followed by 2-3 letters
  final csMatch = RegExp(
    r'\b([WK][A-Z]{2,3})\b',
    caseSensitive: false,
  ).firstMatch(s);
  if (csMatch != null) {
    final cs = csMatch.group(1)!.toUpperCase();
    // Validate it looks like a real call sign (not a common word)
    if (cs.length >= 3 && cs.length <= 4) return cs;
  }
  // No call sign found — return cleaned name lowercase (sorts after uppercase)
  return s.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ').trim().toLowerCase();
}

String normalizeChannelName(String name) {
  return name
      .toLowerCase()
      .replaceAll(
        RegExp(r'\b(hd|fhd|shd|sd|4k|uhd)\b', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'(us-?[a-z]*\|?|uk-?[a-z]*\|?|ca-?[a-z]*\|?|mx-?[a-z]*\|?)'),
        '',
      )
      .replaceAll(RegExp(r'[\s|()[\]]+'), ' ')
      .trim();
}

/// Invisible / zero-width characters that can differ between how a playlist
/// is saved on one platform vs another (BOM, zero-width spaces, NBSP) and
/// silently break exact-string EPG id matching.
final RegExp _epgInvisibleChars = RegExp(
  r'[\u200B\u200C\u200D\u200E\u200F\uFEFF\u00A0]',
);

/// Canonical key for exact tvg-id / tvg-name ↔ XMLTV channel-id matching:
/// lowercased, invisible chars stripped, trimmed. Applied on BOTH sides so a
/// stray BOM/zero-width/NBSP (e.g. from a differently-saved playlist) can't
/// make an otherwise-identical id fail to match on one platform.
String epgIdKey(String s) =>
    s.toLowerCase().replaceAll(_epgInvisibleChars, '').trim();

/// Normalize a channel/EPG display name for fuzzy EPG matching.
/// Strips country tags, quality tags, provider prefixes, call signs in parens.
String normalizeForEpgMatch(String name) {
  return name
      .toLowerCase()
      .replaceAll(RegExp(r'\[.*?\]'), '') // [US], [SP], [H]
      .replaceAll(RegExp(r'\(.*?\)'), '') // (WABC), (S)
      .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd|us|uk|ca|mx)\b'), '')
      .replaceAll(RegExp(r'us-?[a-z]*\|'), '') // US-P| prefix
      .replaceAll(
        RegExp(r'[^\p{L}\p{N}]+', unicode: true),
        ' ',
      ) // keep all letters (incl. CJK) + digits
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
}

final RegExp _callSignInParens = RegExp(r'\(([WK][A-Z]{2,3})\)');
final RegExp _callSignInTvgId = RegExp(
  r'[.\-_]([wk][a-z]{2,3})(?:[.\-_]|$)',
  caseSensitive: false,
);
final RegExp _callSignWord = RegExp(r'\b([WK][A-Z]{2,3})\b');

/// Extract a broadcast call sign (3-4 uppercase letters starting with W or K)
/// from a channel name. Checks parenthesized call signs like (WABC) first,
/// then tvgId patterns, then words in the name.
String? extractCallSign(String name, String? tvgId) {
  // 1. Check parenthesized call sign: (WABC)
  final parenMatch = _callSignInParens.firstMatch(name);
  if (parenMatch != null) return parenMatch.group(1)!.toUpperCase();
  // 2. Check tvgId for embedded call sign: abcwabc.us, ABC.(WABC).New.York
  if (tvgId != null && tvgId.isNotEmpty) {
    final tvgMatch = _callSignInTvgId.firstMatch(tvgId);
    if (tvgMatch != null) return tvgMatch.group(1)!.toUpperCase();
    // Also try last segment before .us: e.g. "cbs2wcbs.us" → extract WCBS
    final dotParts = tvgId
        .replaceAll(RegExp(r'\.us$', caseSensitive: false), '')
        .split('.');
    for (final part in dotParts) {
      final m = RegExp(
        r'([wk][a-z]{2,3})$',
        caseSensitive: false,
      ).firstMatch(part);
      if (m != null) return m.group(1)!.toUpperCase();
    }
  }
  // 3. Check name for standalone call sign word
  final wordMatch = _callSignWord.firstMatch(
    name.replaceAll(RegExp(r'\(.*?\)'), ''),
  );
  if (wordMatch != null) return wordMatch.group(1)!.toUpperCase();
  return null;
}

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models.dart';

/// Fetches lyrics from LRCLib (https://lrclib.net) — a free, CC0 lyrics
/// database that returns both synced (LRC) and plain text lyrics.
class LyricsService {
  static const _base = 'https://lrclib.net/api';

  Future<LyricResult> fetch({
    required String trackName,
    required String artistName,
    String? albumName,
    Duration? duration,
  }) async {
    // 1) Try the /get endpoint (requires all four params — most accurate).
    if (albumName != null && duration != null) {
      final r = await _get(Uri.parse(
        '$_base/get'
        '?track_name=${Uri.encodeQueryComponent(trackName)}'
        '&artist_name=${Uri.encodeQueryComponent(artistName)}'
        '&album_name=${Uri.encodeQueryComponent(albumName)}'
        '&duration=${duration.inSeconds}',
      ));
      if (r != null) return r;
    }
    // 2) Fall back to /search (partial match).
    final searchResp = await http.get(Uri.parse(
      '$_base/search'
      '?track_name=${Uri.encodeQueryComponent(trackName)}'
      '&artist_name=${Uri.encodeQueryComponent(artistName)}',
    ));
    if (searchResp.statusCode != 200) return LyricResult.empty;
    final list = jsonDecode(searchResp.body) as List;
    if (list.isEmpty) return LyricResult.empty;
    final first = list.first as Map<String, dynamic>;
    return _parse(first);
  }

  Future<LyricResult?> _get(Uri url) async {
    final resp = await http.get(url);
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return _parse(json);
  }

  LyricResult _parse(Map<String, dynamic> json) {
    final synced = json['syncedLyrics'] as String?;
    final plain = json['plainLyrics'] as String? ?? '';
    if (synced != null && synced.isNotEmpty) {
      return LyricResult(
        synced: true,
        lines: _parseLrc(synced),
        plainText: plain,
      );
    }
    return LyricResult(synced: false, lines: const [], plainText: plain);
  }

  /// Parses an LRC-format string into timestamped lines.
  /// Only the timestamp/text structure is interpreted here; no lyric text
  /// is embedded in this source.
  static List<LyricLine> _parseLrc(String lrc) {
    final regex = RegExp(r'\[(\d+):(\d+)(?:\.(\d+))?\](.*)');
    final lines = <LyricLine>[];
    for (final raw in lrc.split('\n')) {
      final m = regex.firstMatch(raw);
      if (m == null) continue;
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      final fracStr = m.group(3);
      int millis = 0;
      if (fracStr != null) {
        final f = fracStr.padRight(3, '0').substring(0, 3);
        millis = int.parse(f);
      }
      final text = (m.group(4) ?? '').trim();
      lines.add(LyricLine(
        Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
        text,
      ));
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}

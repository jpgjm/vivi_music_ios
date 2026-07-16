import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models.dart';

/// Wraps `youtube_explode_dart` to search YouTube (Music) and resolve
/// audio-only stream URLs for playback.
class YoutubeService {
  final YoutubeExplode _yt = YoutubeExplode();

  /// Clients used for stream extraction.
  ///
  /// - `ios` returns **unciphered** stream URLs directly from the InnerTube
  ///   `/player` endpoint. No `player.js` download / signature decipher
  ///   step is required, which is dramatically faster (100–300 ms vs
  ///   several seconds) and far more reliable than the default web client
  ///   (whose URLs are also often throttled by YouTube).
  /// - `androidVr` is a fallback for the rare videos the iOS client cannot
  ///   resolve.
  static final _streamClients = <YoutubeApiClient>[
    YoutubeApiClient.ios,
    YoutubeApiClient.androidVr,
  ];

  Future<void> dispose() async {
    _yt.close();
  }

  /// Search YouTube for songs matching [query].
  Future<List<Song>> search(String query, {int limit = 25}) async {
    final result = await _yt.search.search(query);
    final list = <Song>[];
    for (final v in result.take(limit)) {
      list.add(Song(
        videoId: v.id.value,
        title: v.title,
        artist: v.author,
        duration: v.duration,
        thumbnailUrl: _bestThumb(v.thumbnails),
      ));
    }
    return list;
  }

  String _bestThumb(ThumbnailSet t) {
    return t.highResUrl.isNotEmpty
        ? t.highResUrl
        : t.mediumResUrl.isNotEmpty
            ? t.mediumResUrl
            : t.standardResUrl;
  }

  /// Resolve the best audio-only stream URL for a given [videoId].
  Future<String> getAudioStreamUrl(String videoId) async {
    final info = await getAudioStreamInfo(videoId);
    return info.url;
  }

  /// Resolve the best audio-only stream + its byte length. Used by the
  /// download service which needs the length so it can append the required
  /// `&range=0-<len>` query parameter to the URL.
  ///
  /// Also returns the InnerTube client name embedded in the resolved URL
  /// (the `c=` query parameter, e.g. "IOS" or "ANDROID_VR"), so the caller
  /// can send a matching User-Agent header — YouTube's CDN sometimes
  /// throttles or disconnects clients whose UA does not match.
  Future<AudioStreamInfo> getAudioStreamInfo(String videoId) async {
    final manifest = await _yt.videos.streamsClient.getManifest(
      videoId,
      ytClients: _streamClients,
    );
    // Prefer highest-bitrate audio-only stream. Fall back to muxed.
    final audioOnly = manifest.audioOnly.sortByBitrate();
    if (audioOnly.isNotEmpty) {
      final s = audioOnly.last;
      return AudioStreamInfo(
        url: s.url.toString(),
        contentLength: s.size.totalBytes,
      );
    }
    final muxed = manifest.muxed.sortByBitrate();
    if (muxed.isNotEmpty) {
      final s = muxed.last;
      return AudioStreamInfo(
        url: s.url.toString(),
        contentLength: s.size.totalBytes,
      );
    }
    throw Exception('No playable stream found for $videoId');
  }

  /// Fetch detailed video info for a [videoId].
  Future<Song> getVideoInfo(String videoId) async {
    final v = await _yt.videos.get(videoId);
    return Song(
      videoId: v.id.value,
      title: v.title,
      artist: v.author,
      duration: v.duration,
      thumbnailUrl: v.thumbnails.highResUrl,
    );
  }

  /// Related songs (used for autoplay/queue continuation).
  Future<List<Song>> getRelated(String videoId, {int limit = 15}) async {
    try {
      final video = await _yt.videos.get(videoId);
      final related = await _yt.videos.getRelatedVideos(video);
      if (related == null) return const [];
      return related.take(limit).map((v) {
        return Song(
          videoId: v.id.value,
          title: v.title,
          artist: v.author,
          duration: v.duration,
          thumbnailUrl: _bestThumb(v.thumbnails),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }
}

/// Result of [YoutubeService.getAudioStreamInfo].
class AudioStreamInfo {
  final String url;
  final int contentLength;
  const AudioStreamInfo({
    required this.url,
    required this.contentLength,
  });

  /// The InnerTube client that resolved this URL, parsed from `c=` in the
  /// query string. Empty if not present.
  String get clientName {
    final m = RegExp(r'[?&]c=([A-Z0-9_]+)').firstMatch(url);
    return m?.group(1) ?? '';
  }
}

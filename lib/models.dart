import 'package:audio_service/audio_service.dart';

/// A song from YouTube / YouTube Music.
class Song {
  final String videoId;
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String? thumbnailUrl;

  const Song({
    required this.videoId,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.thumbnailUrl,
  });

  String get youtubeUrl => "https://www.youtube.com/watch?v=$videoId";

  MediaItem toMediaItem({Uri? artUri, String? streamUrl}) {
    return MediaItem(
      id: videoId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      artUri: artUri ??
          (thumbnailUrl != null ? Uri.parse(thumbnailUrl!) : null),
      extras: {
        if (streamUrl != null) 'streamUrl': streamUrl,
        'youtubeUrl': youtubeUrl,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': duration?.inMilliseconds,
        'thumbnailUrl': thumbnailUrl,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        videoId: json['videoId'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String?,
        duration: json['durationMs'] != null
            ? Duration(milliseconds: json['durationMs'] as int)
            : null,
        thumbnailUrl: json['thumbnailUrl'] as String?,
      );
}

/// One line of a synced lyric (LRC).
class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

/// A full lyric result (synced or plain).
class LyricResult {
  final bool synced;
  final List<LyricLine> lines;
  final String plainText;
  const LyricResult({
    required this.synced,
    required this.lines,
    required this.plainText,
  });

  static const LyricResult empty =
      LyricResult(synced: false, lines: [], plainText: "");
}

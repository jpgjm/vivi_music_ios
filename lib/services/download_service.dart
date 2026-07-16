import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';

import '../models.dart';
import 'storage_service.dart';
import 'youtube_service.dart';

/// Downloads YouTube audio streams to local storage so songs can be played
/// offline. Files live at `<AppDocumentsDir>/downloads/<videoId>.m4a`.
///
/// Exposed as a singleton so the audio handler and UI share a single
/// source of truth for download state.
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  final YoutubeService _yt = YoutubeService();
  final StorageService _storage = StorageService();
  final Dio _dio = Dio(BaseOptions(
    // Long timeouts because YouTube CDN can be slow to first-byte.
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 5),
    // Follow redirects (googlevideo often redirects).
    followRedirects: true,
    maxRedirects: 5,
  ));

  /// videoId → progress in 0.0..1.0. Absent = not being downloaded.
  final BehaviorSubject<Map<String, double>> progress =
      BehaviorSubject.seeded(const {});

  /// Set of videoIds whose download is complete (persisted).
  final BehaviorSubject<Set<String>> downloadedIds =
      BehaviorSubject.seeded(const {});

  /// One CancelToken per in-flight download.
  final Map<String, CancelToken> _cancelTokens = {};

  bool _initialized = false;

  /// Loads the persisted downloaded-id set. Safe to call multiple times.
  Future<void> init() async {
    if (_initialized) return;
    final list = await _storage.loadDownloads();
    downloadedIds.add(list.map((s) => s.videoId).toSet());
    _initialized = true;
  }

  Future<Directory> _downloadDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> _pathFor(String videoId) async {
    final dir = await _downloadDir();
    return '${dir.path}/$videoId.m4a';
  }

  /// Returns the local path if the video is fully downloaded, else null.
  Future<String?> localPathIfDownloaded(String videoId) async {
    final path = await _pathFor(videoId);
    if (File(path).existsSync()) return path;
    return null;
  }

  bool isDownloaded(String videoId) =>
      downloadedIds.value.contains(videoId);

  bool isDownloading(String videoId) {
    final p = progress.value[videoId];
    return p != null && p < 1.0;
  }

  /// Resolve stream URL from YouTube, then save to disk.
  ///
  /// If already downloaded or in-flight, does nothing.
  Future<void> download(Song song) async {
    if (isDownloaded(song.videoId) || isDownloading(song.videoId)) return;

    final finalPath = await _pathFor(song.videoId);
    final tmpPath = '$finalPath.part';

    _updateProgress(song.videoId, 0.0);

    Object? lastError;
    try {
      // Try up to 2 times — YouTube URLs occasionally 403 / disconnect;
      // re-resolving the URL fixes it in most cases.
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await _downloadOnce(song, tmpPath);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          // Clean up partial file before retrying.
          final tmp = File(tmpPath);
          if (tmp.existsSync()) {
            try {
              await tmp.delete();
            } catch (_) {}
          }
          if (attempt == 0) {
            // Small back-off then retry with a freshly-resolved URL.
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      }

      if (lastError != null) throw lastError;

      // Publish the file and record it.
      await File(tmpPath).rename(finalPath);
      await _storage.addDownload(song);
      _addDownloadedId(song.videoId);
      _updateProgress(song.videoId, 1.0);

      Future.delayed(const Duration(seconds: 1), () {
        _removeProgress(song.videoId);
      });
    } catch (e) {
      // Final cleanup.
      final tmp = File(tmpPath);
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      _removeProgress(song.videoId);
      rethrow;
    } finally {
      _cancelTokens.remove(song.videoId);
    }
  }

  /// One resolve+download cycle. Throws on failure.
  Future<void> _downloadOnce(Song song, String tmpPath) async {
    // Re-resolve the URL each attempt — YouTube URLs expire, and the
    // safest way to recover from any prior 403 / disconnect is to fetch
    // a fresh URL.
    final info = await _yt.getAudioStreamInfo(song.videoId);

    // -------------------------------------------------------------------
    // CRITICAL: append `&range=0-<contentLength>` to the URL.
    // Without this, YouTube's CDN drops the connection mid-transfer for
    // non-browser clients. This is exactly what VIVI Music does on
    // Android (`DownloadUtil.kt`).
    // -------------------------------------------------------------------
    final rangedUrl = '${info.url}&range=0-${info.contentLength}';

    // Use a User-Agent that matches the InnerTube client which resolved
    // the URL. YouTube's CDN sometimes throttles / disconnects clients
    // whose UA does not match the `c=` in the URL.
    final ua = _userAgentFor(info.clientName);

    final cancelToken = CancelToken();
    _cancelTokens[song.videoId] = cancelToken;

    await _dio.download(
      rangedUrl,
      tmpPath,
      cancelToken: cancelToken,
      options: Options(
        headers: {
          'User-Agent': ua,
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
        },
        // Don't throw on non-2xx so we can inspect the status ourselves.
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
      onReceiveProgress: (received, total) {
        // Use content length from the API if the server didn't send one
        // (some CDN edges omit it when `range` is fully-specified).
        final t = total > 0 ? total : info.contentLength;
        if (t > 0) {
          _updateProgress(song.videoId, (received / t).clamp(0.0, 1.0));
        }
      },
    );
  }

  /// Pick a User-Agent that matches the client that resolved the URL.
  /// Strings taken verbatim from the original VIVI Music InnerTube
  /// client definitions.
  static String _userAgentFor(String clientName) {
    switch (clientName) {
      case 'IOS':
      case 'IOS_MUSIC':
        return 'com.google.ios.youtube/21.03.1 '
            '(iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)';
      case 'ANDROID_VR':
        return 'com.google.android.apps.youtube.vr.oculus/1.61.48 '
            '(Linux; U; Android 12; en_US; Oculus Quest 3; '
            'Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)';
      case 'ANDROID':
      case 'ANDROID_MUSIC':
        return 'com.google.android.youtube/21.03.38 '
            '(Linux; U; Android 14) gzip';
      default:
        // Safe default: IOS UA.
        return 'com.google.ios.youtube/21.03.1 '
            '(iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)';
    }
  }

  /// Cancel an in-flight download.
  Future<void> cancel(String videoId) async {
    _cancelTokens[videoId]?.cancel('cancelled by user');
    _cancelTokens.remove(videoId);
    _removeProgress(videoId);
  }

  /// Delete a completed download (removes file + record).
  Future<void> deleteDownload(String videoId) async {
    final path = await _pathFor(videoId);
    final f = File(path);
    if (f.existsSync()) {
      try {
        await f.delete();
      } catch (_) {}
    }
    await _storage.removeDownload(videoId);
    _removeDownloadedId(videoId);
  }

  /// Total size on disk of all downloads, in bytes.
  Future<int> totalDownloadedBytes() async {
    final dir = await _downloadDir();
    int total = 0;
    for (final e in dir.listSync()) {
      if (e is File) total += e.lengthSync();
    }
    return total;
  }

  // ---------- private state pushers ----------

  void _updateProgress(String videoId, double value) {
    final map = Map<String, double>.from(progress.value);
    map[videoId] = value;
    progress.add(map);
  }

  void _removeProgress(String videoId) {
    final map = Map<String, double>.from(progress.value);
    map.remove(videoId);
    progress.add(map);
  }

  void _addDownloadedId(String videoId) {
    final set = Set<String>.from(downloadedIds.value)..add(videoId);
    downloadedIds.add(set);
  }

  void _removeDownloadedId(String videoId) {
    final set = Set<String>.from(downloadedIds.value)..remove(videoId);
    downloadedIds.add(set);
  }
}

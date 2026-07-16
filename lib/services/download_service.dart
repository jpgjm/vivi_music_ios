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
  final Dio _dio = Dio();

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

    try {
      final streamUrl = await _yt.getAudioStreamUrl(song.videoId);
      final cancelToken = CancelToken();
      _cancelTokens[song.videoId] = cancelToken;

      await _dio.download(
        streamUrl,
        tmpPath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _updateProgress(song.videoId, received / total);
          }
        },
      );

      // Only publish the file (and record it) once download is complete.
      await File(tmpPath).rename(finalPath);
      await _storage.addDownload(song);
      _addDownloadedId(song.videoId);
      _updateProgress(song.videoId, 1.0);

      // Flash "done" briefly, then clear the progress marker.
      Future.delayed(const Duration(seconds: 1), () {
        _removeProgress(song.videoId);
      });
    } catch (e) {
      // Best-effort cleanup of the partial file.
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

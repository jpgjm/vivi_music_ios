import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';

/// Simple JSON-in-SharedPreferences store for favorites, history and
/// downloaded songs' metadata.
class StorageService {
  static const _kFavorites = 'favorites_v1';
  static const _kHistory = 'history_v1';
  static const _kDownloads = 'downloads_v1';
  static const int _historyLimit = 100;

  Future<List<Song>> loadFavorites() => _load(_kFavorites);
  Future<List<Song>> loadHistory() => _load(_kHistory);
  Future<List<Song>> loadDownloads() => _load(_kDownloads);

  Future<List<Song>> _load(String key) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _save(String key, List<Song> songs) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      key,
      jsonEncode(songs.map((s) => s.toJson()).toList()),
    );
  }

  // ---------- Favorites ----------

  Future<void> toggleFavorite(Song song) async {
    final list = await loadFavorites();
    final idx = list.indexWhere((s) => s.videoId == song.videoId);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, song);
    }
    await _save(_kFavorites, list);
  }

  Future<bool> isFavorite(String videoId) async {
    final list = await loadFavorites();
    return list.any((s) => s.videoId == videoId);
  }

  // ---------- History ----------

  Future<void> pushHistory(Song song) async {
    final list = await loadHistory();
    list.removeWhere((s) => s.videoId == song.videoId);
    list.insert(0, song);
    if (list.length > _historyLimit) {
      list.removeRange(_historyLimit, list.length);
    }
    await _save(_kHistory, list);
  }

  Future<void> clearHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kHistory);
  }

  // ---------- Downloads ----------

  /// Insert (or move to front) a song in the downloads list.
  Future<void> addDownload(Song song) async {
    final list = await loadDownloads();
    list.removeWhere((s) => s.videoId == song.videoId);
    list.insert(0, song);
    await _save(_kDownloads, list);
  }

  Future<void> removeDownload(String videoId) async {
    final list = await loadDownloads();
    list.removeWhere((s) => s.videoId == videoId);
    await _save(_kDownloads, list);
  }

  Future<bool> isDownloadedInStorage(String videoId) async {
    final list = await loadDownloads();
    return list.any((s) => s.videoId == videoId);
  }
}

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/audio_handler.dart';
import '../services/download_service.dart';
import '../services/storage_service.dart';
import '../widgets/song_tile.dart';

class LibraryPage extends StatefulWidget {
  final ViviAudioHandler handler;
  const LibraryPage({super.key, required this.handler});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

enum _LibraryTab { favorites, downloads }

class _LibraryPageState extends State<LibraryPage> {
  final _storage = StorageService();
  List<Song> _favorites = [];
  List<Song> _downloads = [];
  _LibraryTab _tab = _LibraryTab.favorites;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.handler.currentSong.listen((_) => _reload());
    // React to download / delete events too so the list refreshes.
    DownloadService.instance.downloadedIds.listen((_) => _reload());
  }

  Future<void> _reload() async {
    final f = await _storage.loadFavorites();
    final d = await _storage.loadDownloads();
    if (mounted) {
      setState(() {
        _favorites = f;
        _downloads = d;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Segmented control at the top.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SegmentedButton<_LibraryTab>(
            segments: const [
              ButtonSegment(
                value: _LibraryTab.favorites,
                label: Text('Favorites'),
                icon: Icon(Icons.favorite_rounded),
              ),
              ButtonSegment(
                value: _LibraryTab.downloads,
                label: Text('Downloads'),
                icon: Icon(Icons.cloud_done_rounded),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (sel) =>
                setState(() => _tab = sel.first),
          ),
        ),
        Expanded(
          child: _tab == _LibraryTab.favorites
              ? _buildFavorites(context)
              : _buildDownloads(context),
        ),
      ],
    );
  }

  // ---------- Favorites tab ----------

  Widget _buildFavorites(BuildContext context) {
    if (_favorites.isEmpty) {
      return _EmptyState(
        icon: Icons.favorite_border_rounded,
        title: 'No favorites yet',
        subtitle: 'Tap the heart on any song to save it here.',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 120),
        itemCount: _favorites.length,
        itemBuilder: (context, i) {
          final s = _favorites[i];
          return SongTile(
            song: s,
            onTap: () => widget.handler.playSong(s, queue: _favorites),
            trailing: IconButton(
              icon: const Icon(Icons.favorite),
              color: Theme.of(context).colorScheme.primary,
              onPressed: () async {
                await _storage.toggleFavorite(s);
                _reload();
              },
            ),
          );
        },
      ),
    );
  }

  // ---------- Downloads tab ----------

  Widget _buildDownloads(BuildContext context) {
    if (_downloads.isEmpty) {
      return _EmptyState(
        icon: Icons.cloud_download_outlined,
        title: 'No downloads yet',
        subtitle:
            'Open a song and tap the cloud icon to save it for offline playback.',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 120),
        itemCount: _downloads.length,
        itemBuilder: (context, i) {
          final s = _downloads[i];
          return SongTile(
            song: s,
            onTap: () => widget.handler.playSong(s, queue: _downloads),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _confirmDelete(context, s),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Song song) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete download?'),
        content: Text('Remove "${song.title}" from downloads.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await DownloadService.instance.deleteDownload(song.videoId);
      _reload();
    }
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: onSurface.withOpacity(0.4)),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: onSurface.withOpacity(0.55)),
            ),
          ],
        ),
      ),
    );
  }
}

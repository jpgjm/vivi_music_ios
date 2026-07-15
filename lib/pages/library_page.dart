import 'package:flutter/material.dart';

import '../models.dart';
import '../services/audio_handler.dart';
import '../services/storage_service.dart';
import '../widgets/song_tile.dart';

class LibraryPage extends StatefulWidget {
  final ViviAudioHandler handler;
  const LibraryPage({super.key, required this.handler});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _storage = StorageService();
  List<Song> _favorites = [];

  @override
  void initState() {
    super.initState();
    _reload();
    widget.handler.currentSong.listen((_) => _reload());
  }

  Future<void> _reload() async {
    final f = await _storage.loadFavorites();
    if (mounted) setState(() => _favorites = f);
  }

  @override
  Widget build(BuildContext context) {
    if (_favorites.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.favorite_border_rounded,
                size: 64,
                color:
                    Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
              ),
              const SizedBox(height: 16),
              const Text(
                'No favorites yet',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap the heart on any song to save it here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.55),
                ),
              ),
            ],
          ),
        ),
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
}

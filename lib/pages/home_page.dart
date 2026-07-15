import 'package:flutter/material.dart';

import '../models.dart';
import '../services/audio_handler.dart';
import '../services/storage_service.dart';
import '../widgets/song_tile.dart';

class HomePage extends StatefulWidget {
  final ViviAudioHandler handler;
  const HomePage({super.key, required this.handler});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _storage = StorageService();
  List<Song> _recent = [];
  List<Song> _favorites = [];

  @override
  void initState() {
    super.initState();
    _reload();
    widget.handler.currentSong.listen((_) => _reload());
  }

  Future<void> _reload() async {
    final h = await _storage.loadHistory();
    final f = await _storage.loadFavorites();
    if (mounted) {
      setState(() {
        _recent = h;
        _favorites = f;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 120),
        children: [
          _SectionHeader(
            title: 'Recently played',
            action: _recent.isEmpty
                ? null
                : TextButton(
                    onPressed: () async {
                      await _storage.clearHistory();
                      _reload();
                    },
                    child: const Text('Clear'),
                  ),
          ),
          if (_recent.isEmpty)
            const _EmptyHint(text: 'Songs you play will appear here.'),
          for (final s in _recent.take(20))
            SongTile(
              song: s,
              onTap: () => widget.handler.playSong(s, queue: _recent),
            ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Favorites'),
          if (_favorites.isEmpty)
            const _EmptyHint(text: 'Tap the heart to save a song.'),
          for (final s in _favorites.take(20))
            SongTile(
              song: s,
              onTap: () => widget.handler.playSong(s, queue: _favorites),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const _SectionHeader({required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
        ),
      ),
    );
  }
}

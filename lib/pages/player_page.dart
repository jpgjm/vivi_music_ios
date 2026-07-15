import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/audio_handler.dart';
import '../services/lyrics_service.dart';
import '../services/storage_service.dart';
import '../widgets/lyrics_view.dart';

class PlayerPage extends StatefulWidget {
  final ViviAudioHandler handler;
  const PlayerPage({super.key, required this.handler});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final LyricsService _lyricsSvc = LyricsService();
  final StorageService _storage = StorageService();
  LyricResult _lyric = LyricResult.empty;
  bool _showLyrics = false;
  bool _favorite = false;
  String? _lastLoadedVideoId;

  @override
  void initState() {
    super.initState();
    widget.handler.currentSong.listen(_onSongChanged);
    final s = widget.handler.currentSong.valueOrNull;
    if (s != null) _onSongChanged(s);
  }

  Future<void> _onSongChanged(Song? song) async {
    if (song == null) return;
    if (song.videoId == _lastLoadedVideoId) return;
    _lastLoadedVideoId = song.videoId;
    final fav = await _storage.isFavorite(song.videoId);
    if (mounted) setState(() => _favorite = fav);
    try {
      final result = await _lyricsSvc.fetch(
        trackName: song.title,
        artistName: song.artist,
        duration: song.duration,
      );
      if (mounted && song.videoId == _lastLoadedVideoId) {
        setState(() => _lyric = result);
      }
    } catch (_) {
      if (mounted) setState(() => _lyric = LyricResult.empty);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _showLyrics
                  ? Icons.album_rounded
                  : Icons.lyrics_rounded,
            ),
            onPressed: () => setState(() => _showLyrics = !_showLyrics),
          ),
        ],
      ),
      body: StreamBuilder<MediaItem?>(
        stream: widget.handler.mediaItem,
        builder: (context, snap) {
          final item = snap.data;
          if (item == null) {
            return const Center(child: Text('Nothing is playing'));
          }
          return Column(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _showLyrics
                      ? LyricsView(
                          key: const ValueKey('lyrics'),
                          lyric: _lyric,
                          positionStream: widget.handler.positionStream,
                        )
                      : _Artwork(
                          key: const ValueKey('art'),
                          artUri: item.artUri,
                        ),
                ),
              ),
              _MetaAndControls(
                title: item.title,
                artist: item.artist ?? '',
                favorite: _favorite,
                onFavorite: () async {
                  final song = widget.handler.currentSong.valueOrNull;
                  if (song == null) return;
                  await _storage.toggleFavorite(song);
                  final fav = await _storage.isFavorite(song.videoId);
                  if (mounted) setState(() => _favorite = fav);
                },
                handler: widget.handler,
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  final Uri? artUri;
  const _Artwork({super.key, required this.artUri});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: artUri != null
                ? CachedNetworkImage(
                    imageUrl: artUri.toString(),
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      child: const Icon(Icons.music_note_rounded, size: 96),
                    ),
                  )
                : Container(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: const Icon(Icons.music_note_rounded, size: 96),
                  ),
          ),
        ),
      ),
    );
  }
}

class _MetaAndControls extends StatelessWidget {
  final String title;
  final String artist;
  final bool favorite;
  final VoidCallback onFavorite;
  final ViviAudioHandler handler;

  const _MetaAndControls({
    required this.title,
    required this.artist,
    required this.favorite,
    required this.onFavorite,
    required this.handler,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      artist,
                      style: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                iconSize: 28,
                icon: Icon(
                  favorite ? Icons.favorite : Icons.favorite_border,
                  color: favorite
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: onFavorite,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _ProgressBar(handler: handler),
          const SizedBox(height: 8),
          StreamBuilder<PlaybackState>(
            stream: handler.playbackState,
            builder: (context, s) {
              final playing = s.data?.playing ?? false;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    iconSize: 42,
                    icon: const Icon(Icons.skip_previous_rounded),
                    onPressed: handler.skipToPrevious,
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      iconSize: 56,
                      color: Theme.of(context).colorScheme.onPrimary,
                      icon: Icon(playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded),
                      onPressed: () =>
                          playing ? handler.pause() : handler.play(),
                    ),
                  ),
                  IconButton(
                    iconSize: 42,
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: handler.skipToNext,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final ViviAudioHandler handler;
  const _ProgressBar({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: handler.positionStream,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        return StreamBuilder<Duration?>(
          stream: handler.durationStream,
          builder: (context, durSnap) {
            final dur = durSnap.data ?? Duration.zero;
            final max = dur.inMilliseconds > 0
                ? dur.inMilliseconds.toDouble()
                : 1.0;
            final value = pos.inMilliseconds.clamp(0, max.toInt()).toDouble();
            return Column(
              children: [
                Slider(
                  min: 0,
                  max: max,
                  value: value,
                  onChanged: (v) =>
                      handler.seek(Duration(milliseconds: v.toInt())),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos)),
                      Text(_fmt(dur)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

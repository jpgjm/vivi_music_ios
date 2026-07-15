import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/audio_handler.dart';
import '../pages/player_page.dart';

class MiniPlayer extends StatelessWidget {
  final ViviAudioHandler handler;
  const MiniPlayer({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return const SizedBox.shrink();
        return SafeArea(
          top: false,
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PlayerPage(handler: handler),
            )),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: item.artUri != null
                        ? CachedNetworkImage(
                            imageUrl: item.artUri.toString(),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                const _Placeholder(),
                          )
                        : const _Placeholder(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        if (item.artist != null)
                          Text(
                            item.artist!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.6),
                            ),
                          ),
                      ],
                    ),
                  ),
                  StreamBuilder<PlaybackState>(
                    stream: handler.playbackState,
                    builder: (context, s) {
                      final playing = s.data?.playing ?? false;
                      return IconButton(
                        iconSize: 32,
                        icon: Icon(playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                        onPressed: () =>
                            playing ? handler.pause() : handler.play(),
                      );
                    },
                  ),
                  IconButton(
                    iconSize: 28,
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: handler.skipToNext,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: const Icon(Icons.music_note_rounded),
    );
  }
}

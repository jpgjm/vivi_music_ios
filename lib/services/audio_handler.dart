import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../models.dart';
import 'youtube_service.dart';
import 'storage_service.dart';

/// Sets up the background audio service. Call once at app startup.
Future<ViviAudioHandler> initAudioService() async {
  final handler = await AudioService.init(
    builder: () => ViviAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.vivi.music.channel.audio',
      androidNotificationChannelName: 'VIVI Music playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  return handler;
}

/// Central audio handler: owns a [_player] (just_audio), a queue of [Song]s
/// and exposes standard media controls (play/pause/next/prev/seek). Resolves
/// YouTube stream URLs lazily on demand.
class ViviAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final YoutubeService _yt = YoutubeService();
  final StorageService _storage = StorageService();

  final List<Song> _songs = [];
  int _index = -1;

  /// Broadcasts the current [Song] (null when idle).
  final BehaviorSubject<Song?> currentSong = BehaviorSubject.seeded(null);

  ViviAudioHandler() {
    _player.playbackEventStream.listen(_broadcastState);
    _player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        await _autoAdvance();
      }
    });
  }

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  AudioPlayer get rawPlayer => _player;

  // ---------- Queue management ----------

  Future<void> playSong(Song song, {List<Song>? queue}) async {
    _songs
      ..clear()
      ..addAll(queue ?? [song]);
    _index = _songs.indexWhere((s) => s.videoId == song.videoId);
    if (_index < 0) {
      _songs.insert(0, song);
      _index = 0;
    }
    await _loadCurrent();
    await play();
    await _storage.pushHistory(song);
  }

  Future<void> setQueueAndPlay(List<Song> queue, int startIndex) async {
    _songs
      ..clear()
      ..addAll(queue);
    _index = startIndex.clamp(0, _songs.length - 1);
    await _loadCurrent();
    await play();
    if (_songs.isNotEmpty) {
      await _storage.pushHistory(_songs[_index]);
    }
  }

  Future<void> _loadCurrent() async {
    if (_index < 0 || _index >= _songs.length) return;
    final song = _songs[_index];
    currentSong.add(song);
    try {
      final streamUrl = await _yt.getAudioStreamUrl(song.videoId);
      final item = song.toMediaItem(streamUrl: streamUrl);
      mediaItem.add(item);
      queue.add(_songs.map((s) => s.toMediaItem()).toList());
      await _player.setUrl(streamUrl);
    } catch (e) {
      // Skip forward on failure so playback isn't stuck.
      await _autoAdvance();
    }
  }

  Future<void> _autoAdvance() async {
    if (_index + 1 < _songs.length) {
      _index++;
      await _loadCurrent();
      await play();
    } else {
      await stop();
    }
  }

  // ---------- Standard AudioHandler API ----------

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    await _player.stop();
    currentSong.add(null);
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_index + 1 < _songs.length) {
      _index++;
      await _loadCurrent();
      await play();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    // If more than 5s in, restart current song; otherwise go to previous.
    if (_player.position > const Duration(seconds: 5)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_index > 0) {
      _index--;
      await _loadCurrent();
      await play();
    } else {
      await _player.seek(Duration.zero);
    }
  }

  @override
  Future<void> skipToQueueItem(int i) async {
    if (i < 0 || i >= _songs.length) return;
    _index = i;
    await _loadCurrent();
    await play();
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _index >= 0 ? _index : null,
    ));
  }

  Future<void> dispose() async {
    await _player.dispose();
    await _yt.dispose();
    await currentSong.close();
  }
}

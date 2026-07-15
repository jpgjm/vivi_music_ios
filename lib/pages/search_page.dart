import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/audio_handler.dart';
import '../services/youtube_service.dart';
import '../widgets/song_tile.dart';

class SearchPage extends StatefulWidget {
  final ViviAudioHandler handler;
  const SearchPage({super.key, required this.handler});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _youtube = YoutubeService();
  List<Song> _results = [];
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    _youtube.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _run(q));
  }

  Future<void> _run(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _youtube.search(query);
      if (!mounted) return;
      setState(() {
        _results = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: TextField(
            controller: _controller,
            autofocus: false,
            onChanged: _onChanged,
            onSubmitted: _run,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search songs, artists, albums…',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Error: $_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Search for anything on YouTube.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final s = _results[i];
        return SongTile(
          song: s,
          onTap: () => widget.handler.playSong(s, queue: _results),
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import '../models.dart';

/// Displays synced lyrics with auto-scroll to the active line, or plain
/// lyrics when synced timings are unavailable.
class LyricsView extends StatefulWidget {
  final LyricResult lyric;
  final Stream<Duration> positionStream;

  const LyricsView({
    super.key,
    required this.lyric,
    required this.positionStream,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _controller = ScrollController();
  int _activeIndex = -1;
  static const double _lineHeight = 44;

  @override
  void initState() {
    super.initState();
    widget.positionStream.listen(_onPosition);
  }

  void _onPosition(Duration pos) {
    if (!widget.lyric.synced) return;
    final lines = widget.lyric.lines;
    int newIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= pos) {
        newIndex = i;
      } else {
        break;
      }
    }
    if (newIndex != _activeIndex && mounted) {
      setState(() => _activeIndex = newIndex);
      if (_controller.hasClients && newIndex >= 0) {
        final target = (newIndex * _lineHeight)
            - (MediaQuery.of(context).size.height / 3);
        _controller.animateTo(
          target.clamp(0.0, _controller.position.maxScrollExtent),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lyric.lines.isEmpty && widget.lyric.plainText.isEmpty) {
      return const Center(
        child: Text(
          'No lyrics found',
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
      );
    }
    if (!widget.lyric.synced) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Text(
          widget.lyric.plainText,
          style: const TextStyle(fontSize: 17, height: 1.6),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      controller: _controller,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      itemCount: widget.lyric.lines.length,
      itemBuilder: (context, i) {
        final active = i == _activeIndex;
        return SizedBox(
          height: _lineHeight,
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            style: TextStyle(
              fontSize: active ? 20 : 16,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.55),
              height: 1.4,
            ),
            child: Text(
              widget.lyric.lines[i].text,
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }
}

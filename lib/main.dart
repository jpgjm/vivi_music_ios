import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'pages/library_page.dart';
import 'pages/search_page.dart';
import 'services/audio_handler.dart';
import 'services/download_service.dart';
import 'theme.dart';
import 'widgets/mini_player.dart';

late ViviAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the persisted set of already-downloaded videoIds so the audio
  // handler can prefer local files on startup.
  await DownloadService.instance.init();
  audioHandler = await initAudioService();
  runApp(const ViviMusicApp());
}

class ViviMusicApp extends StatelessWidget {
  const ViviMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VIVI Music',
      debugShowCheckedModeBanner: false,
      theme: ViviTheme.light(),
      darkTheme: ViviTheme.dark(),
      themeMode: ThemeMode.system,
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(handler: audioHandler),
      SearchPage(handler: audioHandler),
      LibraryPage(handler: audioHandler),
    ];
    final titles = ['Home', 'Search', 'Library'];
    return Scaffold(
      appBar: AppBar(title: Text(titles[_index])),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayer(handler: audioHandler),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search_rounded),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music_rounded),
                label: 'Library',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

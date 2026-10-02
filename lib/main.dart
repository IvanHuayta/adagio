import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicialización de notificaciones multimedia nativas y pantalla de bloqueo
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.adagio.music.channel.audio',
    androidNotificationChannelName: 'Adagio Reproducción',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: false,
  );

  runApp(const AdagioApp());
}

// =============================================================================
// GESTIÓN DE SKINS Y TEMAS
// =============================================================================
enum AppSkin { azulCyber, carmesiFuego, rosaNeon, retroVinyl, claroSuave }

class SkinTheme {
  final String name;
  final Color primary;
  final Color background;
  final Color cardColor;
  final Color accent;

  SkinTheme({
    required this.name,
    required this.primary,
    required this.background,
    required this.cardColor,
    required this.accent,
  });

  static Map<AppSkin, SkinTheme> themes = {
    AppSkin.azulCyber: SkinTheme(
      name: 'Azul Ciberpunk',
      primary: const Color(0xFF00E5FF),
      background: const Color(0xFF0F172A),
      cardColor: const Color(0xFF1E293B),
      accent: const Color(0xFFFF007F),
    ),
    AppSkin.carmesiFuego: SkinTheme(
      name: 'Rojo Carmesí',
      primary: const Color(0xFFEF4444),
      background: const Color(0xFF18181B),
      cardColor: const Color(0xFF27272A),
      accent: const Color(0xFFF97316),
    ),
    AppSkin.rosaNeon: SkinTheme(
      name: 'Rosado Neón',
      primary: const Color(0xFFEC4899),
      background: const Color(0xFF1F1123),
      cardColor: const Color(0xFF331D38),
      accent: const Color(0xFFA855F7),
    ),
    AppSkin.retroVinyl: SkinTheme(
      name: 'Retro Madera',
      primary: const Color(0xFFD97706),
      background: const Color(0xFF1C1917),
      cardColor: const Color(0xFF292524),
      accent: const Color(0xFFF59E0B),
    ),
    AppSkin.claroSuave: SkinTheme(
      name: 'Modo Claro',
      primary: const Color(0xFF6366F1),
      background: const Color(0xFFF8FAFC),
      cardColor: const Color(0xFFE2E8F0),
      accent: const Color(0xFF4F46E5),
    ),
  };
}

class AdagioApp extends StatefulWidget {
  const AdagioApp({super.key});

  @override
  State<AdagioApp> createState() => _AdagioAppState();
}

class _AdagioAppState extends State<AdagioApp> {
  AppSkin _currentSkin = AppSkin.azulCyber;

  void _changeSkin(AppSkin skin) {
    setState(() => _currentSkin = skin);
  }

  @override
  Widget build(BuildContext context) {
    final theme = SkinTheme.themes[_currentSkin]!;

    return MaterialApp(
      title: 'Adagio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: _currentSkin == AppSkin.claroSuave
            ? Brightness.light
            : Brightness.dark,
        scaffoldBackgroundColor: theme.background,
        primaryColor: theme.primary,
        colorScheme: ColorScheme.fromSeed(
          seedColor: theme.primary,
          brightness: _currentSkin == AppSkin.claroSuave
              ? Brightness.light
              : Brightness.dark,
        ),
      ),
      home: MainMusicScreen(
        currentSkin: _currentSkin,
        onSkinChanged: _changeSkin,
      ),
    );
  }
}

// =============================================================================
// PANTALLA PRINCIPAL CON NAVEGACIÓN Y REPRODUCTOR
// =============================================================================
class MainMusicScreen extends StatefulWidget {
  final AppSkin currentSkin;
  final ValueChanged<AppSkin> onSkinChanged;

  const MainMusicScreen({
    super.key,
    required this.currentSkin,
    required this.onSkinChanged,
  });

  @override
  State<MainMusicScreen> createState() => _MainMusicScreenState();
}

class _MainMusicScreenState extends State<MainMusicScreen>
    with TickerProviderStateMixin {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final OnAudioQuery _audioQuery = OnAudioQuery();

  List<SongModel> _songs = [];
  Set<int> _favoriteSongIds = {};
  final Map<int, int> _playCounts = {};

  bool _isLoading = true;
  bool _hasPermission = false;
  int _currentIndex = -1;

  bool _showPlaylist = false;
  int _selectedTab = 0;
  bool _isShuffle = false;
  bool _isDjMix = false;
  bool _isTransitioning = false;
  LoopMode _loopMode = LoopMode.off;

  late AnimationController _rotationController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);

    _loadUserData();
    _requestPermissionAndScan();

    _audioPlayer.playerStateStream.listen((state) {
      if (state.playing) {
        _rotationController.repeat();
        if (!_waveController.isAnimating) _waveController.repeat(reverse: true);
      } else {
        _rotationController.stop();
        _waveController.stop();
        _saveLastPlaybackState();
      }

      if (state.processingState == ProcessingState.completed) {
        _playNext();
      }
    });

    _audioPlayer.positionStream.listen((position) {
      if (_isDjMix && _audioPlayer.playing && !_isTransitioning) {
        final duration = _audioPlayer.duration ?? Duration.zero;
        if (duration.inSeconds > 50) {
          if (duration.inSeconds - position.inSeconds <= 20) {
            _triggerDjMixTransition();
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _saveLastPlaybackState();
    _audioPlayer.dispose();
    _rotationController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  Future<void> _saveLastPlaybackState() async {
    if (_currentIndex < 0 || _currentIndex >= _songs.length) return;
    final prefs = await SharedPreferences.getInstance();
    final currentSong = _songs[_currentIndex];
    final positionMs = _audioPlayer.position.inMilliseconds;

    await prefs.setInt('adagio_last_song_id', currentSong.id);
    await prefs.setInt('adagio_last_position_ms', positionMs);
  }

  Future<void> _restoreLastPlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSongId = prefs.getInt('adagio_last_song_id');
    final lastPositionMs = prefs.getInt('adagio_last_position_ms') ?? 0;

    if (lastSongId != null && _songs.isNotEmpty) {
      int index = _songs.indexWhere((s) => s.id == lastSongId);
      if (index != -1) {
        final song = _songs[index];
        setState(() => _currentIndex = index);

        final audioSource = AudioSource.uri(
          Uri.parse(song.data),
          tag: MediaItem(
            id: song.id.toString(),
            album: song.album ?? "Adagio",
            title: song.title,
            artist: song.artist ?? "Adagio Player",
          ),
        );

        await _audioPlayer.setAudioSource(audioSource);
        await _audioPlayer.seek(Duration(milliseconds: lastPositionMs));
      }
    }
  }

  Future<void> _triggerDjMixTransition() async {
    _isTransitioning = true;

    for (double v = 1.0; v >= 0.1; v -= 0.1) {
      await _audioPlayer.setVolume(v);
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (_songs.isNotEmpty) {
      int nextRandom = math.Random().nextInt(_songs.length);
      await _playSongAtIndex(nextRandom, _songs, startAtSecond: 25);
    }

    for (double v = 0.1; v <= 1.0; v += 0.1) {
      await _audioPlayer.setVolume(v);
      await Future.delayed(const Duration(milliseconds: 200));
    }

    _isTransitioning = false;
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final favsList = prefs.getStringList('adagio_favorites') ?? [];
    setState(() {
      _favoriteSongIds = favsList.map((id) => int.parse(id)).toSet();
    });
  }

  Future<void> _toggleFavorite(int songId) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_favoriteSongIds.contains(songId)) {
        _favoriteSongIds.remove(songId);
      } else {
        _favoriteSongIds.add(songId);
      }
    });
    await prefs.setStringList(
      'adagio_favorites',
      _favoriteSongIds.map((id) => id.toString()).toList(),
    );
  }

  Future<void> _incrementPlayCount(int songId) async {
    setState(() {
      _playCounts[songId] = (_playCounts[songId] ?? 0) + 1;
    });
  }

  Future<void> _requestPermissionAndScan() async {
    PermissionStatus status = await Permission.audio.request();
    if (!status.isGranted) {
      status = await Permission.storage.request();
    }

    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    setState(() {
      _hasPermission = status.isGranted;
    });

    if (_hasPermission) {
      await _scanAudioFiles();
      await _restoreLastPlaybackState();
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _scanAudioFiles() async {
    setState(() => _isLoading = true);
    List<SongModel> songs = await _audioQuery.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );

    songs = songs.where((s) => (s.duration ?? 0) > 10000).toList();

    setState(() {
      _songs = songs;
      _isLoading = false;
    });
  }

  List<SongModel> _getFilteredSongs() {
    if (_selectedTab == 1) {
      return _songs.where((s) => _favoriteSongIds.contains(s.id)).toList();
    } else if (_selectedTab == 2) {
      List<SongModel> sortedList = List.from(_songs);
      sortedList.sort(
          (a, b) => (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0));
      return sortedList.where((s) => (_playCounts[s.id] ?? 0) > 0).toList();
    }
    return _songs;
  }

  Future<void> _playSongAtIndex(int index, List<SongModel> currentList,
      {int startAtSecond = 0}) async {
    if (index < 0 || index >= currentList.length) return;
    try {
      final song = currentList[index];
      int originalIndex = _songs.indexWhere((s) => s.id == song.id);

      setState(() {
        _currentIndex = originalIndex != -1 ? originalIndex : index;
      });

      _incrementPlayCount(song.id);

      final audioSource = AudioSource.uri(
        Uri.parse(song.data),
        tag: MediaItem(
          id: song.id.toString(),
          album: song.album ?? "Adagio",
          title: song.title,
          artist: song.artist ?? "Adagio Player",
        ),
      );

      await _audioPlayer.setAudioSource(audioSource);

      if (startAtSecond > 0) {
        await _audioPlayer.seek(Duration(seconds: startAtSecond));
      }

      _audioPlayer.play();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al reproducir audio: $e')),
      );
    }
  }

  void _playNext() {
    if (_songs.isEmpty) return;
    if (_isShuffle || _isDjMix) {
      int nextIndex = math.Random().nextInt(_songs.length);
      _playSongAtIndex(nextIndex, _songs, startAtSecond: _isDjMix ? 25 : 0);
    } else {
      int nextIndex = (_currentIndex + 1) % _songs.length;
      _playSongAtIndex(nextIndex, _songs);
    }
  }

  void _playPrevious() {
    if (_songs.isEmpty) return;
    int prevIndex = (_currentIndex - 1 + _songs.length) % _songs.length;
    _playSongAtIndex(prevIndex, _songs);
  }

  void _showAboutDialog(SkinTheme theme) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: theme.cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.graphic_eq, color: theme.primary, size: 28),
            const SizedBox(width: 10),
            Text(
              'Acerca de Adagio',
              style:
                  TextStyle(color: theme.primary, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Adagio Music Player',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text('Versión: 1.0.0+1',
                style: TextStyle(color: Colors.grey)),
            const Divider(height: 24),
            Row(
              children: [
                Icon(Icons.person, color: theme.primary, size: 20),
                const SizedBox(width: 8),
                const Text('Desarrollado por: Huayta®',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.email, color: theme.primary, size: 20),
                const SizedBox(width: 8),
                const SelectableText('ivan.huayta@live.com',
                    style: TextStyle(color: Colors.grey)),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cerrar', style: TextStyle(color: theme.primary)),
          ),
        ],
      ),
    );
  }

  void _confirmarSalida() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Salir de Adagio'),
        content: const Text('¿Deseas cerrar el reproductor de música?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              await _saveLastPlaybackState();
              _audioPlayer.stop();
              exit(0);
            },
            child: const Text('Salir'),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final theme = SkinTheme.themes[widget.currentSkin]!;
    SongModel? currentSong =
        (_currentIndex >= 0 && _currentIndex < _songs.length)
            ? _songs[_currentIndex]
            : null;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: GestureDetector(
          onTap: () => _showAboutDialog(theme),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq, color: theme.primary),
              const SizedBox(width: 8),
              Text(
                'Adagio',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                  color: theme.primary,
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.auto_awesome,
              color: _isDjMix ? theme.accent : theme.primary.withOpacity(0.5),
            ),
            tooltip: 'Modo DJ Mix',
            onPressed: () {
              setState(() => _isDjMix = !_isDjMix);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_isDjMix
                      ? 'Modo DJ Mix Activado'
                      : 'Modo Normal Activado'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          IconButton(
            icon: Icon(_showPlaylist ? Icons.graphic_eq : Icons.queue_music,
                color: theme.primary),
            tooltip: _showPlaylist ? 'Ver Reproductor' : 'Ver Lista',
            onPressed: () => setState(() => _showPlaylist = !_showPlaylist),
          ),
          PopupMenuButton<AppSkin>(
            icon: Icon(Icons.palette, color: theme.primary),
            tooltip: 'Tema',
            onSelected: widget.onSkinChanged,
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: AppSkin.azulCyber, child: Text('Azul Ciberpunk')),
              const PopupMenuItem(
                  value: AppSkin.carmesiFuego, child: Text('Rojo Carmesí')),
              const PopupMenuItem(
                  value: AppSkin.rosaNeon, child: Text('Rosado Neón')),
              const PopupMenuItem(
                  value: AppSkin.retroVinyl, child: Text('Retro Madera')),
              const PopupMenuItem(
                  value: AppSkin.claroSuave, child: Text('Modo Claro')),
            ],
          ),
          IconButton(
            icon: Icon(Icons.equalizer, color: theme.primary),
            tooltip: 'Ecualizador',
            onPressed: () => _openEqualizerModal(context, theme),
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new, color: Colors.redAccent),
            tooltip: 'Salir',
            onPressed: _confirmarSalida,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _showPlaylist
                ? _buildPlaylistView(theme)
                : _buildPlayerView(theme, currentSong),
          ),
          _buildExpandedBottomControls(theme, currentSong),
          GestureDetector(
            onTap: () => _showAboutDialog(theme),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: Text(
                'Desarrollado por Huayta®',
                style: TextStyle(
                  color: theme.primary.withOpacity(0.6),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerView(SkinTheme theme, SongModel? song) {
    bool isFav = song != null && _favoriteSongIds.contains(song.id);

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: RotationTransition(
            turns: _rotationController,
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black,
                border: Border.all(color: theme.primary, width: 5),
                boxShadow: [
                  BoxShadow(
                    color: theme.primary.withOpacity(0.4),
                    blurRadius: 30,
                    spreadRadius: 5,
                  )
                ],
              ),
              child: Center(
                child: ClipOval(
                  child: song != null
                      ? QueryArtworkWidget(
                          id: song.id,
                          type: ArtworkType.AUDIO,
                          artworkWidth: 220,
                          artworkHeight: 220,
                          artworkFit: BoxFit.cover,
                          nullArtworkWidget: _buildDefaultCover(theme),
                        )
                      : _buildDefaultCover(theme),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      song?.title ?? 'Selecciona una canción',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: theme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      song?.artist ?? 'Adagio Player',
                      style: const TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  ],
                ),
              ),
              if (song != null)
                IconButton(
                  icon: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav ? Colors.red : theme.primary,
                    size: 30,
                  ),
                  onPressed: () => _toggleFavorite(song.id),
                ),
            ],
          ),
        ),
        _buildVisualizerAnimation(theme),
      ],
    );
  }

  Widget _buildDefaultCover(SkinTheme theme) {
    return Container(
      width: 220,
      height: 220,
      color: theme.cardColor,
      child: Center(
        child: CircleAvatar(
          radius: 42,
          backgroundColor: theme.primary,
          child: const Icon(Icons.music_note, size: 50, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildVisualizerAnimation(SkinTheme theme) {
    return AnimatedBuilder(
      animation: _waveController,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(18, (index) {
            double height = 10 +
                (math.sin(_waveController.value * math.pi + (index * 0.4)) * 38)
                    .abs();
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3.0),
              width: 6.0,
              height: _audioPlayer.playing ? height : 6,
              decoration: BoxDecoration(
                color: theme.primary,
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: theme.primary.withOpacity(0.3),
                    blurRadius: 4,
                  )
                ],
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildPlaylistView(SkinTheme theme) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (!_hasPermission) {
      return Center(
        child: ElevatedButton(
          onPressed: _requestPermissionAndScan,
          child: const Text('Conceder Permisos'),
        ),
      );
    }

    final filteredSongs = _getFilteredSongs();

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              _buildTabButton('Todas', 0, theme),
              _buildTabButton('Favoritas', 1, theme),
              _buildTabButton('Más Escuchadas', 2, theme),
            ],
          ),
        ),
        Expanded(
          child: filteredSongs.isEmpty
              ? const Center(child: Text('No hay canciones en esta sección.'))
              : ListView.builder(
                  itemCount: filteredSongs.length,
                  itemBuilder: (context, index) {
                    final song = filteredSongs[index];
                    final isSelected =
                        _songs[_currentIndex < 0 ? 0 : _currentIndex].id ==
                            song.id;
                    final isFav = _favoriteSongIds.contains(song.id);

                    return Container(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? theme.primary.withOpacity(0.2)
                            : theme.cardColor.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        leading: QueryArtworkWidget(
                          id: song.id,
                          type: ArtworkType.AUDIO,
                          nullArtworkWidget: CircleAvatar(
                            backgroundColor: theme.cardColor,
                            child: Icon(Icons.music_note, color: theme.primary),
                          ),
                        ),
                        title: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected ? theme.primary : null,
                          ),
                        ),
                        subtitle: Text(
                          '${song.artist ?? 'Desconocido'} • (${_playCounts[song.id] ?? 0} repr.)',
                          maxLines: 1,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            isFav ? Icons.favorite : Icons.favorite_border,
                            color: isFav ? Colors.red : Colors.grey,
                            size: 20,
                          ),
                          onPressed: () => _toggleFavorite(song.id),
                        ),
                        onTap: () {
                          _playSongAtIndex(index, filteredSongs,
                              startAtSecond: _isDjMix ? 25 : 0);
                          setState(() => _showPlaylist = false);
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTabButton(String text, int index, SkinTheme theme) {
    bool isSelected = _selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? theme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isSelected ? Colors.white : Colors.grey,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedBottomControls(SkinTheme theme, SongModel? song) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<Duration>(
            stream: _audioPlayer.positionStream,
            builder: (context, snapshotPosition) {
              final position = snapshotPosition.data ?? Duration.zero;
              final duration = _audioPlayer.duration ?? Duration.zero;

              return Column(
                children: [
                  Slider(
                    activeColor: theme.primary,
                    inactiveColor: theme.primary.withOpacity(0.2),
                    value: position.inMilliseconds
                        .toDouble()
                        .clamp(0.0, duration.inMilliseconds.toDouble()),
                    max: duration.inMilliseconds > 0
                        ? duration.inMilliseconds.toDouble()
                        : 1.0,
                    onChanged: (val) {
                      _audioPlayer.seek(Duration(milliseconds: val.round()));
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position),
                            style: const TextStyle(fontSize: 10)),
                        Text(_formatDuration(duration),
                            style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(
                  Icons.shuffle,
                  color: _isShuffle ? theme.primary : Colors.grey,
                ),
                tooltip: 'Modo Aleatorio',
                onPressed: () => setState(() => _isShuffle = !_isShuffle),
              ),
              IconButton(
                icon: const Icon(Icons.skip_previous, size: 34),
                color: theme.primary,
                onPressed: _playPrevious,
              ),
              StreamBuilder<PlayerState>(
                stream: _audioPlayer.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;

                  return CircleAvatar(
                    radius: 28,
                    backgroundColor: theme.primary,
                    child: IconButton(
                      icon: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        size: 32,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        if (playing) {
                          _audioPlayer.pause();
                        } else {
                          if (_currentIndex == -1 && _songs.isNotEmpty) {
                            _playSongAtIndex(0, _songs,
                                startAtSecond: _isDjMix ? 25 : 0);
                          } else {
                            _audioPlayer.play();
                          }
                        }
                      },
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, size: 34),
                color: theme.primary,
                onPressed: _playNext,
              ),
              IconButton(
                icon: Icon(
                  _loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                  color:
                      _loopMode == LoopMode.one ? theme.primary : Colors.grey,
                ),
                tooltip: 'Modo Repetir',
                onPressed: () {
                  setState(() {
                    _loopMode =
                        _loopMode == LoopMode.off ? LoopMode.one : LoopMode.off;
                    _audioPlayer.setLoopMode(_loopMode);
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openEqualizerModal(BuildContext context, SkinTheme theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.cardColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        height: 380,
        child: Column(
          children: [
            Text(
              'Ecualizador Adagio Pro (8 Bandas)',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildPresetChip('Bass Boost', theme),
                  _buildPresetChip('Pop', theme),
                  _buildPresetChip('Rock', theme),
                  _buildPresetChip('Jazz', theme),
                  _buildPresetChip('Flat', theme),
                ],
              ),
            ),
            const SizedBox(height: 15),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildBandSlider('32Hz', theme),
                    _buildBandSlider('64Hz', theme),
                    _buildBandSlider('125Hz', theme),
                    _buildBandSlider('250Hz', theme),
                    _buildBandSlider('500Hz', theme),
                    _buildBandSlider('1kHz', theme),
                    _buildBandSlider('4kHz', theme),
                    _buildBandSlider('16kHz', theme),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetChip(String label, SkinTheme theme) {
    return Padding(
      padding: const EdgeInsets.only(right: 6.0),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        backgroundColor: theme.primary.withOpacity(0.15),
        labelStyle:
            TextStyle(color: theme.primary, fontWeight: FontWeight.bold),
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Preset $label aplicado.')),
          );
        },
      ),
    );
  }

  Widget _buildBandSlider(String label, SkinTheme theme) {
    double value = 0.5;
    return StatefulBuilder(
      builder: (context, setSliderState) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Column(
          children: [
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: Slider(
                  value: value,
                  activeColor: theme.primary,
                  onChanged: (v) => setSliderState(() => value = v),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AdagioApp());
}

// =============================================================================
// GESTIÓN DE SKINS Y TEMAS EN ESPAÑOL
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
  Map<int, int> _playCounts = {};

  bool _isLoading = true;
  bool _hasPermission = false;
  int _currentIndex = -1;

  bool _showPlaylist = false;
  int _selectedTab = 0; // 0: Todas, 1: Favoritas, 2: Más Escuchadas
  bool _isShuffle = false;
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
      duration: const Duration(milliseconds: 800),
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
      }

      if (state.processingState == ProcessingState.completed) {
        _playNext();
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _rotationController.dispose();
    _waveController.dispose();
    super.dispose();
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
    PermissionStatus status = await Permission.storage.request();
    if (!status.isGranted) {
      status = await Permission.audio.request();
    }

    setState(() {
      _hasPermission = status.isGranted;
    });

    if (_hasPermission) {
      _scanAudioFiles();
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

  Future<void> _playSongAtIndex(int index, List<SongModel> currentList) async {
    if (index < 0 || index >= currentList.length) return;
    try {
      final song = currentList[index];
      int originalIndex = _songs.indexWhere((s) => s.id == song.id);

      setState(() {
        _currentIndex = originalIndex != -1 ? originalIndex : index;
      });

      _incrementPlayCount(song.id);
      await _audioPlayer.setAudioSource(AudioSource.uri(Uri.parse(song.data)));
      _audioPlayer.play();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al reproducir audio: $e')),
      );
    }
  }

  void _playNext() {
    if (_songs.isEmpty) return;
    if (_isShuffle) {
      int nextIndex = math.Random().nextInt(_songs.length);
      _playSongAtIndex(nextIndex, _songs);
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
            onPressed: () {
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
        title: Row(
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
        actions: [
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
          // FIRMA
          Padding(
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
        ],
      ),
    );
  }

  // VISTA PRINCIPAL DEL REPRODUCTOR
  Widget _buildPlayerView(SkinTheme theme, SongModel? song) {
    bool isFav = song != null && _favoriteSongIds.contains(song.id);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // CARÁTULA GIRATORIA / DISCO
        Container(
          margin: const EdgeInsets.all(16),
          child: RotationTransition(
            turns: _rotationController,
            child: Container(
              width: 210,
              height: 210,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black,
                border: Border.all(color: theme.primary, width: 4),
                boxShadow: [
                  BoxShadow(
                    color: theme.primary.withOpacity(0.3),
                    blurRadius: 20,
                    spreadRadius: 2,
                  )
                ],
              ),
              child: Center(
                child: ClipOval(
                  child: song != null
                      ? QueryArtworkWidget(
                          id: song.id,
                          type: ArtworkType.AUDIO,
                          artworkWidth: 190,
                          artworkHeight: 190,
                          artworkFit: BoxFit.cover,
                          nullArtworkWidget: _buildDefaultCover(theme),
                        )
                      : _buildDefaultCover(theme),
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        // DETALLES Y BOTÓN DE ME GUSTA
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
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
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: theme.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song?.artist ?? 'Adagio Player',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (song != null)
                IconButton(
                  icon: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav ? Colors.red : theme.primary,
                    size: 28,
                  ),
                  onPressed: () => _toggleFavorite(song.id),
                ),
            ],
          ),
        ),

        const SizedBox(height: 15),

        // VISUALIZADOR DE ESPECTRO
        _buildVisualizerAnimation(theme),
      ],
    );
  }

  Widget _buildDefaultCover(SkinTheme theme) {
    return Container(
      width: 190,
      height: 190,
      color: theme.cardColor,
      child: Center(
        child: CircleAvatar(
          radius: 35,
          backgroundColor: theme.primary,
          child: const Icon(Icons.music_note, size: 40, color: Colors.white),
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
          children: List.generate(14, (index) {
            double height = 8 +
                (math.sin(_waveController.value * math.pi + index) * 22).abs();
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: 4.5,
              height: _audioPlayer.playing ? height : 5,
              decoration: BoxDecoration(
                color: theme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        );
      },
    );
  }

  // VISTA DE LISTA CON PESTAÑAS (TODAS, FAVORITAS, MÁS ESCUCHADAS)
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
        // SELECTOR DE PESTAÑAS
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
                          _playSongAtIndex(index, filteredSongs);
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

  // CONTROLES DE REPRODUCCIÓN (SLIDER + NAVEGACIÓN)
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
                            _playSongAtIndex(0, _songs);
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

  // ECUALIZADOR AVANZADO DE 8 BANDAS Y PRESETS
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

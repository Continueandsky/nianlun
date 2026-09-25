import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/pages/editor/journal_editor_page.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/services/audio_service.dart';
import 'package:nianlun/theme/starry_theme.dart';
import 'package:nianlun/utils/delta_utils.dart';
import 'package:path/path.dart' as p;

/// 节点页：点进「某一天」后的页面 ⭐核心体验
///
///  - 沉浸态（默认落地）：全屏照片 + 虚化氛围背景 + 日期头 + 唱片机，进入自动淡入音乐
///  - 翻书态（上滑进入 / 下滑返回）：背后变暗，纸质小书翻页，日记衬线正文 + 拍立得照片
///  - 两态切换音乐贯穿不断
class NodePage extends ConsumerStatefulWidget {
  final DateTime date;
  final int initialPhotoIndex;

  const NodePage({super.key, required this.date, this.initialPhotoIndex = 0});

  @override
  ConsumerState<NodePage> createState() => _NodePageState();
}

enum _NodeMode { immersive, book }

class _NodePageState extends ConsumerState<NodePage> {
  _NodeMode _mode = _NodeMode.immersive;
  bool _chromeVisible = true;
  bool _musicStarted = false;
  int _photoIndex = 0;

  PageController? _photoController;
  late final PlayerService _player;

  @override
  void initState() {
    super.initState();
    _photoIndex = widget.initialPhotoIndex < 0 ? 0 : widget.initialPhotoIndex;
    _player = ref.read(playerServiceProvider);
  }

  @override
  void dispose() {
    _photoController?.dispose();
    // 离开节点：音乐淡出
    _player.stopWithFade();
    super.dispose();
  }

  void _ensureController(int count) {
    if (_photoController != null || count == 0) return;
    final initial = math.min(_photoIndex, count - 1);
    _photoIndex = initial;
    _photoController = PageController(initialPage: initial);
  }

  void _startMusicIfNeeded(DayEntry entry) {
    if (_musicStarted) return;
    final music = entry.music;
    if (music == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repo = ref.read(dayRepositoryProvider);
      final file = await repo.musicFile(music);
      if (!await file.exists()) return;
      _musicStarted = true;
      final err = await _player.playWithFade(file.path, title: music.title);
      if (err != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entryAsync = ref.watch(dayEntryProvider(widget.date));
    final daysAsync = ref.watch(daysProvider);
    final rootAsync = ref.watch(mediaRootPathProvider);

    return Scaffold(
      backgroundColor: StarryTheme.deepSpace,
      body: entryAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: StarryTheme.starPurple)),
        error: (e, _) => Center(
          child: Text('读取失败：$e',
              style: const TextStyle(color: StarryTheme.starDim, fontSize: 13)),
        ),
        data: (entry) {
          _ensureController(entry.photos.length);
          _startMusicIfNeeded(entry);

          final rootPath = rootAsync.valueOrNull ?? '';
          final days = daysAsync.valueOrNull ?? const <DaySummary>[];
          final firstDay = days.isEmpty ? null : days.last.date;
          final ordinal = firstDay == null
              ? null
              : widget.date.difference(firstDay).inDays + 1;

          return GestureDetector(
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -220) {
                _switchMode(_NodeMode.book);
              } else if ((d.primaryVelocity ?? 0) > 220) {
                _switchMode(_NodeMode.immersive);
              }
            },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 620),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _mode == _NodeMode.immersive
                  ? _ImmersiveView(
                      key: const ValueKey('immersive'),
                      date: widget.date,
                      entry: entry,
                      rootPath: rootPath,
                      ordinal: ordinal,
                      photoController: _photoController,
                      photoIndex: _photoIndex,
                      chromeVisible: _chromeVisible,
                      player: _player,
                      onToggleChrome: () =>
                          setState(() => _chromeVisible = !_chromeVisible),
                      onPhotoChanged: (i) => setState(() => _photoIndex = i),
                      onWriteJournal: _openEditor,
                      onAttachPhotos: _attachPhotos,
                      onPickMusic: _pickMusic,
                      onRemoveMusic: _removeMusic,
                    )
                  : _BookView(
                      key: const ValueKey('book'),
                      date: widget.date,
                      entry: entry,
                      rootPath: rootPath,
                      onWriteJournal: _openEditor,
                      onEditJournal: (journal) => _openEditor(journal: journal),
                    ),
            ),
          );
        },
      ),
    );
  }

  void _switchMode(_NodeMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _chromeVisible = true;
    });
  }

  Future<void> _openEditor({JournalEntry? journal}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JournalEditorPage(date: widget.date, journal: journal),
    ));
    refreshAllDays(ref);
  }

  Future<void> _attachPhotos() async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) return;
    final count =
        await ref.read(mediaAttachServiceProvider).attachPhotos(widget.date, picked);
    refreshAllDays(ref);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(count > 0 ? '已加入 $count 张照片' : '加入失败，换个图片文件试试')),
    );
  }

  Future<void> _pickMusic() async {
    final picked = await FilePicker.pickFile(type: FileType.audio);
    if (picked == null) return;
    await ref.read(mediaAttachServiceProvider).attachMusic(widget.date, picked);
    refreshAllDays(ref);

    // 立刻换上这首
    final entry = await ref.read(dayRepositoryProvider).entryFor(widget.date);
    final music = entry.music;
    if (music == null) return;
    final file = await ref.read(dayRepositoryProvider).musicFile(music);
    if (!await file.exists()) return;
    _musicStarted = true;
    final err = await _player.playWithFade(file.path, title: music.title);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? '这一天的歌：${music.title}'),
    ));
  }

  Future<void> _removeMusic() async {
    await ref.read(mediaAttachServiceProvider).removeMusic(widget.date);
    await _player.stopWithFade();
    _musicStarted = false;
    refreshAllDays(ref);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已移除此天的配乐')));
  }
}

// ═══════════════════════ 状态① 沉浸态 ═══════════════════════

class _ImmersiveView extends StatelessWidget {
  final DateTime date;
  final DayEntry entry;
  final String rootPath;
  final int? ordinal;
  final PageController? photoController;
  final int photoIndex;
  final bool chromeVisible;
  final PlayerService player;
  final VoidCallback onToggleChrome;
  final ValueChanged<int> onPhotoChanged;
  final VoidCallback onWriteJournal;
  final VoidCallback onAttachPhotos;
  final VoidCallback onPickMusic;
  final VoidCallback onRemoveMusic;

  const _ImmersiveView({
    super.key,
    required this.date,
    required this.entry,
    required this.rootPath,
    required this.ordinal,
    required this.photoController,
    required this.photoIndex,
    required this.chromeVisible,
    required this.player,
    required this.onToggleChrome,
    required this.onPhotoChanged,
    required this.onWriteJournal,
    required this.onAttachPhotos,
    required this.onPickMusic,
    required this.onRemoveMusic,
  });

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final photos = entry.photos;
    final PhotoItem? current = photos.isEmpty
        ? null
        : photos[photoIndex < 0
            ? 0
            : (photoIndex >= photos.length ? photos.length - 1 : photoIndex)];

    return Stack(
      fit: StackFit.expand,
      children: [
        // 氛围底：当前照片放大虚化 + 压暗；无照片时是深空
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 700),
          child: current == null
              ? const ColoredBox(
                  key: ValueKey('empty-bg'), color: StarryTheme.deepSpace)
              : _BlurredBackdrop(
                  key: ValueKey(current.relativePath),
                  file: File(p.join(rootPath, current.relativePath)),
                ),
        ),
        SafeArea(
          child: Column(
            children: [
              _header(context),
              Expanded(
                child: photos.isEmpty
                    ? _emptyPhotos(context)
                    : GestureDetector(
                        onTap: onToggleChrome,
                        child: PageView.builder(
                          controller: photoController,
                          onPageChanged: onPhotoChanged,
                          itemCount: photos.length,
                          itemBuilder: (context, i) {
                            final photo = photos[i];
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                              child: Center(
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.55),
                                        blurRadius: 28,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: Image.file(
                                      File(p.join(rootPath, photo.relativePath)),
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => const SizedBox(
                                        height: 200,
                                        child: Center(
                                          child: Icon(
                                              Icons.broken_image_outlined,
                                              color: StarryTheme.starDim),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              if (current?.caption != null && (current?.caption ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 2, 30, 8),
                  child: Text(
                    '「 ${current!.caption} 」',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 13,
                        color: StarryTheme.starLight,
                        fontStyle: FontStyle.italic),
                  ),
                ),
              if (photos.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${photoIndex + 1} / ${photos.length}',
                    style:
                        const TextStyle(fontSize: 11, color: StarryTheme.starDim),
                  ),
                ),
              _MusicBar(
                player: player,
                music: entry.music,
                onPick: onPickMusic,
                onRemove: onRemoveMusic,
              ),
              AnimatedOpacity(
                opacity: chromeVisible ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                child: const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 10),
                  child: Text('上滑 · 翻开这一天的日记',
                      style: TextStyle(fontSize: 12, color: StarryTheme.starDim)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final d = date;
    final mood = entry.mood;
    final subtitle = <String>[
      if (ordinal != null) '第 $ordinal 个日子',
      if (mood != null) mood.label,
      if (entry.journals.isNotEmpty) '${entry.journals.length} 篇日记',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down,
                color: StarryTheme.starDim),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  '${d.month}月${d.day}日 · 星期${_weekdays[d.weekday - 1]}',
                  style: const TextStyle(
                      fontSize: 16,
                      color: StarryTheme.starLight,
                      fontWeight: FontWeight.w500),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 11,
                          color: StarryTheme.starDim,
                          fontStyle: FontStyle.italic)),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, color: StarryTheme.starDim),
            color: StarryTheme.nebula,
            onSelected: (value) {
              switch (value) {
                case 'journal':
                  onWriteJournal();
                case 'photo':
                  onAttachPhotos();
                case 'music':
                  onPickMusic();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: 'journal',
                  child: Text('写日记',
                      style: TextStyle(color: StarryTheme.starLight))),
              PopupMenuItem(
                  value: 'photo',
                  child: Text('加入照片',
                      style: TextStyle(color: StarryTheme.starLight))),
              PopupMenuItem(
                  value: 'music',
                  child: Text('配上这一天的一首歌',
                      style: TextStyle(color: StarryTheme.starLight))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyPhotos(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.photo_camera_back_outlined,
            size: 44, color: StarryTheme.starDim),
        const SizedBox(height: 14),
        const Text('这一天还没有照片',
            style: TextStyle(fontSize: 14, color: StarryTheme.starLight)),
        const SizedBox(height: 6),
        const Text('可以补几张，也可以只写下文字',
            style: TextStyle(fontSize: 12, color: StarryTheme.starDim)),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: StarryTheme.starPurple,
                side: const BorderSide(color: StarryTheme.starPurple),
              ),
              onPressed: onAttachPhotos,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('加入照片'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: StarryTheme.starDim,
                side: const BorderSide(color: Color(0xFF2E3560)),
              ),
              onPressed: onWriteJournal,
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('写日记'),
            ),
          ],
        ),
      ],
    );
  }
}

class _BlurredBackdrop extends StatelessWidget {
  final File file;
  const _BlurredBackdrop({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Image.file(
            file,
            fit: BoxFit.cover,
            cacheWidth: 220,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: StarryTheme.deepSpace),
          ),
        ),
        ColoredBox(color: StarryTheme.deepSpace.withValues(alpha: 0.62)),
      ],
    );
  }
}

/// 唱片机播放条（真实播放/暂停 + 进度 + 旋转唱片）
class _MusicBar extends StatelessWidget {
  final PlayerService player;
  final MusicTrack? music;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _MusicBar({
    required this.player,
    required this.music,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final track = music;

    if (track == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: TextButton.icon(
          onPressed: onPick,
          style: TextButton.styleFrom(
            foregroundColor: StarryTheme.starPurple,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          icon: const Icon(Icons.library_music_outlined, size: 18),
          label: const Text('为这一天配一首歌', style: TextStyle(fontSize: 13)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GestureDetector(
        onLongPress: () => _showActions(context),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            color: StarryTheme.nebula.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2E3560)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const _VinylDisc(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                color: StarryTheme.starLight,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 2),
                        StreamBuilder<Duration>(
                          stream: player.player.positionStream,
                          builder: (context, snapshot) {
                            final pos = snapshot.data ?? Duration.zero;
                            final total =
                                player.player.duration ?? Duration.zero;
                            final artist =
                                track.artist == null ? '' : ' · ${track.artist}';
                            return Text(
                              '${_fmt(pos)} / ${_fmt(total)}$artist',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11, color: StarryTheme.starDim),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  StreamBuilder<bool>(
                    stream: player.player.playingStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data ?? player.player.playing;
                      return IconButton(
                        iconSize: 26,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: StarryTheme.starPurple,
                        ),
                        onPressed: () =>
                            playing ? player.pause() : player.resume(),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              StreamBuilder<Duration>(
                stream: player.player.positionStream,
                builder: (context, snapshot) {
                  final pos = (snapshot.data ?? Duration.zero).inMilliseconds;
                  final total =
                      (player.player.duration ?? Duration.zero).inMilliseconds;
                  final raw = total <= 0 ? 0.0 : pos / total;
                  final value = math.min(1.0, math.max(0.0, raw));
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 2,
                      backgroundColor: const Color(0xFF2A3160),
                      valueColor:
                          const AlwaysStoppedAnimation(StarryTheme.starPurple),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: StarryTheme.nebula,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.swap_horiz, color: StarryTheme.starPurple),
              title: const Text('换一首',
                  style: TextStyle(color: StarryTheme.starLight)),
              onTap: () {
                Navigator.of(ctx).pop();
                onPick();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.music_off_outlined, color: StarryTheme.starDim),
              title: const Text('移除配乐',
                  style: TextStyle(color: StarryTheme.starDim)),
              onTap: () {
                Navigator.of(ctx).pop();
                onRemove();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _VinylDisc extends StatefulWidget {
  const _VinylDisc();

  @override
  State<_VinylDisc> createState() => _VinylDiscState();
}

class _VinylDiscState extends State<_VinylDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
        vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _spin,
      child: Container(
        width: 38,
        height: 38,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: StarryTheme.deepSpace,
          border: Border.fromBorderSide(
              BorderSide(color: Color(0xFF4A5488), width: 1.2)),
        ),
        child: const Center(
          child: CircleAvatar(radius: 4, backgroundColor: StarryTheme.starPurple),
        ),
      ),
    );
  }
}

// ═══════════════════════ 状态② 翻书态 ═══════════════════════

class _BookView extends StatefulWidget {
  final DateTime date;
  final DayEntry entry;
  final String rootPath;
  final VoidCallback onWriteJournal;
  final ValueChanged<JournalEntry> onEditJournal;

  const _BookView({
    super.key,
    required this.date,
    required this.entry,
    required this.rootPath,
    required this.onWriteJournal,
    required this.onEditJournal,
  });

  @override
  State<_BookView> createState() => _BookViewState();
}

class _BookViewState extends State<_BookView> {
  // 纸张尽量占满屏宽（照片才能更大），只留一点点邻页边缘暗示这是一本书
  final PageController _controller = PageController(viewportFraction: 0.97);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final date = widget.date;

    final pages = <Widget>[
      for (final journal in entry.journals)
        _JournalPaper(
          date: date,
          journal: journal,
          mood: entry.mood,
          onEdit: () => widget.onEditJournal(journal),
          onAdd: widget.onWriteJournal,
        ),
    ];
    // 照片页需要知道自己在 PageView 里的下标，才能按翻页进度做旋转动画
    for (final photo in entry.photos) {
      pages.add(_PolaroidPage(
        date: date,
        photo: photo,
        rootPath: widget.rootPath,
        controller: _controller,
        pageIndex: pages.length,
      ));
    }
    if (pages.isEmpty) {
      pages.add(_BlankPaper(date: date, onWrite: widget.onWriteJournal));
    }

    final music = entry.music;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              music == null
                  ? '${date.year}.${date.month}.${date.day}'
                  : '♪ ${music.title} · 正在播放',
              style: const TextStyle(fontSize: 12, color: StarryTheme.starPurple),
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: pages.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
                child: _PageFlip(
                  controller: _controller,
                  index: i,
                  child: pages[i],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text('下滑 · 回到照片',
                style: TextStyle(fontSize: 12, color: StarryTheme.starDim)),
          ),
        ],
      ),
    );
  }
}

/// 翻页时的纸张 3D 翻转
class _PageFlip extends StatelessWidget {
  final PageController controller;
  final int index;
  final Widget child;

  const _PageFlip({
    required this.controller,
    required this.index,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, inner) {
        var delta = 0.0;
        if (controller.hasClients && controller.position.haveDimensions) {
          delta = (controller.page ?? 0) - index;
        }
        final angle = math.max(-1.0, math.min(1.0, delta)) * -0.55;
        return Transform(
          alignment: Alignment.centerRight,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateY(angle),
          child: inner,
        );
      },
      child: child,
    );
  }
}

/// 纸张公共外观（米白纸 + 装订线 + 阴影）
class _Paper extends StatelessWidget {
  final Widget child;
  const _Paper({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: StarryTheme.paper,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.horizontal(left: Radius.circular(6)),
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xFFD9CFB6), Color(0xFFF3EBD8)],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _JournalPaper extends StatefulWidget {
  final DateTime date;
  final JournalEntry journal;
  final Mood? mood;
  final VoidCallback onEdit;
  final VoidCallback onAdd;

  const _JournalPaper({
    required this.date,
    required this.journal,
    required this.mood,
    required this.onEdit,
    required this.onAdd,
  });

  @override
  State<_JournalPaper> createState() => _JournalPaperState();
}

class _JournalPaperState extends State<_JournalPaper> {
  late final QuillController _controller;

  @override
  void initState() {
    super.initState();
    _controller = buildReadOnlyController(widget.journal.contentJson);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.date;
    return _Paper(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${d.year}.${d.month}.${d.day}',
                    style: const TextStyle(
                        fontSize: 17,
                        color: StarryTheme.paperInk,
                        fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined,
                      size: 17, color: StarryTheme.paperDim),
                  onPressed: widget.onEdit,
                ),
              ],
            ),
            if (widget.mood != null)
              Text('心情 · ${widget.mood!.label}',
                  style: const TextStyle(
                      fontSize: 11,
                      color: StarryTheme.paperDim,
                      fontStyle: FontStyle.italic)),
            const SizedBox(height: 10),
            Container(height: 1, color: const Color(0xFFDCD2B8)),
            const SizedBox(height: 12),
            Expanded(
              child: Theme(
                data: StarryTheme.paperLight,
                child: QuillEditor.basic(
                  controller: _controller,
                  config: const QuillEditorConfig(
                    showCursor: false,
                    enableInteractiveSelection: true,
                    padding: EdgeInsets.zero,
                    customStyles: DefaultStyles(
                      paragraph: DefaultTextBlockStyle(
                        TextStyle(
                          fontSize: 15,
                          height: 1.75,
                          color: StarryTheme.paperInk,
                        ),
                        HorizontalSpacing.zero,
                        VerticalSpacing.zero,
                        VerticalSpacing.zero,
                        null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.onAdd,
                style: TextButton.styleFrom(
                    foregroundColor: StarryTheme.paperDim,
                    visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('再写一篇', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PolaroidPage extends StatelessWidget {
  final DateTime date;
  final PhotoItem photo;
  final String rootPath;
  final PageController controller;
  final int pageIndex;

  const _PolaroidPage({
    required this.date,
    required this.photo,
    required this.rootPath,
    required this.controller,
    required this.pageIndex,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(p.join(rootPath, photo.relativePath));
    // 横图：翻页过程中从「横向原样」顺势旋转 90° 立起来铺满
    // 竖图：拍立得白边卡片，按纸面最大化
    return photo.aspectRatio > 1.0
        ? _LandscapePhotoCard(
            date: date,
            photo: photo,
            file: file,
            controller: controller,
            pageIndex: pageIndex,
          )
        : _PortraitPhotoCard(date: date, photo: photo, file: file);
  }
}

/// 横向照片：翻页过程中从「横向原样」顺势旋转 90°（顺时针）立起来铺满纸页
///
/// 旋转角由 PageView 的翻页进度驱动：这一页刚露头时 p=0（照片横着、完整可见），
/// 翻到底时 p=1（转满 90° 并刚好占满整张卡片）——手指停下来，动画也刚好走完。
class _LandscapePhotoCard extends StatelessWidget {
  final DateTime date;
  final PhotoItem photo;
  final File file;
  final PageController controller;
  final int pageIndex;

  const _LandscapePhotoCard({
    required this.date,
    required this.photo,
    required this.file,
    required this.controller,
    required this.pageIndex,
  });

  @override
  Widget build(BuildContext context) {
    final caption = photo.caption;
    final label = (caption ?? '').isNotEmpty
        ? '「 $caption 」'
        : '${date.year}.${date.month}.${date.day} 拍下';
    final ar = photo.aspectRatio.clamp(1.02, 4.0);

    return _Paper(
      child: LayoutBuilder(
        builder: (context, c) {
          const m = 8.0; // 纸面留白
          final cardW = math.max(c.maxWidth - m * 2, 1.0);
          final cardH = math.max(c.maxHeight - m * 2, 1.0);

          // 照片的基准显示尺寸（p=0 时横着完整显示，宽度顶满卡片）
          final photoW = cardW;
          final photoH = cardW / ar;
          // p=1 时旋转 90°，需要 scale 使得视觉边界铺满卡片
          // 视觉宽 = photoH * scale, 视觉高 = photoW * scale
          // 铺满条件：scale = max(cardW / photoH, cardH / photoW)
          //         = max(ar, cardH / cardW)
          final endScale = math.max(ar, cardH / cardW);

          // 解码分辨率：照片长边旋转后要铺满卡片高度，
          // 需要 cardH × DPR 个像素，太低会糊（固定 900 不够）
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final decodeW =
              (cardH * dpr * 1.15).ceil().clamp(720, 3200);

          return Center(
            child: SizedBox(
              width: cardW,
              height: cardH,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedBuilder(
                      animation: controller,
                      child: Image.file(
                        file,
                        width: photoW,
                        height: photoH,
                        fit: BoxFit.cover,
                        cacheWidth: decodeW,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => Container(
                          color: const Color(0xFFE8E4DA),
                          child: const Center(
                            child: Icon(Icons.broken_image_outlined,
                                color: StarryTheme.paperDim, size: 32),
                          ),
                        ),
                      ),
                      builder: (context, child) {
                        var delta = 0.0;
                        if (controller.hasClients &&
                            controller.position.haveDimensions) {
                          delta = (controller.page ?? pageIndex.toDouble()) -
                              pageIndex;
                        }
                        // p：0 = 这一页刚露出一点点，1 = 已经翻到这一页
                        final p = (1 - delta.abs()).clamp(0.0, 1.0);
                        final angle = p * math.pi / 2; // 顺时针 90°
                        final scale = 1 + (endScale - 1) * p;

                        return Center(
                          child: Transform.rotate(
                            angle: angle,
                            alignment: Alignment.center,
                            child: Transform.scale(
                              scale: scale,
                              child: SizedBox(
                                width: photoW,
                                height: photoH,
                                child: child,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    // 底部渐变 + 日期/说明（不跟着旋转）
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 28, 14, 14),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.55),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 竖向照片：拍立得白边卡片，按纸面最大化（宽/高谁先顶住就听谁的），
/// 日期写在照片下方那道白边上——就像一张真照片贴在纸页上
class _PortraitPhotoCard extends StatelessWidget {
  final DateTime date;
  final PhotoItem photo;
  final File file;

  const _PortraitPhotoCard({
    required this.date,
    required this.photo,
    required this.file,
  });

  @override
  Widget build(BuildContext context) {
    final caption = photo.caption;
    final label = (caption ?? '').isNotEmpty
        ? '「 $caption 」'
        : '${date.year}.${date.month}.${date.day} 拍下';
    final ar = photo.aspectRatio.clamp(0.24, 1.0);

    return _Paper(
      child: LayoutBuilder(
        builder: (context, c) {
          const padX = 8.0; // 纸面左右留白
          const padY = 10.0; // 纸面上下留白
          const border = 8.0; // 照片左右/上白边
          const borderBottom = 34.0; // 照片下方白边（放日期）

          final availW = math.max(c.maxWidth - padX * 2, 1.0);
          final availH = math.max(c.maxHeight - padY * 2, 1.0);

          // 照片按真实比例放到最大：受宽度限制还是受高度限制，取小的那个
          final photoH = math.max(
            1.0,
            math.min(
              (availW - border * 2) / ar,
              availH - border - borderBottom,
            ),
          );
          final photoW = photoH * ar;
          final cardW = photoW + border * 2;
          final cardH = photoH + border + borderBottom;

          return Center(
            child: Container(
              width: cardW,
              height: cardH,
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: border,
                    top: border,
                    width: photoW,
                    height: photoH,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Image.file(
                        file,
                        fit: BoxFit.cover,
                        cacheWidth: 720,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(Icons.broken_image_outlined,
                              color: StarryTheme.paperDim),
                        ),
                      ),
                    ),
                  ),
                  // 白底下沿的日期 / 说明
                  Positioned(
                    left: border,
                    right: border,
                    bottom: 0,
                    height: borderBottom,
                    child: Center(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 11,
                          color: StarryTheme.paperDim,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BlankPaper extends StatelessWidget {
  final DateTime date;
  final VoidCallback onWrite;

  const _BlankPaper({required this.date, required this.onWrite});

  @override
  Widget build(BuildContext context) {
    return _Paper(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${date.month}月${date.day}日',
                style: const TextStyle(
                    fontSize: 18,
                    color: StarryTheme.paperInk,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 10),
            const Text('这一天的空白，也是年轮的一部分',
                style: TextStyle(fontSize: 12, color: StarryTheme.paperDim)),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: StarryTheme.paperInk,
                foregroundColor: StarryTheme.paper,
              ),
              onPressed: onWrite,
              child: const Text('写下这一天'),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/pages/node/node_page.dart';
import 'package:nianlun/pages/settings/backup_sheet.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/services/photo_import_service.dart';
import 'package:nianlun/theme/starry_theme.dart';
import 'package:path/path.dart' as p;

/// Tab 1「星河」：照片像记忆碎片散落在一张无边桌面上
/// 支持双指缩放 / 单指拖动画布，点击碎片进入它所属的那一天
class StarRiverPage extends ConsumerWidget {
  const StarRiverPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daysAsync = ref.watch(daysProvider);
    final rootAsync = ref.watch(mediaRootPathProvider);

    return daysAsync.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: StarryTheme.starPurple)),
      error: (e, _) => Center(
        child: Text('读取失败：$e',
            style: const TextStyle(color: StarryTheme.starDim, fontSize: 13)),
      ),
      data: (days) => rootAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: StarryTheme.starPurple)),
        error: (e, _) => Center(
          child: Text('媒体目录读取失败：$e',
              style:
                  const TextStyle(color: StarryTheme.starDim, fontSize: 13)),
        ),
        data: (rootPath) => _ScatterBody(days: days, rootPath: rootPath),
      ),
    );
  }
}

class _ScatterBody extends ConsumerStatefulWidget {
  final List<DaySummary> days;
  final String rootPath;

  const _ScatterBody({required this.days, required this.rootPath});

  @override
  ConsumerState<_ScatterBody> createState() => _ScatterBodyState();
}

class _ScatterBodyState extends ConsumerState<_ScatterBody>
    with TickerProviderStateMixin {
  late final TransformationController _controller;
  late final AnimationController _entryAnim;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
    _entryAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _entryAnim.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _entryAnim.dispose();
    super.dispose();
  }

  void _fitInitial(BoxConstraints constraints, Size canvas) {
    if (_fitted) return;
    final viewport = Size(constraints.maxWidth, constraints.maxHeight);
    // 初始视角：把整个画布装进屏幕，留出顶部标题栏空间
    final scaleX = viewport.width / canvas.width;
    final scaleY = viewport.height / canvas.height;
    final scale = (min(scaleX, scaleY) * 0.92).clamp(0.18, 1.0);
    final tx = (viewport.width - canvas.width * scale) / 2;
    final ty = (viewport.height - canvas.height * scale) / 2;
    _controller.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0.0, 1.0)
      ..scaleByDouble(scale, scale, 1.0, 1.0);
    _fitted = true;
  }

  void _onDoubleTap() {
    final current = _controller.value.getMaxScaleOnAxis();
    final size = MediaQuery.of(context).size;
    final target = current < 1.0 ? 1.8 : 0.55;
    _controller.value = Matrix4.identity()
      ..translateByDouble((size.width - size.width * target) / 2,
          (size.height - size.height * target) / 2, 0.0, 1.0)
      ..scaleByDouble(target, target, 1.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final shards = _collectShards(widget.days);
    final totalPhotos = shards.length;
    final empty = totalPhotos == 0;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景星点
        const _StarField(),
        if (!empty)
          LayoutBuilder(
            builder: (context, constraints) {
              final canvas = _canvasSize(constraints, shards.length);
              final layout = _scatter(shards, canvas);
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _fitInitial(constraints, canvas),
              );
              return GestureDetector(
                onDoubleTap: _onDoubleTap,
                behavior: HitTestBehavior.translucent,
                child: InteractiveViewer(
                  transformationController: _controller,
                  boundaryMargin: const EdgeInsets.all(120),
                  minScale: 0.12,
                  maxScale: 4.0,
                  panAxis: PanAxis.free,
                  child: SizedBox(
                    width: canvas.width,
                    height: canvas.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: layout.asMap().entries.map((e) {
                        final delay = (e.key / max(layout.length, 1)) * 0.55;
                        return FadeTransition(
                          opacity: CurvedAnimation(
                            parent: _entryAnim,
                            curve: Interval(delay, 1.0,
                                curve: Curves.easeOutQuad),
                          ),
                          child: _PhotoShard(
                            rootPath: widget.rootPath,
                            shard: e.value,
                            onTap: () => Navigator.of(context)
                                .push(MaterialPageRoute(
                              builder: (_) => NodePage(
                                date: e.value.date,
                                initialPhotoIndex: e.value.indexInDay,
                              ),
                            )),
                            onLongPress: () =>
                                _confirmRemovePhoto(context, ref, e.value),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              );
            },
          ),
        if (empty)
          _EmptyRiver(onImport: () => ImportFlow.pickAndRun(context, ref)),
        // 悬浮标题栏
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: _RiverHeader(
              totalPhotos: totalPhotos,
              dayCount: widget.days.where((d) => d.hasPhotos).length,
            ),
          ),
        ),
      ],
    );
  }

  List<_Shard> _collectShards(List<DaySummary> days) {
    final shards = <_Shard>[];
    for (final day in days) {
      for (var i = 0; i < day.photos.length; i++) {
        shards.add(_Shard(
          photo: day.photos[i],
          date: day.date,
          indexInDay: i,
        ));
      }
    }
    // 新日子铺在上层
    return shards.reversed.toList();
  }

  Size _canvasSize(BoxConstraints constraints, int count) {
    final viewport = Size(constraints.maxWidth, constraints.maxHeight);
    // 碎片越多，桌面越大；最少 2.2 屏，最多 5 屏
    final scale = 2.2 + sqrt(count / 10).clamp(0.0, 2.8);
    final width = viewport.width * scale;
    final height = viewport.height * max(1.6, scale * 0.85);
    return Size(width, height);
  }

  List<_PlacedShard> _scatter(List<_Shard> shards, Size canvas) {
    final rand = Random(20260925); // 固定种子，同一次数据布局稳定
    const cardW = 108.0;
    const cardH = 130.0;
    const padding = 18.0;

    final placed = <_PlacedShard>[];
    for (var i = 0; i < shards.length; i++) {
      // 螺旋 + 随机抖动，让照片像随手撒在桌面上
      final t = i / max(shards.length, 1);
      final angle = i * 2.1 + rand.nextDouble() * 0.9;
      final radius = 60 + t * (canvas.shortestSide / 2.1) +
          (rand.nextDouble() - 0.5) * 120;

      final cx = canvas.width / 2 + radius * cos(angle);
      final cy = canvas.height / 2 + radius * sin(angle) * 0.75 +
          (rand.nextDouble() - 0.5) * 80;

      final left = (cx - cardW / 2).clamp(padding, canvas.width - cardW - padding);
      final top = (cy - cardH / 2).clamp(padding, canvas.height - cardH - padding);

      final rotation = (rand.nextDouble() - 0.5) * 0.35; // ±10°
      final z = i;

      placed.add(_PlacedShard(
        shard: shards[i],
        left: left,
        top: top,
        rotation: rotation,
        zIndex: z,
      ));
    }
    return placed;
  }

  Future<void> _confirmRemovePhoto(
      BuildContext context, WidgetRef ref, _PlacedShard shard) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StarryTheme.nebula,
        title: const Text('从「年轮」移除这张照片？',
            style: TextStyle(fontSize: 16, color: StarryTheme.starLight)),
        content: Text(
          '只会删除年轮里的副本，系统相册中的原图不受影响。\n'
          '${shard.date.year}.${shard.date.month}.${shard.date.day}',
          style: const TextStyle(
              fontSize: 13, color: StarryTheme.starDim, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消',
                style: TextStyle(color: StarryTheme.starDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除',
                style: TextStyle(color: StarryTheme.starPurple)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(mediaAttachServiceProvider).removePhoto(shard.photo);
    refreshAllDays(ref);
  }
}

// ───────────────────────── 数据对象 ─────────────────────────

class _Shard {
  final PhotoItem photo;
  final DateTime date;
  final int indexInDay;

  const _Shard({
    required this.photo,
    required this.date,
    required this.indexInDay,
  });
}

class _PlacedShard {
  final _Shard shard;
  final double left;
  final double top;
  final double rotation;
  final int zIndex;

  PhotoItem get photo => shard.photo;
  DateTime get date => shard.date;
  int get indexInDay => shard.indexInDay;

  _PlacedShard({
    required this.shard,
    required this.left,
    required this.top,
    required this.rotation,
    required this.zIndex,
  });
}

// ───────────────────────── 单个碎片（拍立得卡片） ─────────────────────────

class _PhotoShard extends StatelessWidget {
  final String rootPath;
  final _PlacedShard shard;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PhotoShard({
    required this.rootPath,
    required this.shard,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(p.join(rootPath, shard.photo.relativePath));

    return Positioned(
      left: shard.left,
      top: shard.top,
      child: Transform.rotate(
        angle: shard.rotation,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          behavior: HitTestBehavior.opaque,
          child: RepaintBoundary(
            child: Container(
              width: 108,
              height: 130,
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F6EF),
                borderRadius: BorderRadius.circular(5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(2, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // 照片区
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      width: 96,
                      height: 96,
                      child: Image.file(
                        file,
                        fit: BoxFit.cover,
                        cacheWidth: 240,
                        errorBuilder: (_, __, ___) => Container(
                          color: const Color(0xFFE8E4DA),
                          child: const Icon(
                            Icons.broken_image_outlined,
                            color: Color(0xFF9E9A8E),
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 日期标签
                  Expanded(
                    child: Center(
                      child: Text(
                        '${shard.date.month}.${shard.date.day}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF6B6559),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 背景星点 ─────────────────────────

class _StarField extends StatelessWidget {
  const _StarField();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StarPainter(),
      child: const SizedBox.expand(),
    );
  }
}

class _StarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rand = Random(2025);
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.18);
    final count = (size.width * size.height / 8000).clamp(30, 180).toInt();

    for (var i = 0; i < count; i++) {
      final x = rand.nextDouble() * size.width;
      final y = rand.nextDouble() * size.height;
      final r = rand.nextDouble() * 1.2 + 0.4;
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ───────────────────────── 顶部 ─────────────────────────

class _RiverHeader extends ConsumerWidget {
  final int totalPhotos;
  final int dayCount;

  const _RiverHeader({required this.totalPhotos, required this.dayCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 10, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('星河',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                        color: StarryTheme.starLight)),
                const SizedBox(height: 4),
                Text(
                  totalPhotos == 0
                      ? '每一颗星，都是那一天的光'
                      : '$dayCount 个日子 · $totalPhotos 颗星',
                  style: const TextStyle(
                      fontSize: 12,
                      color: StarryTheme.starDim,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '导入照片',
            icon: const Icon(Icons.add_photo_alternate_outlined,
                color: StarryTheme.starPurple),
            onPressed: () => ImportFlow.pickAndRun(context, ref),
          ),
          IconButton(
            tooltip: '备份与恢复',
            icon: const Icon(Icons.folder_special_outlined,
                color: StarryTheme.starPurple),
            onPressed: () => showBackupSheet(context, ref),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 空态 ─────────────────────────

class _EmptyRiver extends StatelessWidget {
  final VoidCallback onImport;
  const _EmptyRiver({required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.auto_awesome, size: 54, color: StarryTheme.warmGlow),
        const SizedBox(height: 18),
        const Text('银河还很安静',
            style: TextStyle(fontSize: 16, color: StarryTheme.starLight)),
        const SizedBox(height: 8),
        const Text('导入你的照片，让它们开始发光',
            style: TextStyle(fontSize: 13, color: StarryTheme.starDim)),
        const SizedBox(height: 26),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: StarryTheme.starPurple,
            foregroundColor: StarryTheme.deepSpace,
          ),
          onPressed: onImport,
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('导入照片'),
        ),
      ],
    );
  }
}

// ───────────────────────── 导入流程 ─────────────────────────

class _ImportDialog extends StatelessWidget {
  final ValueNotifier<ImportProgress?> progress;
  final VoidCallback onCancel;

  const _ImportDialog({required this.progress, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: StarryTheme.nebula,
      title: const Text('正在把照片收进年轮…',
          style: TextStyle(fontSize: 15, color: StarryTheme.starLight)),
      content: ValueListenableBuilder<ImportProgress?>(
        valueListenable: progress,
        builder: (context, value, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: value?.ratio,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF2A3160),
                  valueColor:
                      const AlwaysStoppedAnimation(StarryTheme.starPurple),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                value == null
                    ? '读取相册中…'
                    : '${value.scanned} / ${value.total}　新导入 ${value.imported}',
                style: const TextStyle(fontSize: 12, color: StarryTheme.starDim),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: const Text('停下', style: TextStyle(color: StarryTheme.starDim)),
        ),
      ],
    );
  }
}

abstract final class ImportFlow {
  /// 弹出导入方式选择，然后开始导入
  static Future<void> pickAndRun(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<_ImportChoice>(
      context: context,
      backgroundColor: StarryTheme.nebula,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text('把相册里的照片收进年轮',
                  style: TextStyle(fontSize: 15, color: StarryTheme.starLight)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '照片按拍摄日期自动归到那一天，已导入的不会重复。',
                style: TextStyle(
                    fontSize: 12, color: StarryTheme.starDim, height: 1.6),
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.all_inclusive, color: StarryTheme.starPurple),
              title: const Text('导入全部照片',
                  style: TextStyle(color: StarryTheme.starLight)),
              subtitle: const Text('照片多时耗时久、占空间大',
                  style: TextStyle(fontSize: 11, color: StarryTheme.starDim)),
              onTap: () => Navigator.of(ctx).pop(_ImportChoice.all),
            ),
            ListTile(
              leading: const Icon(Icons.history, color: StarryTheme.starPurple),
              title: const Text('只导入最近一年',
                  style: TextStyle(color: StarryTheme.starLight)),
              subtitle: const Text('推荐，先跑通再补全',
                  style: TextStyle(fontSize: 11, color: StarryTheme.starDim)),
              onTap: () => Navigator.of(ctx).pop(_ImportChoice.year),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline,
                  color: StarryTheme.starPurple),
              title: const Text('从相册挑选',
                  style: TextStyle(color: StarryTheme.starLight)),
              subtitle: const Text('调用系统相册选择照片',
                  style: TextStyle(fontSize: 11, color: StarryTheme.starDim)),
              onTap: () => Navigator.of(ctx).pop(_ImportChoice.pick),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;

    if (choice == _ImportChoice.pick) {
      final picker = ImagePicker();
      final files = await picker.pickMultiImage();
      if (files.isEmpty || !context.mounted) return;
      await _runImportFiles(context, ref, files);
      return;
    }

    await runSince(
      context,
      ref,
      since: choice == _ImportChoice.all
          ? null
          : DateTime.now().subtract(const Duration(days: 365)),
    );
  }

  /// 执行全量/最近一年导入
  static Future<void> runSince(BuildContext context, WidgetRef ref,
      {DateTime? since}) async {
    final service = ref.read(photoImportServiceProvider);
    final progress = ValueNotifier<ImportProgress?>(null);
    var cancelled = false;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ImportDialog(progress: progress, onCancel: () => cancelled = true),
    );

    ImportResult result;
    try {
      result = await service.importFromLibrary(
        since: since,
        onProgress: (v) => progress.value = v,
        isCancelled: () => cancelled,
      );
    } catch (_) {
      result = const ImportResult();
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    refreshAllDays(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        result.permissionDenied
            ? '需要相册权限才能导入照片，请在系统设置里允许「年轮」访问照片'
            : result.summary,
      ),
      duration: const Duration(seconds: 4),
    ));
  }

  /// 执行手动挑选导入（系统相册选择器返回的 XFile）
  static Future<void> _runImportFiles(
    BuildContext context,
    WidgetRef ref,
    List<XFile> files,
  ) async {
    final service = ref.read(photoImportServiceProvider);
    final progress = ValueNotifier<ImportProgress?>(null);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ImportDialog(progress: progress, onCancel: () {}),
    );

    ImportResult result;
    try {
      result = await service.importFiles(
        files,
        onProgress: (v) => progress.value = v,
      );
    } catch (_) {
      result = const ImportResult();
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    refreshAllDays(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.summary),
      duration: const Duration(seconds: 4),
    ));
  }
}

enum _ImportChoice { all, year, pick }

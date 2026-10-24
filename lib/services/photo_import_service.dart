import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nianlun/services/database.dart';
import 'package:nianlun/services/day_repository.dart';
import 'package:nianlun/utils/media_utils.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

/// 导入进度（UI 进度条用）
class ImportProgress {
  final int scanned;
  final int total;
  final int imported;
  final int skipped;

  const ImportProgress({
    required this.scanned,
    required this.total,
    required this.imported,
    required this.skipped,
  });

  double get ratio => total <= 0 ? 0 : (scanned / total).clamp(0.0, 1.0);
}

/// 文件内容签名（抽样 FNV-1a）：长度 + 首/中/尾各 16KB 的哈希。
/// 同一张照片不管被系统相册挑选多少次、缓存路径怎么变，内容签名都一致，
/// 这是跨挑选会话可靠去重的关键（缓存路径 hashCode 每次都会变，靠不住）。
Future<String> fileContentSignature(String path) async {
  try {
    final f = File(path);
    final len = await f.length();
    final raf = await f.open();
    try {
      const n = 16384;
      var hash = 0xcbf29ce484222325;
      Future<void> mixAt(int pos) async {
        if (len <= 0) return;
        raf.setPositionSync(pos.clamp(0, len - 1));
        final chunk = await raf.read(n);
        for (final b in chunk) {
          hash ^= b;
          hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
        }
      }

      await mixAt(0);
      if (len > n * 2) await mixAt(len ~/ 2 - n ~/ 2);
      if (len > n) await mixAt(len - n);
      return '${len}_$hash';
    } finally {
      await raf.close();
    }
  } catch (_) {
    // 读不了就退化为路径签名（至少本批内仍能去重）
    return 'p_${path.hashCode}';
  }
}

class ImportResult {
  final int imported;
  final int skipped;
  final int failed;
  final DateTime? earliest;
  final DateTime? latest;
  final bool permissionDenied;

  const ImportResult({
    this.imported = 0,
    this.skipped = 0,
    this.failed = 0,
    this.earliest,
    this.latest,
    this.permissionDenied = false,
  });

  String get summary {
    final range = (earliest != null && latest != null)
        ? '，${earliest!.year}.${earliest!.month}.${earliest!.day} — ${latest!.year}.${latest!.month}.${latest!.day}'
        : '';
    return '新导入 $imported 张 · 已在库 $skipped 张 · 失败 $failed 张$range';
  }
}

/// 照片导入服务：
/// 1. photo_manager 读取系统相册（需用户授权）
/// 2. 按拍摄时间自动归入「某一天」节点
/// 3. 复制副本进 App 媒体目录（不受系统相册清理影响，备份自包含）
/// 4. 按相册 asset id 去重，可重复导入不会产生重复
class PhotoImportService {
  final AppDatabase _db;
  final DayRepository _repo;
  PhotoImportService(this._db, this._repo);

  /// 请求相册权限
  Future<bool> requestPermission() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  /// 相册里共有多少张图片（不含已导入判断，仅提示用）
  Future<int> countInLibrary({DateTime? since}) async {
    try {
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      if (albums.isEmpty) return 0;
      return await albums.first.assetCountAsync;
    } catch (_) {
      return 0;
    }
  }

  /// 统计指定范围内「尚未导入」的照片数（自定义编排向导用）。
  /// 只读 asset id 与拍摄时间，不取文件/缩略图，比正式导入快得多。
  /// 返回 -1 表示权限被拒绝或读取失败。
  Future<int> countNewPhotos({DateTime? since}) async {
    try {
      if (!await requestPermission()) return -1;
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      if (albums.isEmpty) return 0;
      final album = albums.first;
      final total = await album.assetCountAsync;
      final existing = await _db.allSourceIds();
      var count = 0;
      const pageSize = 500;
      for (var start = 0; start < total; start += pageSize) {
        final end = math.min(start + pageSize, total);
        final batch = await album.getAssetListRange(start: start, end: end);
        for (final asset in batch) {
          if (existing.contains(asset.id)) continue;
          if (since != null && asset.createDateTime.isBefore(since)) continue;
          count++;
        }
      }
      return count;
    } catch (_) {
      return -1;
    }
  }

  /// 全量导入。[since] 非空则只导入该时间之后的照片。
  ///
  /// 性能要点：
  ///  - 去重预热：一次性把全部 sourceId 读进内存 Set，避免每张一次 DB 往返
  ///  - 页内并发 4：复制文件 / 取缩略图都是异步原生操作，重叠执行明显提速
  ///  - 整页一个事务批量插入，避免逐条 autocommit 的 fsync 开销
  Future<ImportResult> importFromLibrary({
    DateTime? since,
    void Function(ImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!await requestPermission()) {
      return const ImportResult(permissionDenied: true);
    }

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (albums.isEmpty) return const ImportResult();

    final album = albums.first;
    final total = await album.assetCountAsync;
    final root = await mediaRoot();
    final existing = await _db.allSourceIds();

    var scanned = 0;
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    DateTime? earliest;
    DateTime? latest;

    const pageSize = 100;
    const concurrency = 4;

    String keyOf(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    // dayId 的 Future 缓存：并发 worker 共享同一次查询，不会重复建行撞 UNIQUE
    final dayIdFutures = <String, Future<int>>{};
    Future<int> dayIdFor(DateTime d) =>
        dayIdFutures.putIfAbsent(keyOf(d), () => _repo.dayIdFor(d));

    void report() => onProgress?.call(ImportProgress(
        scanned: scanned, total: total, imported: imported, skipped: skipped));

    for (var start = 0; start < total; start += pageSize) {
      if (isCancelled?.call() ?? false) break;

      final end = math.min(start + pageSize, total);
      List<AssetEntity> batch;
      try {
        batch = await album.getAssetListRange(start: start, end: end);
      } catch (_) {
        break;
      }

      final rows = <Map<String, Object?>>[];
      final rowSourceIds = <String>[];

      Future<void> handle(AssetEntity asset) async {
        if (existing.contains(asset.id)) {
          skipped++;
          return;
        }
        try {
          final takenAt = asset.createDateTime;
          if (since != null && takenAt.isBefore(since)) {
            skipped++;
            return;
          }

          final file = await asset.originFile;
          if (file == null) {
            failed++;
            return;
          }

          // 归天（同一天复用 dayId，避免重复建行）
          final dayId = await dayIdFor(takenAt);

          // 复制副本进沙盒：media/photos/YYYY-MM/<时间戳>_<assetId>.<ext>
          final dir = Directory(p.join(root.path, 'photos',
              '${takenAt.year}-${takenAt.month.toString().padLeft(2, '0')}'));
          await dir.create(recursive: true);
          var ext = p.extension(file.path);
          if (ext.isEmpty) ext = '.jpg';
          final destPath = p.join(
              dir.path, '${takenAt.millisecondsSinceEpoch}_${asset.id}$ext');
          await file.copy(destPath);

          // 主色（氛围光）从缩略图取样，失败不影响导入
          int? color;
          try {
            final thumb = await asset.thumbnailDataWithSize(
              const ThumbnailSize(48, 48),
              quality: 70,
            );
            if (thumb != null) color = await averageColorFromBytes(thumb);
          } catch (_) {}

          rows.add({
            'day_id': dayId,
            'relative_path': p.relative(destPath, from: root.path),
            'taken_at': takenAt.millisecondsSinceEpoch,
            'dominant_color': color,
            'width': asset.orientatedWidth,
            'height': asset.orientatedHeight,
            'source_id': asset.id,
            'caption': null,
            'sort_order': 0,
          });
          rowSourceIds.add(asset.id);
          if (earliest == null || takenAt.isBefore(earliest!)) {
            earliest = takenAt;
          }
          if (latest == null || takenAt.isAfter(latest!)) {
            latest = takenAt;
          }
        } catch (_) {
          failed++;
        }
      }

      // 页内并发 worker 池：共享游标取任务（Dart 单 isolate，同步段原子）
      var cursor = 0;
      Future<void> worker() async {
        while (cursor < batch.length) {
          if (isCancelled?.call() ?? false) return;
          final asset = batch[cursor++];
          await handle(asset);
          scanned++;
          if (scanned % 4 == 0) report(); // 细粒度进度，不再「停一会 +100」
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);

      // 整页一个事务写入；成功后才把 sourceId 计入已导入集合
      if (rows.isNotEmpty) {
        try {
          await _db.insertPhotosBatch(rows);
          existing.addAll(rowSourceIds);
          imported += rows.length;
        } catch (_) {
          failed += rows.length;
        }
      }
      report();
    }

    return ImportResult(
      imported: imported,
      skipped: skipped,
      failed: failed,
      earliest: earliest,
      latest: latest,
    );
  }

  /// 导入用户手动挑选的一组 AssetEntity（来自相册选择器）
  Future<ImportResult> importAssets(
    List<AssetEntity> assets, {
    void Function(ImportProgress progress)? onProgress,
  }) async {
    if (assets.isEmpty) return const ImportResult();

    final root = await mediaRoot();
    final existing = await _db.allSourceIds();
    var scanned = 0;
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    DateTime? earliest;
    DateTime? latest;
    final dayIdCache = <String, int>{};

    String keyOf(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    for (final asset in assets) {
      scanned++;
      try {
        if (existing.contains(asset.id)) {
          skipped++;
          onProgress?.call(ImportProgress(
            scanned: scanned,
            total: assets.length,
            imported: imported,
            skipped: skipped,
          ));
          continue;
        }

        final takenAt = asset.createDateTime;
        final file = await asset.originFile;
        if (file == null) {
          failed++;
          onProgress?.call(ImportProgress(
            scanned: scanned,
            total: assets.length,
            imported: imported,
            skipped: skipped,
          ));
          continue;
        }

        final key = keyOf(takenAt);
        final dayId = dayIdCache[key] ??= await _repo.dayIdFor(takenAt);

        final dir = Directory(p.join(
            root.path,
            'photos',
            '${takenAt.year}-${takenAt.month.toString().padLeft(2, '0')}'));
        await dir.create(recursive: true);
        var ext = p.extension(file.path);
        if (ext.isEmpty) ext = '.jpg';
        final destPath = p.join(
            dir.path, '${takenAt.millisecondsSinceEpoch}_${asset.id}$ext');
        await file.copy(destPath);

        int? color;
        try {
          final thumb = await asset.thumbnailDataWithSize(
            const ThumbnailSize(48, 48),
            quality: 70,
          );
          if (thumb != null) color = await averageColorFromBytes(thumb);
        } catch (_) {}

        await _db.insertPhoto(
          dayId: dayId,
          relativePath: p.relative(destPath, from: root.path),
          takenAt: takenAt,
          dominantColor: color,
          width: asset.orientatedWidth,
          height: asset.orientatedHeight,
          sourceId: asset.id,
        );
        existing.add(asset.id);

        imported++;
        if (earliest == null || takenAt.isBefore(earliest)) earliest = takenAt;
        if (latest == null || takenAt.isAfter(latest)) latest = takenAt;
      } catch (_) {
        failed++;
      }

      onProgress?.call(ImportProgress(
        scanned: scanned,
        total: assets.length,
        imported: imported,
        skipped: skipped,
      ));
    }

    return ImportResult(
      imported: imported,
      skipped: skipped,
      failed: failed,
      earliest: earliest,
      latest: latest,
    );
  }

  /// 导入用户从系统相册选择器挑出的图片（XFile 列表）。
  /// 优先读取 EXIF 拍摄时间归天；没有 EXIF 时降级用文件修改时间。
  Future<ImportResult> importFiles(
    List<XFile> files, {
    void Function(ImportProgress progress)? onProgress,
  }) async {
    if (files.isEmpty) return const ImportResult();

    final root = await mediaRoot();
    final existing = await _db.allSourceIds();
    var scanned = 0;
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    DateTime? earliest;
    DateTime? latest;
    final dayIdCache = <String, int>{};

    String keyOf(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    for (final xfile in files) {
      scanned++;
      try {
        // 内容签名去重（先于一切落盘/建库操作）：
        // 同一张照片被多次挑选时缓存路径每次都变，路径 hash 去重会失效，
        // 导致同一照片重复入库 → 两条记录的落盘文件名还相同（takenAt+文件名
        // hash 不变）→ 星野贴片 ValueKey(relativePath) 撞键 → 渲染红屏。
        // 内容签名则稳定可靠。
        final sourceId = 'file_${await fileContentSignature(xfile.path)}';
        if (existing.contains(sourceId)) {
          skipped++;
          _reportProgress(onProgress, scanned, files.length, imported, skipped);
          continue;
        }

        final bytes = await xfile.readAsBytes();
        if (bytes.isEmpty) {
          failed++;
          _reportProgress(onProgress, scanned, files.length, imported, skipped);
          continue;
        }

        final takenAt = await _extractTakenAt(xfile.path, bytes);
        final key = keyOf(takenAt);
        final dayId = dayIdCache[key] ??= await _repo.dayIdFor(takenAt);

        final dir = Directory(p.join(
            root.path, 'photos', '${takenAt.year}-${takenAt.month.toString().padLeft(2, '0')}'));
        await dir.create(recursive: true);
        var ext = p.extension(xfile.path).toLowerCase();
        if (ext.isEmpty) ext = '.jpg';
        // 落盘名唯一化：与历史遗留数据/极端撞车场景兜底，绝不覆盖已有文件
        var destPath = p.join(dir.path,
            '${takenAt.millisecondsSinceEpoch}_${sourceId.hashCode}$ext');
        var suffix = 1;
        while (await File(destPath).exists()) {
          suffix++;
          destPath = p.join(dir.path,
              '${takenAt.millisecondsSinceEpoch}_${sourceId.hashCode}_$suffix$ext');
        }
        await File(destPath).writeAsBytes(bytes);

        final meta = await probeImageBytes(bytes);

        await _db.insertPhoto(
          dayId: dayId,
          relativePath: p.relative(destPath, from: root.path),
          takenAt: takenAt,
          dominantColor: meta?.color,
          width: meta?.width,
          height: meta?.height,
          sourceId: sourceId,
        );
        existing.add(sourceId);

        imported++;
        if (earliest == null || takenAt.isBefore(earliest)) earliest = takenAt;
        if (latest == null || takenAt.isAfter(latest)) latest = takenAt;
      } catch (e, st) {
        dev.log('手动导入图片失败', error: e, stackTrace: st);
        failed++;
      }

      _reportProgress(onProgress, scanned, files.length, imported, skipped);
    }

    return ImportResult(
      imported: imported,
      skipped: skipped,
      failed: failed,
      earliest: earliest,
      latest: latest,
    );
  }

  Future<DateTime> _extractTakenAt(String path, Uint8List bytes) async {
    try {
      final exifData = await readExifFromBytes(bytes);
      final raw = exifData['EXIF DateTimeOriginal']?.printable ??
          exifData['Image DateTime']?.printable;
      if (raw != null && raw.length >= 19) {
        // EXIF 日期格式：'2024:09:24 12:00:00'
        final dt = DateTime.tryParse(raw.replaceFirst(':', '-').replaceFirst(':', '-'));
        if (dt != null) return dt;
      }
    } catch (_) {}

    try {
      final modified = File(path).lastModifiedSync();
      if (modified.year >= 1990 && modified.year <= DateTime.now().year) {
        return modified;
      }
    } catch (_) {}

    return DateTime.now();
  }

  void _reportProgress(
    void Function(ImportProgress progress)? onProgress,
    int scanned,
    int total,
    int imported,
    int skipped,
  ) {
    onProgress?.call(ImportProgress(
      scanned: scanned,
      total: total,
      imported: imported,
      skipped: skipped,
    ));
  }
}

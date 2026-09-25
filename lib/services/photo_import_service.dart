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

  /// 全量导入。[since] 非空则只导入该时间之后的照片。
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

    var scanned = 0;
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    DateTime? earliest;
    DateTime? latest;

    const pageSize = 100;
    final dayIdCache = <String, int>{};

    for (var start = 0; start < total; start += pageSize) {
      if (isCancelled?.call() ?? false) break;

      final end = math.min(start + pageSize, total);
      List<AssetEntity> batch;
      try {
        batch = await album.getAssetListRange(start: start, end: end);
      } catch (_) {
        break;
      }

      for (final asset in batch) {
        scanned++;
        try {
          if (await _db.hasSourceId(asset.id)) {
            skipped++;
            continue;
          }
          final takenAt = asset.createDateTime;
          if (since != null && takenAt.isBefore(since)) {
            skipped++;
            continue;
          }

          final file = await asset.originFile;
          if (file == null) {
            failed++;
            continue;
          }

          // 归天（同一天复用 dayId，避免重复建行）
          String keyOf(DateTime d) =>
              '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
          final key = keyOf(takenAt);
          final dayId = dayIdCache[key] ??= await _repo.dayIdFor(takenAt);

          // 复制副本进沙盒：media/photos/YYYY-MM/<时间戳>_<assetId>.<ext>
          final dir = Directory(
              p.join(root.path, 'photos', '${takenAt.year}-${takenAt.month.toString().padLeft(2, '0')}'));
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

          await _db.insertPhoto(
            dayId: dayId,
            relativePath: p.relative(destPath, from: root.path),
            takenAt: takenAt,
            dominantColor: color,
            width: asset.orientatedWidth,
            height: asset.orientatedHeight,
            sourceId: asset.id,
          );

          imported++;
          if (earliest == null || takenAt.isBefore(earliest)) earliest = takenAt;
          if (latest == null || takenAt.isAfter(latest)) latest = takenAt;
        } catch (_) {
          failed++;
        }
      }

      onProgress?.call(ImportProgress(
        scanned: scanned,
        total: total,
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

  /// 导入用户手动挑选的一组 AssetEntity（来自相册选择器）
  Future<ImportResult> importAssets(
    List<AssetEntity> assets, {
    void Function(ImportProgress progress)? onProgress,
  }) async {
    if (assets.isEmpty) return const ImportResult();

    final root = await mediaRoot();
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
        if (await _db.hasSourceId(asset.id)) {
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
        final destPath = p.join(
            dir.path,
            '${takenAt.millisecondsSinceEpoch}_${xfile.name.hashCode}$ext');
        await File(destPath).writeAsBytes(bytes);

        final meta = await probeImageBytes(bytes);

        // sourceId 用文件路径兜底，用于去重（手动选的文件没有相册 asset id）
        final sourceId = 'file_${xfile.path.hashCode}';
        if (await _db.hasSourceId(sourceId)) {
          skipped++;
          _reportProgress(onProgress, scanned, files.length, imported, skipped);
          continue;
        }

        await _db.insertPhoto(
          dayId: dayId,
          relativePath: p.relative(destPath, from: root.path),
          takenAt: takenAt,
          dominantColor: meta?.color,
          width: meta?.width,
          height: meta?.height,
          sourceId: sourceId,
        );

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

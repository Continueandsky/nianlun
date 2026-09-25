import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/services/database.dart';
import 'package:nianlun/services/day_repository.dart';
import 'package:nianlun/utils/media_utils.dart';
import 'package:path/path.dart' as p;

/// 媒体挂载服务：为某一天补照片 / 配一首本地音乐 / 移除
class MediaAttachService {
  final AppDatabase _db;
  final DayRepository _repo;
  MediaAttachService(this._db, this._repo);

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 把选中的图片挂到某天，返回成功数量
  Future<int> attachPhotos(DateTime date, List<PlatformFile> files) async {
    final dayId = await _repo.dayIdFor(date);
    final root = await mediaRoot();
    final dir = Directory(
        p.join(root.path, 'photos', '${date.year}-${_two(date.month)}'));
    await dir.create(recursive: true);

    var count = 0;
    final existing = await _db.photosOfDay(dayId);
    var order = existing.length;

    for (final picked in files) {
      try {
        final bytes = await picked.readAsBytes();
        final meta = await probeImageBytes(bytes);
        final ext = picked.extension ?? 'jpg';
        final destPath = p.join(dir.path,
            'attach_${DateTime.now().microsecondsSinceEpoch}_$count.$ext');
        await File(destPath).writeAsBytes(bytes);

        await _db.insertPhoto(
          dayId: dayId,
          relativePath: p.relative(destPath, from: root.path),
          takenAt: _takenAtFor(date, picked),
          dominantColor: meta?.color,
          width: meta?.width,
          height: meta?.height,
          sortOrder: order++,
        );
        count++;
      } catch (_) {
        // 单张失败不影响其他
      }
    }
    return count;
  }

  /// 给某天配一首本地音乐（同一天只保留一首，覆盖旧的）
  Future<void> attachMusic(DateTime date, PlatformFile picked, {String? title}) async {
    final dayId = await _repo.dayIdFor(date);
    final root = await mediaRoot();
    final dir = Directory(p.join(root.path, 'music'));
    await dir.create(recursive: true);

    final ext = picked.extension ?? 'mp3';
    final destPath = p.join(
        dir.path, 'music_${dayId}_${DateTime.now().millisecondsSinceEpoch}.$ext');
    final srcPath = picked.path;
    if (srcPath != null && File(srcPath).existsSync()) {
      await File(srcPath).copy(destPath);
    } else {
      await File(destPath).writeAsBytes(await picked.readAsBytes());
    }

    // 尝试从文件名拆出「歌手 - 歌名」
    final rawName = title ?? p.basenameWithoutExtension(picked.name);
    String songTitle = rawName;
    String? artist;
    for (final sep in const [' - ', ' – ', ' — ', '-']) {
      if (rawName.contains(sep)) {
        final parts = rawName.split(sep);
        if (parts.length >= 2 && parts[0].trim().isNotEmpty && parts[1].trim().isNotEmpty) {
          artist = parts[0].trim();
          songTitle = parts.sublist(1).join(sep).trim();
          break;
        }
      }
    }

    await _db.upsertMusic(
      dayId: dayId,
      relativePath: p.relative(destPath, from: root.path),
      title: songTitle,
      artist: artist,
    );
  }

  /// 移除某天的音乐（连副本一起删）
  Future<void> removeMusic(DateTime date) async {
    final row = await _db.dayRow(date);
    if (row == null) return;
    final dayId = row['id'] as int;
    final music = await _db.musicOfDay(dayId);
    if (music == null) return;
    try {
      final file = await mediaFile(music['relative_path'] as String);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    await _db.deleteMusic(dayId);
  }

  /// 从「年轮」移除一张照片（只删 App 内副本，不动系统相册）
  Future<void> removePhoto(PhotoItem photo) async {
    if (photo.id == null) return;
    try {
      final file = await mediaFile(photo.relativePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    await _db.deletePhoto(photo.id!);
  }

  /// 改照片题注
  Future<void> setCaption(PhotoItem photo, String? caption) async {
    if (photo.id == null) return;
    await _db.setCaption(photo.id!, caption);
  }

  /// 照片的拍摄时间：若文件修改时间正好在目标那天则采用，否则用中午 12 点兜底
  DateTime _takenAtFor(DateTime day, PlatformFile picked) {
    final path = picked.path;
    if (path != null) {
      try {
        final modified = File(path).lastModifiedSync();
        if (modified.year == day.year &&
            modified.month == day.month &&
            modified.day == day.day) {
          return modified;
        }
      } catch (_) {}
    }
    return DateTime(day.year, day.month, day.day, 12);
  }
}

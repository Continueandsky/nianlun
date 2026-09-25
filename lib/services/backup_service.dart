import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:nianlun/services/database.dart';
import 'package:nianlun/utils/media_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 备份系统：一键导出 / 导入 `.nianlun` 备份包（zip 容器）
///   ├─ nianlun.db        SQLite 数据库
///   └─ media/            全部照片 + 音乐副本
class BackupService {
  final AppDatabase _db;
  BackupService(this._db);

  static String _two(int n) => n.toString().padLeft(2, '0');

  String defaultFileName() {
    final now = DateTime.now();
    return 'nianlun_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}.nianlun';
  }

  /// 导出到系统临时目录，返回文件（UI 再决定「另存为」到哪）
  Future<File> exportToTemp() async {
    final dir = await getTemporaryDirectory();
    return exportTo(File(p.join(dir.path, defaultFileName())));
  }

  /// 导出：数据库 + 全部媒体副本 → 单个 .nianlun 文件
  Future<File> exportTo(File target) async {
    await (await _db.db).close();
    _db.reset();

    try {
      final dbsPath = await getDatabasesPath();
      final dbFile = File(p.join(dbsPath, 'nianlun.db'));
      final media = await mediaRoot();

      await target.parent.create(recursive: true);
      final encoder = ZipFileEncoder()..create(target.path);
      if (await dbFile.exists()) {
        await encoder.addFile(dbFile, 'nianlun.db');
      }
      if (await media.exists()) {
        // media 目录 basename 即 'media'，默认 includeDirName=true → 包内路径 'media/...'
        await encoder.addDirectory(media);
      }
      await encoder.close();
      return target;
    } finally {
      // 无论成败都重开数据库，App 可继续使用
      await _db.db;
    }
  }

  /// 从 .nianlun 备份包完整恢复（覆盖同名数据）
  Future<void> importFrom(String backupPath) async {
    await (await _db.db).close();
    _db.reset();

    try {
      final bytes = await File(backupPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final dbsPath = await getDatabasesPath();
      final media = await mediaRoot();

      for (final file in archive.files) {
        if (!file.isFile) continue;
        final name = file.name;
        final target = name.startsWith('media/')
            ? File(p.join(media.path, name.substring('media/'.length)))
            : File(p.join(dbsPath, name));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(file.content as List<int>);
      }
    } finally {
      await _db.db;
    }
  }

  /// 备份概况（UI 提示用）
  Future<Map<String, int>> stats() async {
    final db = await _db.db;
    Future<int> count(String table) async {
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      return (rows.first['c'] as int?) ?? 0;
    }

    var mediaBytes = 0;
    try {
      final media = await mediaRoot();
      await for (final entity in media.list(recursive: true)) {
        if (entity is File) {
          mediaBytes += await entity.length();
        }
      }
    } catch (_) {}

    return {
      'days': await count('days'),
      'photos': await count('photos'),
      'journals': await count('journals'),
      'music': await count('music'),
      'mediaBytes': mediaBytes,
    };
  }
}

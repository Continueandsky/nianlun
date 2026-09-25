import 'dart:io';

import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/services/database.dart';
import 'package:nianlun/utils/media_utils.dart';

/// 仓库层：把数据库行装配成对 UI 友好的模型
class DayRepository {
  final AppDatabase _db;
  DayRepository(this._db);

  static DateTime normalize(DateTime d) => DateTime(d.year, d.month, d.day);

  /// 某天的完整节点（不存在则返回空节点，id 为 null）
  Future<DayEntry> entryFor(DateTime date) async {
    final normalized = normalize(date);
    final row = await _db.dayRow(normalized);
    if (row == null) {
      final now = DateTime.now();
      return DayEntry(date: normalized, createdAt: now, updatedAt: now);
    }
    final dayId = row['id'] as int;
    final photoRows = await _db.photosOfDay(dayId);
    final journalRows = await _db.journalsOfDay(dayId);
    final musicRow = await _db.musicOfDay(dayId);
    return DayEntry.fromMap(
      row,
      photos: photoRows.map(PhotoItem.fromMap).toList(),
      journals: journalRows.map(JournalEntry.fromMap).toList(),
      music: musicRow == null ? null : MusicTrack.fromMap(musicRow),
    );
  }

  /// 全部有内容的日子（首页瀑布流 + 日历共用）
  Future<List<DaySummary>> allSummaries() async {
    final dayRows = await _db.daysWithCounts();
    final photoRows = await _db.allPhotosWithDate();

    final photosByDate = <String, List<PhotoItem>>{};
    for (final row in photoRows) {
      final key = row['day_date'] as String;
      photosByDate.putIfAbsent(key, () => <PhotoItem>[]).add(PhotoItem.fromMap(row));
    }

    return dayRows.map((r) {
      final key = r['date'] as String;
      final moodIndex = r['mood'] as int?;
      return DaySummary(
        date: DateTime.parse(key),
        mood: moodIndex == null ? null : Mood.values[moodIndex],
        journalCount: (r['journal_count'] as int?) ?? 0,
        hasMusic: ((r['music_count'] as int?) ?? 0) > 0,
        photos: photosByDate[key] ?? const <PhotoItem>[],
      );
    }).toList();
  }

  /// 第一个有记录的日子（用来算「第 N 个日子」）
  Future<DateTime?> firstDay() async {
    final db = await _db.db;
    final rows = await db.rawQuery('SELECT MIN(date) AS first FROM days');
    final value = rows.isEmpty ? null : rows.first['first'] as String?;
    return value == null ? null : DateTime.parse(value);
  }

  /// 取得某天的 day id（不存在则创建）—— 写日记/挂照片/配乐前调用
  Future<int> dayIdFor(DateTime date) => _db.getOrCreateDay(normalize(date));

  /// 照片绝对路径
  Future<File> photoFile(PhotoItem photo) => mediaFile(photo.relativePath);

  /// 音乐绝对路径
  Future<File> musicFile(MusicTrack track) => mediaFile(track.relativePath);
}

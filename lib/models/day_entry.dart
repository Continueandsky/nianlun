import 'dart:ui';

/// 「年轮」核心数据模型：一切以「某一天」为节点
/// DayEntry = 日记(可多篇) + 照片(0..n) + 音乐(0..1) + 心情

class JournalEntry {
  final int? id;
  final int dayId;
  final String contentJson; // 富文本(Quill Delta JSON)
  final DateTime createdAt;
  final DateTime updatedAt;

  JournalEntry({
    this.id,
    required this.dayId,
    required this.contentJson,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'day_id': dayId,
        'content_json': contentJson,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory JournalEntry.fromMap(Map<String, dynamic> m) => JournalEntry(
        id: m['id'] as int?,
        dayId: m['day_id'] as int,
        contentJson: m['content_json'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
}

class PhotoItem {
  final int? id;
  final int dayId;
  final String relativePath; // 相对 App 媒体目录的路径（备份时保证可迁移）
  final DateTime takenAt; // EXIF 拍摄时间
  final int? dominantColor; // 主色调（时间轴氛围光 & 渲染用）
  final int? width; // 原始宽（瀑布流比例）
  final int? height; // 原始高
  final String? sourceId; // 来源相册 asset id（导入去重用）
  final String? caption; // 照片题注（如「汉江边的傍晚」）
  final int sortOrder;

  PhotoItem({
    this.id,
    required this.dayId,
    required this.relativePath,
    required this.takenAt,
    this.dominantColor,
    this.width,
    this.height,
    this.sourceId,
    this.caption,
    this.sortOrder = 0,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'day_id': dayId,
        'relative_path': relativePath,
        'taken_at': takenAt.millisecondsSinceEpoch,
        'dominant_color': dominantColor,
        'width': width,
        'height': height,
        'source_id': sourceId,
        'caption': caption,
        'sort_order': sortOrder,
      };

  factory PhotoItem.fromMap(Map<String, dynamic> m) => PhotoItem(
        id: m['id'] as int?,
        dayId: m['day_id'] as int,
        relativePath: m['relative_path'] as String,
        takenAt: DateTime.fromMillisecondsSinceEpoch(m['taken_at'] as int),
        dominantColor: m['dominant_color'] as int?,
        width: m['width'] as int?,
        height: m['height'] as int?,
        sourceId: m['source_id'] as String?,
        caption: m['caption'] as String?,
        sortOrder: m['sort_order'] as int? ?? 0,
      );

  Color? get color => dominantColor == null ? null : Color(dominantColor!);

  /// 宽高比（缺省按 3:4 竖构图，最像手机拍照）
  double get aspectRatio {
    final w = width, h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return 3 / 4;
    return w / h;
  }
}

class MusicTrack {
  final int? id;
  final int dayId;
  final String relativePath; // 本地音频文件（App 媒体目录内副本）
  final String title; // 歌名
  final String? artist;
  final String? externalUrl; // 酷狗等外链（仅记录跳转，不在应用内播放）

  MusicTrack({
    this.id,
    required this.dayId,
    required this.relativePath,
    required this.title,
    this.artist,
    this.externalUrl,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'day_id': dayId,
        'relative_path': relativePath,
        'title': title,
        'artist': artist,
        'external_url': externalUrl,
      };

  factory MusicTrack.fromMap(Map<String, dynamic> m) => MusicTrack(
        id: m['id'] as int?,
        dayId: m['day_id'] as int,
        relativePath: m['relative_path'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String?,
        externalUrl: m['external_url'] as String?,
      );
}

enum Mood { calm, happy, low, excited, tired }

extension MoodX on Mood {
  String get label => switch (this) {
        Mood.calm => '平静',
        Mood.happy => '开心',
        Mood.low => '低落',
        Mood.excited => '兴奋',
        Mood.tired => '疲惫',
      };

  /// 日历/日历星星上的心情色
  Color get color => switch (this) {
        Mood.calm => const Color(0xFFAFA9EC),
        Mood.happy => const Color(0xFFF2CF9A),
        Mood.low => const Color(0xFF7C8BB5),
        Mood.excited => const Color(0xFFF0A9C0),
        Mood.tired => const Color(0xFF9FA8C8),
      };
}

class DayEntry {
  final int? id;
  final DateTime date; // 唯一键（日期，忽略时分秒）
  final Mood? mood;
  final DateTime createdAt;
  final DateTime updatedAt;

  final List<JournalEntry> journals;
  final List<PhotoItem> photos;
  final MusicTrack? music;

  DayEntry({
    this.id,
    required this.date,
    this.mood,
    required this.createdAt,
    required this.updatedAt,
    this.journals = const [],
    this.photos = const [],
    this.music,
  });

  /// 节点是否有内容（照片/日记/音乐任一）
  bool get hasContent =>
      photos.isNotEmpty || journals.isNotEmpty || music != null;

  String get dateKey =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'date': dateKey,
        'mood': mood?.index,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory DayEntry.fromMap(
    Map<String, dynamic> m, {
    List<JournalEntry> journals = const [],
    List<PhotoItem> photos = const [],
    MusicTrack? music,
  }) =>
      DayEntry(
        id: m['id'] as int?,
        date: DateTime.parse(m['date'] as String),
        mood: m['mood'] == null ? null : Mood.values[m['mood'] as int],
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
        journals: journals,
        photos: photos,
        music: music,
      );
}

/// 轻量「天」摘要：首页瀑布流 / 日历 只需这些，不必装配完整节点
class DaySummary {
  final DateTime date;
  final Mood? mood;
  final int journalCount;
  final bool hasMusic;
  final List<PhotoItem> photos;

  const DaySummary({
    required this.date,
    this.mood,
    this.journalCount = 0,
    this.hasMusic = false,
    this.photos = const [],
  });

  bool get hasPhotos => photos.isNotEmpty;
  bool get hasContent => photos.isNotEmpty || journalCount > 0 || hasMusic;
  int get photoCount => photos.length;

  /// 当天主色（取当天第一张照片，用于氛围渐变）
  int? get coverColor =>
      photos.isEmpty ? null : photos.first.dominantColor;
}

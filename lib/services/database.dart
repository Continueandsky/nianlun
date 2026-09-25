import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 「年轮」数据库：SQLite，纯本地
/// 表结构：days(节点) / journals(日记) / photos(照片) / music(音乐)
class AppDatabase {
  static const _dbName = 'nianlun.db';
  static const _dbVersion = 2;

  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbsPath = await getDatabasesPath();
    return openDatabase(
      p.join(dbsPath, _dbName),
      version: _dbVersion,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE days (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT UNIQUE NOT NULL,
            mood INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE journals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_id INTEGER NOT NULL REFERENCES days(id) ON DELETE CASCADE,
            content_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_id INTEGER NOT NULL REFERENCES days(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            taken_at INTEGER NOT NULL,
            dominant_color INTEGER,
            width INTEGER,
            height INTEGER,
            source_id TEXT,
            caption TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE music (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_id INTEGER UNIQUE NOT NULL REFERENCES days(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT,
            external_url TEXT
          )
        ''');
        await _createIndexes(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          // v1 → v2：照片补「来源 id / 宽高」，用于导入去重与瀑布流比例
          await db.execute('ALTER TABLE photos ADD COLUMN width INTEGER');
          await db.execute('ALTER TABLE photos ADD COLUMN height INTEGER');
          await db.execute('ALTER TABLE photos ADD COLUMN source_id TEXT');
          await db.execute(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_photos_source ON photos(source_id)');
        }
      },
    );
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_photos_day ON photos(day_id, taken_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_journals_day ON journals(day_id)');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_photos_source ON photos(source_id)');
  }

  // ───────────────────────── 天（节点） ─────────────────────────

  String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// 取某天节点行（不存在返回 null）
  Future<Map<String, dynamic>?> dayRow(DateTime date) async {
    final database = await db;
    final rows = await database
        .query('days', where: 'date = ?', whereArgs: [_dateKey(date)], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 取得或创建某天的节点，返回 day id
  Future<int> getOrCreateDay(DateTime date) async {
    final database = await db;
    final key = _dateKey(date);
    final rows =
        await database.query('days', where: 'date = ?', whereArgs: [key], limit: 1);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    return database.insert('days', {'date': key, 'created_at': now, 'updated_at': now});
  }

  /// 全部「有内容」的日子（含各表计数），倒序 —— 首页与日历共用
  Future<List<Map<String, dynamic>>> daysWithCounts() async {
    final database = await db;
    return database.rawQuery('''
      SELECT d.id, d.date, d.mood, d.updated_at,
        (SELECT COUNT(*) FROM photos p WHERE p.day_id = d.id) AS photo_count,
        (SELECT COUNT(*) FROM journals j WHERE j.day_id = d.id) AS journal_count,
        (SELECT COUNT(*) FROM music m WHERE m.day_id = d.id) AS music_count
      FROM days d
      WHERE d.mood IS NOT NULL
         OR (SELECT COUNT(*) FROM photos p WHERE p.day_id = d.id) > 0
         OR (SELECT COUNT(*) FROM journals j WHERE j.day_id = d.id) > 0
         OR (SELECT COUNT(*) FROM music m WHERE m.day_id = d.id) > 0
      ORDER BY d.date DESC
    ''');
  }

  /// 全部照片（带所属日期），倒序（首页瀑布流一次取完）
  Future<List<Map<String, dynamic>>> allPhotosWithDate() async {
    final database = await db;
    return database.rawQuery('''
      SELECT p.*, d.date AS day_date
      FROM photos p JOIN days d ON d.id = p.day_id
      ORDER BY d.date DESC, p.taken_at ASC, p.id ASC
    ''');
  }

  Future<void> setMood(int dayId, int? mood) async {
    final database = await db;
    await database.update(
      'days',
      {'mood': mood, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [dayId],
    );
  }

  Future<void> touchDay(int dayId) async {
    final database = await db;
    await database.update(
      'days',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [dayId],
    );
  }

  // ───────────────────────── 日记 ─────────────────────────

  Future<List<Map<String, dynamic>>> journalsOfDay(int dayId) async {
    final database = await db;
    return database
        .query('journals', where: 'day_id = ?', whereArgs: [dayId], orderBy: 'created_at ASC');
  }

  Future<int> insertJournal({
    required int dayId,
    required String contentJson,
    int? createdAt,
  }) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await database.insert('journals', {
      'day_id': dayId,
      'content_json': contentJson,
      'created_at': createdAt ?? now,
      'updated_at': now,
    });
    await touchDay(dayId);
    return id;
  }

  Future<void> updateJournal(int id, String contentJson) async {
    final database = await db;
    await database.update(
      'journals',
      {'content_json': contentJson, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteJournal(int id) async {
    final database = await db;
    await database.delete('journals', where: 'id = ?', whereArgs: [id]);
  }

  // ───────────────────────── 照片 ─────────────────────────

  Future<List<Map<String, dynamic>>> photosOfDay(int dayId) async {
    final database = await db;
    return database.query('photos',
        where: 'day_id = ?',
        whereArgs: [dayId],
        orderBy: 'taken_at ASC, sort_order ASC, id ASC');
  }

  /// 该来源 id 是否已导入（去重）
  Future<bool> hasSourceId(String sourceId) async {
    final database = await db;
    final rows = await database.query('photos',
        columns: ['id'], where: 'source_id = ?', whereArgs: [sourceId], limit: 1);
    return rows.isNotEmpty;
  }

  Future<int> insertPhoto({
    required int dayId,
    required String relativePath,
    required DateTime takenAt,
    int? dominantColor,
    int? width,
    int? height,
    String? sourceId,
    String? caption,
    int sortOrder = 0,
  }) async {
    final database = await db;
    return database.insert('photos', {
      'day_id': dayId,
      'relative_path': relativePath,
      'taken_at': takenAt.millisecondsSinceEpoch,
      'dominant_color': dominantColor,
      'width': width,
      'height': height,
      'source_id': sourceId,
      'caption': caption,
      'sort_order': sortOrder,
    });
  }

  Future<void> deletePhoto(int id) async {
    final database = await db;
    await database.delete('photos', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setCaption(int id, String? caption) async {
    final database = await db;
    await database
        .update('photos', {'caption': caption}, where: 'id = ?', whereArgs: [id]);
  }

  // ───────────────────────── 音乐 ─────────────────────────

  Future<Map<String, dynamic>?> musicOfDay(int dayId) async {
    final database = await db;
    final rows =
        await database.query('music', where: 'day_id = ?', whereArgs: [dayId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 每天至多一首：存在则覆盖
  Future<void> upsertMusic({
    required int dayId,
    required String relativePath,
    required String title,
    String? artist,
    String? externalUrl,
  }) async {
    final database = await db;
    await database.delete('music', where: 'day_id = ?', whereArgs: [dayId]);
    await database.insert('music', {
      'day_id': dayId,
      'relative_path': relativePath,
      'title': title,
      'artist': artist,
      'external_url': externalUrl,
    });
    await touchDay(dayId);
  }

  Future<void> deleteMusic(int dayId) async {
    final database = await db;
    await database.delete('music', where: 'day_id = ?', whereArgs: [dayId]);
  }

  // ───────────────────────── 维护 ─────────────────────────

  /// 关闭连接（备份导出前调用，导出后会自动重开）
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// 将缓存的实例置空（close 之后强制下次重开）
  void reset() => _db = null;
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/services/audio_service.dart';
import 'package:nianlun/services/backup_service.dart';
import 'package:nianlun/services/database.dart';
import 'package:nianlun/services/day_repository.dart';
import 'package:nianlun/services/media_attach_service.dart';
import 'package:nianlun/services/photo_import_service.dart';
import 'package:nianlun/utils/media_utils.dart';

/// 媒体根目录绝对路径（拼照片/音乐的完整路径用）
final mediaRootPathProvider = FutureProvider<String>(
  (ref) async => (await mediaRoot()).path,
);

/// 全局唯一数据库
final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final dayRepositoryProvider = Provider<DayRepository>(
  (ref) => DayRepository(ref.watch(dbProvider)),
);

/// 全部有内容的日子（首页 / 日历）
final daysProvider = FutureProvider<List<DaySummary>>(
  (ref) => ref.watch(dayRepositoryProvider).allSummaries(),
);

/// 某天的完整节点（节点页）
final dayEntryProvider = FutureProvider.family<DayEntry, DateTime>(
  (ref, date) =>
      ref.watch(dayRepositoryProvider).entryFor(DayRepository.normalize(date)),
);

final photoImportServiceProvider = Provider<PhotoImportService>(
  (ref) => PhotoImportService(ref.watch(dbProvider), ref.watch(dayRepositoryProvider)),
);

final mediaAttachServiceProvider = Provider<MediaAttachService>(
  (ref) => MediaAttachService(ref.watch(dbProvider), ref.watch(dayRepositoryProvider)),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(dbProvider)),
);

final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  ref.onDispose(service.dispose);
  return service;
});

/// 数据变更后刷新相关页面（写完日记 / 导入照片 / 换歌之后调用）
void refreshAllDays(WidgetRef ref) {
  ref.invalidate(daysProvider);
  ref.invalidate(dayEntryProvider);
}

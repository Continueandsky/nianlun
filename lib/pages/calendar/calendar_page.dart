import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/pages/node/node_page.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/theme/starry_theme.dart';
import 'package:path/path.dart' as p;

/// Tab 2「日历」：月视图
/// 有内容的日子：底色是当天第一张照片的微缩 + 心情星星；点开 → 那一天
class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  late DateTime _visible; // 当月（取 1 号）

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visible = DateTime(now.year, now.month, 1);
  }

  void _shiftMonth(int delta) {
    setState(() => _visible = DateTime(_visible.year, _visible.month + delta, 1));
  }

  @override
  Widget build(BuildContext context) {
    final daysAsync = ref.watch(daysProvider);
    final rootAsync = ref.watch(mediaRootPathProvider);

    return SafeArea(
      bottom: false,
      child: daysAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: StarryTheme.starPurple)),
        error: (e, _) => Center(
          child: Text('读取失败：$e',
              style: const TextStyle(color: StarryTheme.starDim, fontSize: 13)),
        ),
        data: (days) => rootAsync.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: StarryTheme.starPurple)),
          error: (e, _) => const SizedBox.shrink(),
          data: (rootPath) => _buildCalendar(days, rootPath),
        ),
      ),
    );
  }

  Widget _buildCalendar(List<DaySummary> days, String rootPath) {
    final byDate = <String, DaySummary>{};
    for (final d in days) {
      byDate[_key(d.date)] = d;
    }

    final firstOfMonth = _visible;
    final daysInMonth = DateTime(firstOfMonth.year, firstOfMonth.month + 1, 0).day;
    final leading = firstOfMonth.weekday - 1; // 周一为第一列
    final totalCells = leading + daysInMonth;
    final rows = (totalCells + 6) ~/ 7;

    final monthSummaries = days
        .where((d) =>
            d.date.year == firstOfMonth.year && d.date.month == firstOfMonth.month)
        .toList();
    final monthPhotos =
        monthSummaries.fold<int>(0, (sum, d) => sum + d.photoCount);
    final monthDays = monthSummaries.where((d) => d.hasContent).length;

    final now = DateTime.now();
    final isThisMonth = now.year == firstOfMonth.year && now.month == firstOfMonth.month;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          _weekdayRow(),
          const SizedBox(height: 4),
          for (var row = 0; row < rows; row++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: _cell(
                        index: row * 7 + col,
                        leading: leading,
                        daysInMonth: daysInMonth,
                        byDate: byDate,
                        rootPath: rootPath,
                        isThisMonth: isThisMonth,
                        now: now,
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              monthDays == 0
                  ? '这个月还没有留下痕迹'
                  : '本月 $monthDays 个日子 · $monthPhotos 张照片',
              style: const TextStyle(fontSize: 12, color: StarryTheme.starDim),
            ),
          ),
          const SizedBox(height: 10),
          const Center(
            child: Text('点开某一天，翻开那一天的故事',
                style: TextStyle(fontSize: 11, color: StarryTheme.starDim)),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final now = DateTime.now();
    final isThisMonth =
        now.year == _visible.year && now.month == _visible.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('日历',
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                  color: StarryTheme.starLight)),
          const SizedBox(height: 12),
          Row(
            children: [
              _roundBtn(Icons.chevron_left, () => _shiftMonth(-1)),
              const SizedBox(width: 4),
              Text('${_visible.year} 年 ${_visible.month} 月',
                  style: const TextStyle(
                      fontSize: 16,
                      color: StarryTheme.starLight,
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 4),
              _roundBtn(Icons.chevron_right, () => _shiftMonth(1)),
              const Spacer(),
              if (!isThisMonth)
                TextButton(
                  onPressed: () => setState(
                      () => _visible = DateTime(now.year, now.month, 1)),
                  child: const Text('回到今天',
                      style: TextStyle(
                          fontSize: 12, color: StarryTheme.starDim)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap) {
    return IconButton(
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: StarryTheme.starDim),
      onPressed: onTap,
    );
  }

  Widget _weekdayRow() {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          for (final l in labels)
            Expanded(
              child: Center(
                child: Text(l,
                    style: const TextStyle(
                        fontSize: 11, color: StarryTheme.starDim)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell({
    required int index,
    required int leading,
    required int daysInMonth,
    required Map<String, DaySummary> byDate,
    required String rootPath,
    required bool isThisMonth,
    required DateTime now,
  }) {
    final dayNumber = index - leading + 1;
    if (dayNumber < 1 || dayNumber > daysInMonth) {
      return const SizedBox(height: 54);
    }
    final date = DateTime(_visible.year, _visible.month, dayNumber);
    final summary = byDate[_key(date)];
    final hasContent = summary?.hasContent ?? false;
    final cover = summary != null && summary.photos.isNotEmpty
        ? summary.photos.first
        : null;
    final isToday = isThisMonth && dayNumber == now.day;

    return Padding(
      padding: const EdgeInsets.all(2),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => NodePage(date: date),
        )),
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isToday
                  ? StarryTheme.starPurple
                  : (hasContent ? const Color(0xFF2E3560) : Colors.transparent),
              width: isToday ? 1.6 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 有照片的日子：底色铺当天第一张照片
                if (cover != null)
                  ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      StarryTheme.deepSpace.withValues(alpha: 0.45),
                      BlendMode.srcATop,
                    ),
                    child: Image.file(
                      File(p.join(rootPath, cover.relativePath)),
                      fit: BoxFit.cover,
                      cacheWidth: 160,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  )
                else if (hasContent)
                  Container(color: StarryTheme.nebula.withValues(alpha: 0.7)),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$dayNumber',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: hasContent ? FontWeight.w600 : FontWeight.w400,
                        color: hasContent
                            ? StarryTheme.starLight
                            : StarryTheme.starDim.withValues(alpha: 0.75),
                      ),
                    ),
                    if (hasContent) ...[
                      const SizedBox(height: 3),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            summary!.mood != null
                                ? Icons.star_rounded
                                : Icons.circle,
                            size: summary.mood != null ? 9 : 5,
                            color: summary.mood?.color ?? StarryTheme.starPurple,
                          ),
                          if (summary.journalCount > 0) ...[
                            const SizedBox(width: 3),
                            const Icon(Icons.edit_note_rounded,
                                size: 10, color: StarryTheme.warmGlow),
                          ],
                          if (summary.hasMusic) ...[
                            const SizedBox(width: 3),
                            const Icon(Icons.music_note_rounded,
                                size: 9, color: StarryTheme.starPurple),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

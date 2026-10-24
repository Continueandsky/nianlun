import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nianlun/pages/calendar/calendar_page.dart';
import 'package:nianlun/pages/editor/journal_editor_page.dart';
import 'package:nianlun/pages/home/star_river_page.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/theme/starry_theme.dart';
import 'package:nianlun/widgets/starry_background.dart';

void main() {
  runApp(const ProviderScope(child: NianlunApp()));
}

class NianlunApp extends StatelessWidget {
  const NianlunApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '年轮',
      debugShowCheckedModeBanner: false,
      theme: StarryTheme.dark,
      localizationsDelegates: const [
        FlutterQuillLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      locale: const Locale('zh', 'CN'),
      home: const HomeShell(),
    );
  }
}

/// 首页：底部双 Tab —— 星河（照片流）/ 日历，右下角写今天的日记
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  /// 星河专注态：true 时底部 Tab 栏与 FAB 动画降下隐藏
  final ValueNotifier<bool> _starFocusMode = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _applyOrientation(0);
  }

  /// 方向策略：只有「星河」tab 允许横屏（横屏进入纯净观星模式），
  /// 其余 tab 一律锁定竖屏。切 tab 时调用。
  void _applyOrientation(int index) {
    if (index == 0) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  @override
  void dispose() {
    _starFocusMode.dispose();
    super.dispose();
  }

  Future<void> _writeToday() async {
    // 日记编辑器不成熟于横屏：进入前锁竖屏，返回后按当前 tab 恢复
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JournalEditorPage(date: DateTime.now()),
    ));
    if (!mounted) return;
    _applyOrientation(_index);
    refreshAllDays(ref);
  }

  @override
  Widget build(BuildContext context) {
    // 星河 tab 横屏 = 纯净观星模式：底部 Tab 栏与 FAB 一并退场
    final landscapeStar = _index == 0 &&
        MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      extendBody: true,
      body: StarryBackground(
        child: IndexedStack(
          index: _index,
          children: [
            StarRiverPage(focusMode: _starFocusMode),
            const CalendarPage(),
          ],
        ),
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _starFocusMode,
        builder: (context, hidden, child) {
          final hide = hidden || landscapeStar;
          return AnimatedScale(
            scale: hide ? 0 : 1,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: hide ? 0 : 1,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: hide,
                child: child,
              ),
            ),
          );
        },
        child: FloatingActionButton(
          onPressed: _writeToday,
          backgroundColor: StarryTheme.starPurple,
          foregroundColor: StarryTheme.deepSpace,
          tooltip: '写今天的日记',
          child: const Icon(Icons.edit_note),
        ),
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: _starFocusMode,
        builder: (context, hidden, child) {
          final hide = hidden || landscapeStar;
          return AnimatedSlide(
            offset: Offset(0, hide ? 1.3 : 0),
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: hide ? 0 : 1,
              duration: const Duration(milliseconds: 260),
              child: IgnorePointer(
                ignoring: hide,
                child: child,
              ),
            ),
          );
        },
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: StarryTheme.nebula.withValues(alpha: 0.94),
            indicatorColor: StarryTheme.starPurple.withValues(alpha: 0.25),
            labelTextStyle: const WidgetStatePropertyAll(
              TextStyle(fontSize: 12, color: StarryTheme.starDim),
            ),
          ),
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) {
              setState(() => _index = i);
              _applyOrientation(i);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined),
                selectedIcon:
                    Icon(Icons.auto_awesome, color: StarryTheme.starPurple),
                label: '星河',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon:
                    Icon(Icons.calendar_month, color: StarryTheme.starPurple),
                label: '日历',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

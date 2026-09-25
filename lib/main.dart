import 'package:flutter/material.dart';
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

  Future<void> _writeToday() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JournalEditorPage(date: DateTime.now()),
    ));
    refreshAllDays(ref);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: StarryBackground(
        child: IndexedStack(
          index: _index,
          children: const [StarRiverPage(), CalendarPage()],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _writeToday,
        backgroundColor: StarryTheme.starPurple,
        foregroundColor: StarryTheme.deepSpace,
        tooltip: '写今天的日记',
        child: const Icon(Icons.edit_note),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: StarryTheme.nebula.withValues(alpha: 0.94),
          indicatorColor: StarryTheme.starPurple.withValues(alpha: 0.25),
          labelTextStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 12, color: StarryTheme.starDim),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined),
              selectedIcon: Icon(Icons.auto_awesome, color: StarryTheme.starPurple),
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
    );
  }
}

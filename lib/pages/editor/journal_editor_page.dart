import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/theme/starry_theme.dart';
import 'package:nianlun/utils/delta_utils.dart';

/// 日记编辑器：富文本（flutter_quill）+ 心情标记
/// [journal] 为空 = 新写一篇（一天可以有多篇）
class JournalEditorPage extends ConsumerStatefulWidget {
  final DateTime date;
  final JournalEntry? journal;

  const JournalEditorPage({super.key, required this.date, this.journal});

  @override
  ConsumerState<JournalEditorPage> createState() => _JournalEditorPageState();
}

class _JournalEditorPageState extends ConsumerState<JournalEditorPage> {
  late final QuillController _controller;
  final FocusNode _focusNode = FocusNode();
  Mood? _mood;
  bool _saving = false;

  /// 字数用 ValueNotifier 单独驱动，避免每敲一个字就重建整页
  final ValueNotifier<int> _charCount = ValueNotifier<int>(0);

  static const _moodIcons = {
    Mood.calm: (Icons.nights_stay_outlined, '平静'),
    Mood.happy: (Icons.wb_sunny_outlined, '开心'),
    Mood.low: (Icons.water_outlined, '低落'),
    Mood.excited: (Icons.bolt_outlined, '兴奋'),
    Mood.tired: (Icons.bedtime_outlined, '疲惫'),
  };

  @override
  void initState() {
    super.initState();
    _controller = widget.journal == null
        ? QuillController.basic()
        : buildEditableController(widget.journal!.contentJson);
    _controller.addListener(_onChanged);
    _loadMood();
  }

  void _onChanged() {
    final count = _controller.document.toPlainText().trim().length;
    if (count != _charCount.value) {
      _charCount.value = count;
    }
  }

  Future<void> _loadMood() async {
    final entry = await ref.read(dayRepositoryProvider).entryFor(widget.date);
    if (!mounted) return;
    setState(() => _mood = entry.mood);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    _charCount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    final repo = ref.read(dayRepositoryProvider);
    final db = ref.read(dbProvider);
    final dayId = await repo.dayIdFor(widget.date);

    final blank = isDocumentBlank(_controller);
    final existing = widget.journal;

    if (existing == null) {
      if (!blank) {
        await db.insertJournal(
            dayId: dayId, contentJson: encodeDocument(_controller));
      }
    } else {
      await db.updateJournal(existing.id!, encodeDocument(_controller));
    }
    await db.setMood(dayId, _mood?.index);

    refreshAllDays(ref);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        existing == null
            ? (blank ? '心情已记下' : '这一篇日记已收进年轮')
            : '已保存修改',
      ),
    ));
  }

  Future<void> _delete() async {
    final journal = widget.journal;
    if (journal == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StarryTheme.nebula,
        title: const Text('删除这一篇日记？',
            style: TextStyle(fontSize: 16, color: StarryTheme.starLight)),
        content: const Text('删除后无法恢复。',
            style: TextStyle(fontSize: 13, color: StarryTheme.starDim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: StarryTheme.starDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: StarryTheme.starPurple)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(dbProvider).deleteJournal(journal.id!);
    refreshAllDays(ref);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.date;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: StarryTheme.deepSpace,
      appBar: AppBar(
        title: Text('${d.month}月${d.day}日 · ${widget.journal == null ? '新的一篇' : '编辑日记'}'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存',
                style: TextStyle(color: StarryTheme.starPurple)),
          ),
        ],
      ),
      // 键盘避让收敛到 _KeyboardAvoider 这一层：viewInsets 变化只会重建它自己，
      // 里面那一大坨（工具条 + 富文本编辑器）实例不变，键盘弹出动画期间不再逐帧重建
      body: _KeyboardAvoider(
        child: SafeArea(
          child: Column(
            children: [
              _moodRow(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: StarryTheme.paper,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Theme(
                      data: StarryTheme.paperLight,
                      child: Column(
                        children: [
                          QuillSimpleToolbar(
                            controller: _controller,
                            config: const QuillSimpleToolbarConfig(
                              showFontFamily: false,
                              showFontSize: false,
                              showSmallButton: false,
                              showColorButton: false,
                              showBackgroundColorButton: false,
                              showInlineCode: false,
                              showCodeBlock: false,
                              showIndent: false,
                              showClearFormat: false,
                              showLink: false,
                              showSearchButton: false,
                              showSubscript: false,
                              showSuperscript: false,
                              showDirection: false,
                              showLineHeightButton: false,
                            ),
                          ),
                          Container(height: 1, color: const Color(0xFFDCD2B8)),
                          Expanded(
                            // 光标闪烁只重绘编辑器这一块，不牵连整页
                            child: RepaintBoundary(
                              child: QuillEditor.basic(
                                controller: _controller,
                                focusNode: _focusNode,
                                config: const QuillEditorConfig(
                                  padding: EdgeInsets.fromLTRB(16, 14, 16, 14),
                                  placeholder: '今天发生了什么…',
                                  autoFocus: true,
                                  customStyles: DefaultStyles(
                                    paragraph: DefaultTextBlockStyle(
                                      TextStyle(
                                        fontSize: 16.5,
                                        height: 1.8,
                                        color: StarryTheme.paperInk,
                                      ),
                                      HorizontalSpacing.zero,
                                      VerticalSpacing.zero,
                                      VerticalSpacing.zero,
                                      null,
                                    ),
                                    placeHolder: DefaultTextBlockStyle(
                                      TextStyle(
                                        fontSize: 16.5,
                                        height: 1.8,
                                        color: Color(0x594A412B),
                                      ),
                                      HorizontalSpacing.zero,
                                      VerticalSpacing.zero,
                                      VerticalSpacing.zero,
                                      null,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          _editorFooter(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _moodRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in _moodIcons.entries)
              GestureDetector(
                onTap: () => setState(
                    () => _mood = _mood == entry.key ? null : entry.key),
                child: Container(
                  margin: const EdgeInsets.only(right: 10),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _mood == entry.key
                        ? StarryTheme.starPurple.withValues(alpha: 0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _mood == entry.key
                          ? StarryTheme.starPurple
                          : const Color(0xFF2E3560),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(entry.value.$1,
                          size: 16,
                          color: _mood == entry.key
                              ? StarryTheme.starPurple
                              : StarryTheme.starDim),
                      const SizedBox(width: 4),
                      Text(entry.value.$2,
                          style: const TextStyle(
                              fontSize: 12, color: StarryTheme.starDim)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _editorFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 10, 8),
      child: Row(
        children: [
          ValueListenableBuilder<int>(
            valueListenable: _charCount,
            builder: (context, count, _) => Text(
              '$count 字',
              style:
                  const TextStyle(fontSize: 11, color: StarryTheme.paperDim),
            ),
          ),
          const Spacer(),
          if (widget.journal != null)
            TextButton.icon(
              onPressed: _delete,
              style: TextButton.styleFrom(
                foregroundColor: StarryTheme.paperDim,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('删除', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

/// 键盘避让层（性能关键）
///
/// 只有这一层去依赖 `MediaQuery.viewInsets`，并且把里面的子树当成一个
/// 固定实例直接透传：键盘弹出/收起时，**只有这一层重建 + 重新布局**，
/// 工具条和富文本编辑器不会被逐帧重建 —— 手感明显顺滑。
class _KeyboardAvoider extends StatelessWidget {
  final Widget child;

  const _KeyboardAvoider({required this.child});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: bottom),
        child: child,
      ),
    );
  }
}

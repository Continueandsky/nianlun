import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/services/photo_import_service.dart';
import 'package:nianlun/services/star_layout_service.dart';
import 'package:nianlun/theme/starry_theme.dart';

/// 自定义编排导入向导：
/// 1. 选来源（全部 / 最近一年 / 相册挑选）
///    - 全部/最近一年：先统计将导入的新照片数，再按容量逐颗挑星体（扣完为止）
///    - 相册挑选：循环式——选一种星体 → 立即进系统相册挑它的照片 →
///      回来再选下一颗……直到点「继续」，每颗的照片就是刚挑的那批
/// 2. 挑星体的同时可以给每颗起名字（右侧编辑栏）
/// 3. 宇宙编辑器：点击星体锁定并弹出名字气泡，之后手指在任意位置
///    拖动都在移动它；点空白处取消锁定，点另一颗切换锁定
/// 4. 保存编排（star_layout.json，含名字）并执行导入
///
/// 完成后 pop 带回 ImportResult，由调用方展示结果。
class CustomImportPage extends ConsumerStatefulWidget {
  const CustomImportPage({super.key});

  @override
  ConsumerState<CustomImportPage> createState() => _CustomImportPageState();
}

class _TypeMeta {
  final String key;
  final IconData icon;
  final Color color;
  const _TypeMeta(this.key, this.icon, this.color);
}

const _typeMetas = [
  _TypeMeta('sphere', Icons.public, Color(0xFFFFCF9E)),
  _TypeMeta('ring', Icons.toll, Color(0xFF9FD8FF)),
  _TypeMeta('spiral', Icons.blur_circular, Color(0xFFB9A6FF)),
  _TypeMeta('cloud', Icons.cloud_outlined, Color(0xFFF0A8D8)),
];

_TypeMeta _metaOf(String type) =>
    _typeMetas.firstWhere((m) => m.key == type, orElse: () => _typeMetas.first);

class _PlannedBody {
  final String type;
  int cap; // 计数模式 = 容量；挑选模式 = 已挑照片数
  String name;
  List<XFile>? files; // 仅「相册挑选」模式：这颗星体对应的照片
  Offset pos; // 世界坐标（摆放编辑器可拖动修改）
  _PlannedBody({
    required this.type,
    required this.cap,
    this.files,
    required this.pos,
  }) : name = '';
}

enum _Step { source, plan, place }

class _CustomImportPageState extends ConsumerState<CustomImportPage> {
  _Step _step = _Step.source;
  bool _counting = false;
  int _newCount = 0;
  DateTime? _since; // null = 全部（计数模式用）
  bool _pickerMode = false; // 相册挑选（循环挑照片）模式
  final List<_PlannedBody> _chosen = [];

  /// 已有星体的名字（小写集合）：命名时禁止与它们重名
  Set<String> _existingNames = {};

  /// 已有星体数量：新星体的默认摆放轨道从它们外面接着排
  int _existingBodyCount = 0;

  @override
  void initState() {
    super.initState();
    StarLayoutService.load().then((layout) {
      if (!mounted || layout == null) return;
      setState(() {
        _existingBodyCount = layout.bodies.length;
        _existingNames = {
          for (final b in layout.bodies)
            if (b.name != null && b.name!.trim().isNotEmpty)
              b.name!.trim().toLowerCase(),
        };
      });
    });
  }

  int get _used => _chosen.fold(0, (s, b) => s + b.cap);
  int get _remaining => _newCount - _used;

  // ---------------- 第 1 步：来源 ----------------

  Future<void> _pickSource({required bool year}) async {
    setState(() => _counting = true);
    final service = ref.read(photoImportServiceProvider);
    final since = year
        ? DateTime.now().subtract(const Duration(days: 365))
        : null;
    final n = await service.countNewPhotos(since: since);
    if (!mounted) return;
    setState(() => _counting = false);
    if (n < 0) {
      _toast('需要相册权限才能统计照片，请在系统设置里允许「年轮」访问照片');
      return;
    }
    if (n == 0) {
      _toast('这个范围内没有可导入的新照片');
      return;
    }
    setState(() {
      _since = since;
      _pickerMode = false;
      _newCount = n;
      _chosen.clear();
      _step = _Step.plan;
    });
  }

  /// 相册挑选：不预统计，进入循环式挑星体+挑照片
  void _pickFromAlbum() {
    setState(() {
      _pickerMode = true;
      _since = null;
      _newCount = 0;
      _chosen.clear();
      _step = _Step.plan;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ---------------- 第 2 步：挑星体 ----------------

  void _addBodyCounted(String type) {
    if (_remaining <= 0) return;
    final cap = math.min(StarLayoutService.capacityOf(type), _remaining);
    setState(() {
      _chosen.add(_PlannedBody(type: type, cap: cap, pos: Offset.zero));
    });
  }

  /// 挑选模式：点星体类型 → 立即进系统相册挑照片 → 归来即成一颗星体
  Future<void> _addBodyPicked(String type) async {
    final files = await ImagePicker().pickMultiImage();
    if (!mounted || files.isEmpty) return;
    setState(() {
      _chosen.add(_PlannedBody(
        type: type,
        cap: files.length,
        files: files,
        pos: Offset.zero,
      ));
    });
  }

  /// 重挑某颗星体的照片（挑选模式）
  Future<void> _repickBody(int index) async {
    final files = await ImagePicker().pickMultiImage();
    if (!mounted || files.isEmpty) return;
    setState(() {
      _chosen[index].files = files;
      _chosen[index].cap = files.length;
    });
  }

  /// 给某颗星体**追加**照片（挑选模式）：
  /// 系统相册单次最多挑 100 张，大星体（上限 220~360）靠多次追加装满。
  /// 与本星体已有照片内容去重；超出类型上限的部分截断并提示。
  Future<void> _appendPhotos(int index) async {
    final b = _chosen[index];
    final existing = b.files ??= <XFile>[];
    final capacity = StarLayoutService.capacityOf(b.type);
    if (existing.length >= capacity) {
      _toast('这颗${StarLayoutService.displayNameOf(b.type)}已装满（上限 $capacity 张）');
      return;
    }
    final picked = await ImagePicker().pickMultiImage();
    if (!mounted || picked.isEmpty) return;

    // 与本星体已有照片内容去重（同一照片重复挑进来直接跳过）
    final sigs = <String>{};
    for (final f in existing) {
      sigs.add(await fileContentSignature(f.path));
    }
    var dups = 0;
    final fresh = <XFile>[];
    for (final f in picked) {
      if (sigs.add(await fileContentSignature(f.path))) {
        fresh.add(f);
      } else {
        dups++;
      }
    }
    if (!mounted) return;

    // 容量截断
    final room = capacity - existing.length;
    var overflow = 0;
    final List<XFile> accepted;
    if (fresh.length > room) {
      overflow = fresh.length - room;
      accepted = fresh.sublist(0, room);
    } else {
      accepted = fresh;
    }

    setState(() {
      existing.addAll(accepted);
      b.cap = existing.length;
    });
    if (dups > 0 || overflow > 0) {
      _toast([
        if (dups > 0) '$dups 张与这颗星体已有照片重复，已跳过',
        if (overflow > 0) '超出容量 $overflow 张未加入（上限 $capacity 张）',
      ].join('；'));
    }
  }

  /// 一键配齐：按类型轮转自动填满剩余照片（计数模式）
  void _autoFill() {
    var i = 0;
    while (_remaining > 0 && i < 2000) {
      final type = _typeMetas[i % _typeMetas.length].key;
      final cap = math.min(StarLayoutService.capacityOf(type), _remaining);
      _chosen.add(_PlannedBody(type: type, cap: cap, pos: Offset.zero));
      i++;
    }
    setState(() {});
  }

  void _toPlacement() {
    // 重名检测：既不许与已有星体重名，本批内部也不许互相重名
    final seen = <String>{};
    for (final b in _chosen) {
      final name = b.name.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (_existingNames.contains(key)) {
        _toast('「$name」与宇宙里已有的星体重名，请换一个');
        return;
      }
      if (!seen.add(key)) {
        _toast('有两颗星体都叫「$name」，请改成不同的名字');
        return;
      }
    }
    // 默认位置：黄金角 + 递增半径螺旋（与星野自动编排同款，方便对照）。
    // 已有星体占据内圈轨道，新星体从它们的轨道外接着排，避免重叠
    final golden = math.pi * (3 - math.sqrt(5));
    final base = _existingBodyCount;
    for (var i = 0; i < _chosen.length; i++) {
      final orbit = base + i;
      final radius = 620.0 + orbit * 110.0;
      final angle = orbit * golden;
      _chosen[i].pos = Offset(
        math.cos(angle) * radius,
        math.sin(angle) * radius * 0.8 + (orbit.isEven ? 60 : -60),
      );
    }
    setState(() => _step = _Step.place);
  }

  // ---------------- 第 4 步：保存编排 + 导入 ----------------

  Future<void> _finish() async {
    // 挑选模式先做**跨星体内容去重**：同一张照片被挑进多颗星体时，
    // 只归属最早选它的那颗（否则同一照片会重复入库，落盘文件名还相同，
    // 星野贴片撞 ValueKey 直接渲染红屏）。去重后才定容量、存编排。
    var dupCount = 0;
    if (_pickerMode) {
      dupCount = await _dedupeAcrossBodies();
      _chosen.removeWhere((b) => b.cap <= 0);
      if (_chosen.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('所选照片都已在之前的星体里了，没有新照片可导入')),
        );
        return;
      }
    }
    // 先存编排（含名字）：即使导入中途中断，星体摆位与名字也不丢。
    // **关键：合并而非覆盖**——旧星体原样保留在前，新星体追加在尾部。
    // 编排语义是「全库照片按日期升序依次填充」，旧照片先填满旧星体
    // （容量不变 → 旧星体成员与位置完全不动），新照片落进尾部新星体，
    // 这样多次导入互不干扰，已命名/已摆位的星体永不丢失。
    final existing = await StarLayoutService.load();
    final layout = StarLayout([
      ...?existing?.bodies,
      for (final b in _chosen)
        StarLayoutBody(
          type: b.type,
          cx: b.pos.dx,
          cy: b.pos.dy,
          cap: b.cap,
          name: b.name.trim().isEmpty ? null : b.name.trim(),
        ),
    ]);
    await StarLayoutService.save(layout);
    if (!mounted) return;

    final service = ref.read(photoImportServiceProvider);
    final progress = ValueNotifier<ImportProgress?>(null);
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WizardImportDialog(
        progress: progress,
        onCancel: () => cancelled = true,
      ),
    );

    ImportResult result;
    try {
      if (_pickerMode) {
        result = await _importPickedBodies(
          service,
          progress,
          presetSkipped: dupCount,
        );
      } else {
        result = await service.importFromLibrary(
          since: _since,
          onProgress: (v) => progress.value = v,
          isCancelled: () => cancelled,
        );
      }
    } catch (_) {
      result = const ImportResult();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;

    ref.invalidate(starLayoutProvider);
    refreshAllDays(ref);
    Navigator.of(context).pop(result);
  }

  /// 挑选模式：逐颗星体导入它那批照片，聚合成一条进度。
  /// [presetSkipped] = 跨星体去重时已判重的数量，并入最终「跳过」统计。
  Future<ImportResult> _importPickedBodies(
    PhotoImportService service,
    ValueNotifier<ImportProgress?> progress, {
    int presetSkipped = 0,
  }) async {
    final total = _used;
    var base = 0;
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    DateTime? earliest;
    DateTime? latest;

    for (final b in _chosen) {
      final files = b.files;
      if (files == null || files.isEmpty) continue;
      final r = await service.importFiles(
        files,
        onProgress: (v) => progress.value = ImportProgress(
          scanned: base + v.scanned,
          total: total,
          imported: imported + v.imported,
          skipped: skipped + v.skipped,
        ),
      );
      base += files.length;
      imported += r.imported;
      skipped += r.skipped;
      failed += r.failed;
      if (r.earliest != null &&
          (earliest == null || r.earliest!.isBefore(earliest))) {
        earliest = r.earliest;
      }
      if (r.latest != null &&
          (latest == null || r.latest!.isAfter(latest))) {
        latest = r.latest;
      }
    }
    return ImportResult(
      imported: imported,
      skipped: skipped + presetSkipped,
      failed: failed,
      earliest: earliest,
      latest: latest,
    );
  }

  /// 跨星体内容去重：同一张照片（内容签名一致）只保留在最早选它的星体里。
  /// 返回被剔除的重复数量；各星体的 files/cap 会被就地修正。
  Future<int> _dedupeAcrossBodies() async {
    final seen = <String>{};
    var dups = 0;
    for (final b in _chosen) {
      final files = b.files;
      if (files == null) continue;
      final unique = <XFile>[];
      for (final f in files) {
        final sig = await fileContentSignature(f.path);
        if (seen.add(sig)) {
          unique.add(f);
        } else {
          dups++;
        }
      }
      b.files = unique;
      b.cap = unique.length;
    }
    return dups;
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StarryTheme.deepSpace,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: StarryTheme.starLight,
        title: const Text('自定义编排导入', style: TextStyle(fontSize: 16)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _stepDot(0, '来源'),
                _stepLine(0),
                _stepDot(1, '挑星体'),
                _stepLine(1),
                _stepDot(2, '摆位置'),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: switch (_step) {
          _Step.source => _buildSource(),
          _Step.plan => _buildPlan(),
          _Step.place => _buildPlace(),
        },
      ),
    );
  }

  Widget _stepDot(int index, String label) {
    final current = _step.index;
    final active = index <= current;
    return Row(
      children: [
        Icon(
          active ? Icons.check_circle : Icons.circle_outlined,
          size: 13,
          color: active ? StarryTheme.starPurple : StarryTheme.starDim,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: active ? StarryTheme.starLight : StarryTheme.starDim,
          ),
        ),
      ],
    );
  }

  Widget _stepLine(int after) {
    return Container(
      width: 26,
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: after < _step.index
          ? StarryTheme.starPurple
          : StarryTheme.starDim.withValues(alpha: 0.3),
    );
  }

  // ---- 第 1 步 UI ----

  Widget _buildSource() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      children: [
        const Text(
          '这些照片从哪来？',
          style: TextStyle(fontSize: 17, color: StarryTheme.starLight),
        ),
        const SizedBox(height: 6),
        const Text(
          '「全部 / 最近一年」会先统计新照片数量再按容量配星体；\n'
          '「从相册挑选」则是选一颗星体、马上去相册挑它的照片，一颗颗来。',
          style: TextStyle(fontSize: 12, color: StarryTheme.starDim, height: 1.6),
        ),
        const SizedBox(height: 18),
        if (_counting)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(color: StarryTheme.starPurple),
            ),
          )
        else ...[
          _sourceTile(
            icon: Icons.all_inclusive,
            title: '相册里的全部照片',
            subtitle: '统计全部未导入的照片',
            onTap: () => _pickSource(year: false),
          ),
          _sourceTile(
            icon: Icons.history,
            title: '只导入最近一年',
            subtitle: '推荐，数量适中',
            onTap: () => _pickSource(year: true),
          ),
          _sourceTile(
            icon: Icons.check_circle_outline,
            title: '从相册挑选',
            subtitle: '选星体 → 挑它的照片 → 再选下一颗',
            onTap: _pickFromAlbum,
          ),
        ],
      ],
    );
  }

  Widget _sourceTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: StarryTheme.nebula.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Row(
              children: [
                Icon(icon, color: StarryTheme.starPurple, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, color: StarryTheme.starLight)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 11, color: StarryTheme.starDim)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: StarryTheme.starDim),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- 第 2 步 UI ----

  Widget _buildPlan() {
    return Column(
      children: [
        _pickerMode ? _buildPickerHeader() : _buildCountedHeader(),
        SizedBox(
          height: 108,
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.4,
            children: [
              for (final m in _typeMetas) _typeCard(m),
            ],
          ),
        ),
        const Divider(height: 18, color: Color(0xFF2A3160)),
        Expanded(
          child: _chosen.isEmpty
              ? Center(
                  child: Text(
                    _pickerMode
                        ? '点上面的星体，马上去相册挑它的照片'
                        : '点上面的星体，把照片一颗颗装进去',
                    style: const TextStyle(
                        fontSize: 12, color: StarryTheme.starDim),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _chosen.length,
                  itemBuilder: (context, i) => _bodyRow(i),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _planReady
                    ? StarryTheme.starPurple
                    : StarryTheme.starDim.withValues(alpha: 0.3),
                foregroundColor: StarryTheme.deepSpace,
              ),
              onPressed: _planReady ? _toPlacement : null,
              child: Text(_planButtonLabel),
            ),
          ),
        ),
      ],
    );
  }

  bool get _planReady =>
      _pickerMode ? _chosen.isNotEmpty : _remaining == 0 && _chosen.isNotEmpty;

  String get _planButtonLabel {
    if (_pickerMode) {
      return _chosen.isEmpty
          ? '先选一颗星体去挑照片'
          : '继续：把 ${_chosen.length} 颗星体摆进宇宙';
    }
    return _remaining == 0 ? '下一步：把星体摆进宇宙' : '还差 $_remaining 张未编排';
  }

  Widget _buildCountedHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '$_remaining',
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w600,
              color: StarryTheme.warmGlow,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '张照片待编排（共 $_newCount 张）',
              style:
                  const TextStyle(fontSize: 12, color: StarryTheme.starDim),
            ),
          ),
          if (_remaining > 0)
            TextButton(
              onPressed: _autoFill,
              child: const Text(
                '一键配齐',
                style:
                    TextStyle(fontSize: 12, color: StarryTheme.starPurple),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPickerHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '${_chosen.length}',
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w600,
              color: StarryTheme.warmGlow,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '颗星体 · 共 $_used 张照片（没装满的星体点它继续加挑）',
              style:
                  const TextStyle(fontSize: 12, color: StarryTheme.starDim),
            ),
          ),
        ],
      ),
    );
  }

  /// 一颗已选星体的行：图标 + 序号/类型/数量 + 命名编辑栏 + 操作
  Widget _bodyRow(int i) {
    final b = _chosen[i];
    final m = _metaOf(b.type);
    final capacity = StarLayoutService.capacityOf(b.type);
    final full = _pickerMode && b.cap >= capacity;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          // 挑选模式下点左侧区域 = 给这颗星体追加照片
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _pickerMode ? () => _appendPhotos(i) : null,
            child: Row(
              children: [
                Icon(m.icon, size: 16, color: m.color),
                const SizedBox(width: 8),
                SizedBox(
                  width: 108,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '第 ${i + 1} 颗 · ${StarLayoutService.displayNameOf(b.type)}',
                        style: const TextStyle(
                            fontSize: 12, color: StarryTheme.starLight),
                      ),
                      Text(
                        _pickerMode
                            ? (full
                                ? '${b.cap} / $capacity 张 · 已装满'
                                : '${b.cap} / $capacity 张 · 点我加挑')
                            : '${b.cap} 张',
                        style: TextStyle(
                          fontSize: 10,
                          color: full
                              ? StarryTheme.warmGlow
                              : StarryTheme.starDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 命名编辑栏
          Expanded(
            child: SizedBox(
              height: 34,
              child: TextFormField(
                key: ObjectKey(b),
                initialValue: b.name,
                onChanged: (v) => b.name = v,
                style: const TextStyle(
                    fontSize: 12, color: StarryTheme.starLight),
                decoration: InputDecoration(
                  hintText: '起个名字…',
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: StarryTheme.starDim.withValues(alpha: 0.55),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  filled: true,
                  fillColor: StarryTheme.nebula.withValues(alpha: 0.55),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide(
                      color: StarryTheme.starPurple.withValues(alpha: 0.22),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide(
                      color: StarryTheme.starPurple.withValues(alpha: 0.16),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(
                        color: StarryTheme.starPurple, width: 1),
                  ),
                ),
              ),
            ),
          ),
          if (_pickerMode)
            GestureDetector(
              onTap: full ? null : () => _appendPhotos(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.add_photo_alternate_outlined,
                    size: 16,
                    color: full
                        ? StarryTheme.starDim.withValues(alpha: 0.4)
                        : StarryTheme.starPurple),
              ),
            ),
          if (_pickerMode)
            GestureDetector(
              onTap: () => _repickBody(i),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.sync,
                    size: 15, color: StarryTheme.starDim),
              ),
            ),
          GestureDetector(
            onTap: () => setState(() => _chosen.removeAt(i)),
            child: const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.remove_circle_outline,
                  size: 17, color: StarryTheme.starDim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeCard(_TypeMeta m) {
    final enabled = _pickerMode || _remaining > 0;
    final capacity = StarLayoutService.capacityOf(m.key);
    return Material(
      color: StarryTheme.nebula.withValues(alpha: enabled ? 0.75 : 0.35),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled
            ? () => _pickerMode ? _addBodyPicked(m.key) : _addBodyCounted(m.key)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(m.icon, size: 18, color: m.color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      StarLayoutService.displayNameOf(m.key),
                      style: const TextStyle(
                          fontSize: 12, color: StarryTheme.starLight),
                    ),
                    Text(
                      _pickerMode ? '点了就去挑照片' : '$capacity 张 / 颗',
                      style: const TextStyle(
                          fontSize: 10, color: StarryTheme.starDim),
                    ),
                  ],
                ),
              ),
              Icon(
                _pickerMode ? Icons.photo_library_outlined : Icons.add_circle_outline,
                size: 16,
                color:
                    enabled ? StarryTheme.starPurple : StarryTheme.starDim,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 第 3 步 UI（宇宙编辑器）----

  Widget _buildPlace() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(
            '点击星体锁定它（会弹出名字），然后手指在任意位置拖动来移动；'
            '点空白处取消锁定，点另一颗切换',
            style:
                TextStyle(fontSize: 12, color: StarryTheme.starDim, height: 1.5),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _PlacementEditor(bodies: _chosen),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: StarryTheme.warmGlow,
                foregroundColor: StarryTheme.deepSpace,
              ),
              onPressed: _finish,
              child: const Text('完成编排，开始导入'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 宇宙摆放编辑器：点击锁定星体（弹名字气泡）→ 任意位置拖动移动它
class _PlacementEditor extends StatefulWidget {
  final List<_PlannedBody> bodies;
  const _PlacementEditor({required this.bodies});

  @override
  State<_PlacementEditor> createState() => _PlacementEditorState();
}

class _PlacementEditorState extends State<_PlacementEditor> {
  int? _lockedIndex;
  Size _size = Size.zero;

  double get _zoom {
    var maxR = 900.0;
    for (final b in widget.bodies) {
      maxR =
          math.max(maxR, b.pos.distance + StarLayoutService.extentOf(b.type));
    }
    if (_size == Size.zero) return 0.1;
    return math.min(_size.width, _size.height) * 0.44 / maxR;
  }

  Offset _toScreen(Offset world) {
    final z = _zoom;
    return Offset(
      _size.width / 2 + world.dx * z,
      _size.height / 2 + world.dy * z,
    );
  }

  int? _hit(Offset screenPos) {
    final z = _zoom;
    for (var i = widget.bodies.length - 1; i >= 0; i--) {
      final b = widget.bodies[i];
      final s = _toScreen(b.pos);
      final hitR = math.max(StarLayoutService.extentOf(b.type) * z, 22.0);
      if ((s - screenPos).distance < hitR) return i;
    }
    return null;
  }

  void _onTap(Offset pos) {
    final hit = _hit(pos);
    setState(() {
      if (hit == null) {
        _lockedIndex = null; // 点空白：取消锁定
      } else if (hit == _lockedIndex) {
        _lockedIndex = null; // 再点同一颗：取消锁定
      } else {
        _lockedIndex = hit; // 锁定 / 切换锁定
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        final locked = _lockedIndex;
        Offset? bubbleAnchor;
        if (locked != null && locked < widget.bodies.length) {
          bubbleAnchor = _toScreen(widget.bodies[locked].pos);
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTap(d.localPosition),
          onPanUpdate: (d) {
            final i = _lockedIndex;
            if (i == null || i >= widget.bodies.length) return;
            setState(() {
              widget.bodies[i].pos += d.delta / _zoom;
            });
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _PlacementPainter(
                  bodies: widget.bodies,
                  zoom: _zoom,
                  lockedIndex: _lockedIndex,
                ),
                child: const SizedBox.expand(),
              ),
              // 名字气泡（宇宙配色）
              if (bubbleAnchor != null && locked != null)
                Positioned(
                  left: (bubbleAnchor.dx - 90)
                      .clamp(8.0, math.max(8.0, _size.width - 190)),
                  top: (bubbleAnchor.dy -
                          math.max(
                              StarLayoutService.extentOf(
                                      widget.bodies[locked].type) *
                                  _zoom,
                              22.0) -
                          66)
                      .clamp(8.0, math.max(8.0, _size.height - 70)),
                  child: CosmosBubble(
                    title: widget.bodies[locked].name.trim().isEmpty
                        ? '第 ${locked + 1} 颗 · ${StarLayoutService.displayNameOf(widget.bodies[locked].type)}'
                        : widget.bodies[locked].name.trim(),
                    subtitle: '已锁定 · 拖动移动 · 点空白取消',
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 宇宙配色的消息气泡（摆放编辑器与星野名字气泡共用样式）
class CosmosBubble extends StatelessWidget {
  final String title;
  final String? subtitle;
  const CosmosBubble({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 182),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: StarryTheme.nebula.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: StarryTheme.starPurple.withValues(alpha: 0.45),
        ),
        boxShadow: [
          BoxShadow(
            color: StarryTheme.starPurple.withValues(alpha: 0.20),
            blurRadius: 18,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: StarryTheme.starLight,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 10,
                color: StarryTheme.starDim,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlacementPainter extends CustomPainter {
  final List<_PlannedBody> bodies;
  final double zoom;
  final int? lockedIndex;

  const _PlacementPainter({
    required this.bodies,
    required this.zoom,
    required this.lockedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = StarryTheme.deepSpace,
    );

    // 背景星星（静态）
    final rand = math.Random(2026);
    final starPaint = Paint();
    for (var i = 0; i < 120; i++) {
      starPaint.color =
          Colors.white.withValues(alpha: 0.05 + rand.nextDouble() * 0.18);
      canvas.drawCircle(
        Offset(rand.nextDouble() * size.width,
            rand.nextDouble() * size.height),
        0.4 + rand.nextDouble() * 1.1,
        starPaint,
      );
    }

    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint();
    for (var i = 0; i < bodies.length; i++) {
      final b = bodies[i];
      final meta = _metaOf(b.type);
      final screen = center + Offset(b.pos.dx * zoom, b.pos.dy * zoom);
      final r = math.max(StarLayoutService.extentOf(b.type) * zoom, 14.0);
      final locked = i == lockedIndex;

      // 光晕（锁定时更亮）
      paint.shader = RadialGradient(
        colors: [
          meta.color.withValues(alpha: locked ? 0.55 : 0.3),
          meta.color.withValues(alpha: 0.08),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: screen, radius: r));
      canvas.drawCircle(screen, r, paint);
      paint.shader = null;

      // 锁定时加一圈描边光环
      if (locked) {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.white.withValues(alpha: 0.75);
        canvas.drawCircle(screen, r * 0.72, paint);
        paint.style = PaintingStyle.fill;
      }

      // 星核
      paint.color = Colors.white.withValues(alpha: 0.9);
      canvas.drawCircle(screen, 2.2, paint);

      // 序号
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            fontSize: 10,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, screen - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _PlacementPainter old) => true;
}

class _WizardImportDialog extends StatelessWidget {
  final ValueNotifier<ImportProgress?> progress;
  final VoidCallback onCancel;

  const _WizardImportDialog({
    required this.progress,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: StarryTheme.nebula,
      title: const Text(
        '正在把照片收进年轮…',
        style: TextStyle(fontSize: 15, color: StarryTheme.starLight),
      ),
      content: ValueListenableBuilder<ImportProgress?>(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: value?.ratio,
                minHeight: 4,
                backgroundColor: const Color(0xFF2A3160),
                valueColor: const AlwaysStoppedAnimation(
                  StarryTheme.starPurple,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              value == null
                  ? '读取相册中…'
                  : '${value.scanned} / ${value.total}　新导入 ${value.imported}',
              style: const TextStyle(
                fontSize: 12,
                color: StarryTheme.starDim,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child:
              const Text('停下', style: TextStyle(color: StarryTheme.starDim)),
        ),
      ],
    );
  }
}

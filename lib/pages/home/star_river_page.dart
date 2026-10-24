import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nianlun/models/day_entry.dart';
import 'package:nianlun/pages/home/custom_import_page.dart';
import 'package:nianlun/pages/node/node_page.dart';
import 'package:nianlun/pages/settings/backup_sheet.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/services/photo_import_service.dart';
import 'package:nianlun/services/star_layout_service.dart';
import 'package:nianlun/theme/starry_theme.dart';
import 'package:path/path.dart' as p;

/// 星河 Tab：把照片摆成一片「活着的」3D 星海。
///
/// 宏观浏览（默认）：
///  - 照片聚成几颗宏观星体（星球 / 星环 / 银河 / 星云），持续自转、流动、漂浮
///  - 拖动平移视角（惯性），捏合放大后照片淡入为贴片（此时星体运动冻结）
///  - 点击星体（未中照片点）→ 弹出宇宙配色的名字气泡；未命名显示「无名星体」，
///    长按气泡可编辑名字（持久化进 star_layout.json）
///  - 点中足够大的照片点 → 进入那张照片所在那天的节点页（约 280ms 双击判定延迟）
///  - 双击空白处 → 缩放切换；双击某个星体 → 进入专注态
///  - 右上角三条杠菜单：搜索星体（按名字，点击结果相机平滑飞入专注态）/
///    相册导入 / 备份与恢复
///
/// 专注态（双击星体进入）：
///  - 该星体动画居中成为主体，其余星体淡出；顶部标题栏向上滑出，退出后滑回
///  - 单指拖动 = 拨转星体（水平偏航 / 垂直俯仰，**俯仰无上限**，可整圈翻转），
///    松手带惯性；运动永不冻结：放大出贴片后照片依然贴在三维表面上跟着转，
///    正面 / 侧面 / 背面全部贴出（远的更小更暗），立体形状不崩塌
///  - 双指捏小到阈值 → 动画缩回原位，退出专注态
///  - 底部「平铺浏览」→ 沉浸式星墙：照片从三维位置逐张飞出拼成照片墙
///    （星球/星环按经度展开、银河按半径展开、星云随机飘散），上下滑动浏览，
///    捏小或再点按钮飞回星体
///
/// 手势识别说明：
///  onScale 与 onTap/onDoubleTap 挂在同一个 GestureDetector 上会互相吞掉，
///  所以点按/双击全部在 scale 回调里手动识别（位移 < 14px 且时长 < 350ms 视为点按）。
///
/// 性能要点：
///  - cacheWidth 分桶：连续变化的解码宽度会让每张图每帧重解码
///  - 贴片宽度按 6px 量化，同屏贴片上限 72，阴影从简
///  - 贴片是「星体级闸门」：zoom*base >= 阈值时整颗星体前后全贴，
///    点阵 painter 同步整体让位，避免逐颗阈值造成的双面不一致
class StarRiverPage extends ConsumerWidget {
  /// 专注态开关（由 HomeShell 持有）：进入/退出专注态时置位，
  /// 底部 Tab 栏与 FAB 随之动画降下/升起
  final ValueNotifier<bool>? focusMode;

  const StarRiverPage({super.key, this.focusMode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daysAsync = ref.watch(daysProvider);
    final rootAsync = ref.watch(mediaRootPathProvider);
    final layoutAsync = ref.watch(starLayoutProvider);

    return daysAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: StarryTheme.starPurple),
      ),
      error: (error, _) => _RiverMessage(text: '读取失败：$error'),
      data: (days) => rootAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: StarryTheme.starPurple),
        ),
        error: (error, _) => _RiverMessage(text: '媒体目录读取失败：$error'),
        data: (rootPath) => _StarField(
          days: days,
          rootPath: rootPath,
          focusMode: focusMode,
          layout: layoutAsync.valueOrNull,
        ),
      ),
    );
  }
}

class _RiverMessage extends StatelessWidget {
  final String text;
  const _RiverMessage({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: const TextStyle(color: StarryTheme.starDim, fontSize: 13),
      ),
    );
  }
}

// ------------------------------------------------------------------
// 星场状态
// ------------------------------------------------------------------

class _StarField extends ConsumerStatefulWidget {
  final List<DaySummary> days;
  final String rootPath;
  final ValueNotifier<bool>? focusMode;
  final StarLayout? layout;
  const _StarField({
    required this.days,
    required this.rootPath,
    this.focusMode,
    this.layout,
  });

  @override
  ConsumerState<_StarField> createState() => _StarFieldState();
}

class _StarFieldState extends ConsumerState<_StarField>
    with TickerProviderStateMixin {
  late List<_Shard> _shards;
  late List<_BodySpec> _bodies;
  Size _viewport = Size.zero;
  bool _needsFraming = true; // 首帧按星体包围盒自动取景

  _Camera _camera = const _Camera();
  _Camera _gestureStartCamera = const _Camera();
  Offset _gestureStartFocal = Offset.zero;

  Ticker? _inertiaTicker;
  DateTime? _lastInertiaTime;
  Offset _inertiaVelocity = Offset.zero;

  // 星体运动时钟：常开；宏观态进入贴片区间后暂停走时（冻结画面）
  Ticker? _motionTicker;
  double _motionT = 0;

  AnimationController? _zoomAnim;

  // ---- 专注态（双击某颗星体进入）----
  int? _focusBody; // 主体星体下标；null = 宏观浏览
  int? _lastFocusBody; // 退出动画期间仍需知道谁是主体
  double _focusMix = 0; // 0 宏观 ↔ 1 专注（其他星体淡出程度）
  double _focusFitZoom = 1.0; // 星体恰好适配屏幕的 zoom
  _Camera _overviewCamera = const _Camera(); // 进入专注态前的相机
  bool _exitArmed = true; // 本次手势里是否还允许触发「捏小退出」
  double _userYaw = 0; // 拨动产生的偏航角
  double _userTilt = 0; // 拨动产生的俯仰角（无上限，可整圈翻转）
  double _yawVel = 0; // 拨动惯性（rad/s）
  double _tiltVel = 0;
  Ticker? _spinTicker;
  DateTime? _lastSpinTime;

  // ---- 星墙（沉浸式平铺浏览）----
  bool _wallOpen = false;
  double _wallMix = 0; // 0 星体 ↔ 1 星墙
  double _wallScroll = 0; // 星墙纵向滚动（世界单位）
  double _wallZoom = 1; // 星墙取景 zoom
  double _wallContentH = 0; // 星墙内容总高（世界单位）
  _Camera _preWallCamera = const _Camera(); // 进入星墙前的相机
  final Map<_Shard, Offset> _wallSlotOf = {}; // 每张照片的墙内槽位
  final Map<_Shard, double> _wallStaggerOf = {}; // 出场次序（按星体形状算）
  final Map<_Shard, double> _easeByShard = {}; // 每帧的个体过渡进度
  List<_Resolved> _displayResolved = const []; // 每帧的展示坐标（含星墙插值）
  AnimationController? _wallAnim;
  double _wallScrollVel = 0;
  Ticker? _wallTicker;
  DateTime? _lastWallTime;

  // ---- 手动点按/双击识别（onScale 会吞掉同槽的 onTap）----
  Offset _downFocal = Offset.zero;
  Offset _lastFocal = Offset.zero;
  DateTime _downTime = DateTime.fromMillisecondsSinceEpoch(0);
  double _maxMove = 0;
  bool _multiTouch = false;
  DateTime _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapPos = Offset.zero;
  Timer? _pendingTap;
  DateTime _suppressTapUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- 星体名字气泡 / 搜索 ----
  int? _bubbleBody; // 宏观态弹出名字气泡的星体下标
  bool _searchOpen = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  /// 粘性编排缓存：provider 刷新期间 widget.layout 会短暂变 null，
  /// 此时沿用旧值、不触发星体重建（否则命名保存的瞬间星野会闪成
  /// 自动编排再闪回来，还可能撞上路由退出动画导致框架断言）
  StarLayout? _effectiveLayout;

  // 视觉常量
  static const double _minZoom = 0.05;
  static const double _maxZoom = 5.5;
  static const double _baseWorldSize = 9.0; // 点在 zoom=1 时的世界尺寸
  static const double _imageThreshold = 14.0; // 星体级贴片闸门（zoom*base）
  static const double _dotThreshold = 2.2; // 小于此尺寸不绘制（性能裁剪）
  static const int _maxTiles = 72; // 同屏贴片上限（性能保险丝）

  // 星墙槽位（世界单位）
  static const double _wallSlotW = 96.0;
  static const double _wallSlotH = 120.0;
  static const double _wallGap = 12.0;

  // 手势常量
  static const double _tapSlop = 14.0; // 点按允许的最大位移（px）
  static const Duration _tapDelay = Duration(milliseconds: 280); // 单击确认延迟
  static const double _yawFactor = 0.009; // 拨动灵敏度（rad/px）
  static const double _tiltFactor = 0.007;

  /// 解码宽度分桶：只有跨桶才会触发 Image 重新解码
  static const List<int> _cacheBuckets = [96, 160, 224, 320, 448, 640, 768];

  @override
  void initState() {
    super.initState();
    _effectiveLayout = widget.layout;
    _rebuildShards();
    _motionTicker = createTicker(_onMotionTick)..start();
  }

  @override
  void didUpdateWidget(covariant _StarField old) {
    super.didUpdateWidget(old);
    final layoutChanged =
        widget.layout != null && widget.layout != _effectiveLayout;
    if (widget.layout != null) _effectiveLayout = widget.layout;
    if (widget.days != old.days || layoutChanged) {
      _rebuildShards();
    }
  }

  @override
  void dispose() {
    _stopInertia();
    _stopSpinInertia();
    _stopWallInertia();
    _stopWallAnim();
    _pendingTap?.cancel();
    _motionTicker?.dispose();
    _zoomAnim?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _rebuildShards() {
    final built = _buildShards(widget.days, _effectiveLayout);
    _shards = built.shards;
    _bodies = built.bodies;
    // 相机、专注态、气泡全部保留：命名保存/导入刷新不再把视角拽回原位。
    // 仅当星体数量变化导致下标越界时才退回宏观态
    if (_focusBody != null && _focusBody! >= _bodies.length) {
      _focusBody = null;
      _focusMix = 0;
      _setFocusMode(false);
    }
    if (_lastFocusBody != null && _lastFocusBody! >= _bodies.length) {
      _lastFocusBody = null;
    }
    if (_bubbleBody != null && _bubbleBody! >= _bodies.length) {
      _bubbleBody = null;
    }
    _resetWall();
  }

  void _resetWall() {
    _stopWallAnim();
    _stopWallInertia();
    _wallOpen = false;
    _wallMix = 0;
    _wallScroll = 0;
    _wallSlotOf.clear();
    _wallStaggerOf.clear();
    _easeByShard.clear();
  }

  /// 通知 HomeShell：专注态开关变化（Tab 栏/FAB 动画隐藏或升起）
  void _setFocusMode(bool value) {
    final notifier = widget.focusMode;
    if (notifier != null && notifier.value != value) {
      notifier.value = value;
    }
  }

  /// 当前有效的专注主体（含退出动画期间）
  int? get _activeFocus =>
      _focusBody ?? (_focusMix > 0 ? _lastFocusBody : null);

  Offset _focusedOffset() {
    final idx = _activeFocus;
    if (idx == null) return _camera.offset;
    return -_bodies[idx].center; // 星体钉在屏幕中心
  }

  int _focusPhotoCount() {
    final f = _activeFocus;
    if (f == null) return 0;
    var n = 0;
    for (final s in _shards) {
      if (s.bodyIndex == f) n++;
    }
    return n;
  }

  // ---------------- 运动时钟 ----------------

  void _onMotionTick(Duration elapsed) {
    // 宏观浏览下，贴片即将/已经出现就冻结走时（性能 + 点击稳定）；
    // 专注态下永不冻结：星体要一直转，贴片贴在三维表面上跟着转
    if (_focusBody == null &&
        _camera.zoom * _baseWorldSize >= _imageThreshold - 2) {
      return;
    }
    final t = elapsed.inMicroseconds / 1e6;
    if (t == _motionT) return;
    _motionT = t;
    setState(() {});
  }

  /// 按当前运动时刻解算每颗星的世界坐标与深度（远→近排序）。
  List<_Resolved> _resolve() {
    final t = _motionT;
    final focus = _activeFocus;
    final list = <_Resolved>[];
    for (final s in _shards) {
      final b = _bodies[s.bodyIndex];
      final isFocus = focus != null && s.bodyIndex == focus;
      final yaw = b.tiltY + b.spin * t + (isFocus ? _userYaw : 0);
      final tiltX = b.tiltX + (isFocus ? _userTilt : 0);
      _Vec3 v;
      switch (b.type) {
        case _BodyType.sphere:
        case _BodyType.ring:
          // 绕自身 Y 轴自转，再叠加固定倾角与用户拨转
          v = s.local.rotateY(yaw).rotateX(tiltX);
        case _BodyType.spiral:
          // 差速自转（内快外慢，像在流动）+ 径向呼吸
          final lx = s.local.x;
          final ly = s.local.y;
          final r0 = math.sqrt(lx * lx + ly * ly);
          final th0 = math.atan2(ly, lx);
          final rNorm = (r0 / b.extent).clamp(0.0, 1.0);
          final flow =
              b.spin * t * (1.3 - 0.6 * rNorm) + (isFocus ? _userYaw : 0);
          final breathe = 1 + 0.045 * math.sin(t * 0.8 + b.phase);
          final r = r0 * breathe;
          v = _Vec3(r * math.cos(th0 + flow), r * math.sin(th0 + flow),
                  s.local.z)
              .rotateY(b.tiltY)
              .rotateX(tiltX);
        case _BodyType.cloud:
          // 整体慢速涡旋 + 每颗星独立脉冲与上下漂浮
          final pulse = 1 + 0.06 * math.sin(t * 0.7 + s.seed * 1.31);
          v = _Vec3(
            s.local.x * pulse,
            s.local.y * pulse + 4.5 * math.sin(t * 0.5 + s.seed * 1.73),
            s.local.z,
          ).rotateY(yaw).rotateX(tiltX);
      }
      final depth = ((v.z / b.depthScale + 1) / 2).clamp(0.0, 1.0);
      list.add(_Resolved(s, b.center + Offset(v.x, v.y), depth));
    }
    list.sort((a, b) => a.depth.compareTo(b.depth));
    return list;
  }

  // ---------------- 星墙（沉浸式平铺浏览）----------------

  /// 出场次序：按星体形状给每张照片一个 0..1 的 stagger 键
  double _staggerKey(_BodyType type, _Shard s, _BodySpec b) {
    switch (type) {
      case _BodyType.sphere:
      case _BodyType.ring:
        // 按经度展开：像把球面/圆柱面沿一条母线剪开摊平
        final a = math.atan2(s.local.z, s.local.x);
        return (a + math.pi) / (2 * math.pi);
      case _BodyType.spiral:
        // 由内圈向外圈展开
        final r = math.sqrt(s.local.x * s.local.x + s.local.y * s.local.y);
        return (r / b.extent).clamp(0.0, 1.0);
      case _BodyType.cloud:
        // 随机飘散
        return ((s.seed * 2654435761) % 1000) / 1000;
    }
  }

  void _computeWall(int focus) {
    final bodyShards = _shards.where((s) => s.bodyIndex == focus).toList();
    final n = bodyShards.length;
    if (n == 0) return;
    final cols = n <= 9 ? 3 : 4;
    final rows = (n / cols).ceil();
    final contentW = cols * _wallSlotW + (cols - 1) * _wallGap;
    _wallContentH = rows * _wallSlotH + (rows - 1) * _wallGap;
    _wallZoom =
        (_viewport.width * 0.92 / contentW).clamp(0.3, 3.0).toDouble();
    final visibleH = _viewport.height / _wallZoom;
    final b = _bodies[focus];
    final topY = b.center.dy - visibleH * 0.44;
    final leftX = b.center.dx - contentW / 2 + _wallSlotW / 2;

    _wallSlotOf.clear();
    _wallStaggerOf.clear();
    for (var i = 0; i < n; i++) {
      final s = bodyShards[i];
      final row = i ~/ cols;
      final col = i % cols;
      _wallSlotOf[s] = Offset(
        leftX + col * (_wallSlotW + _wallGap),
        topY + row * (_wallSlotH + _wallGap) + _wallSlotH / 2,
      );
      _wallStaggerOf[s] = _staggerKey(b.type, s, b);
    }
  }

  /// 每张照片的展示状态：三维世界坐标 ↔ 星墙槽位 的逐个体插值
  void _fillDisplayResolved(List<_Resolved> resolved) {
    _easeByShard.clear();
    if (_wallMix <= 0) {
      _displayResolved = resolved;
      return;
    }
    final focus = _activeFocus;
    const lag = 0.35; // stagger 拉开的时长占比
    final out = <_Resolved>[];
    for (final r in resolved) {
      final slot = _wallSlotOf[r.shard];
      if (focus == null || r.shard.bodyIndex != focus || slot == null) {
        out.add(r);
        continue;
      }
      final k = _wallStaggerOf[r.shard] ?? 0;
      final raw = (_wallMix * (1 + lag) - k * lag).clamp(0.0, 1.0);
      final e = Curves.easeOutCubic.transform(raw);
      _easeByShard[r.shard] = e;
      final target = slot - Offset(0, _wallScroll);
      out.add(_Resolved(
        r.shard,
        Offset.lerp(r.world, target, e)!,
        r.depth + (1 - r.depth) * e,
      ));
    }
    out.sort((a, b) => a.depth.compareTo(b.depth));
    _displayResolved = out;
  }

  double _clampWallScroll(double s) {
    final visibleH = _viewport.height / math.max(_camera.zoom, 0.05);
    final maxScroll = math.max(0.0, _wallContentH - visibleH * 0.88);
    return s.clamp(0.0, maxScroll).toDouble();
  }

  void _openWall() {
    final focus = _focusBody;
    if (focus == null || _wallOpen || _wallAnim != null) return;
    _stopInertia();
    _stopSpinInertia();
    _stopZoomAnim();
    _computeWall(focus);
    if (_wallSlotOf.isEmpty) return;
    _preWallCamera = _camera;
    _wallOpen = true;
    _wallScroll = 0;
    _runWallAnim(
      to: _Camera(offset: -_bodies[focus].center, zoom: _wallZoom),
      mixTo: 1,
    );
  }

  void _closeWall() {
    if (!_wallOpen) return;
    _stopWallInertia();
    _runWallAnim(to: _preWallCamera, mixTo: 0, onDone: () {
      _wallOpen = false;
      _wallScroll = 0;
      _wallSlotOf.clear();
      _wallStaggerOf.clear();
    });
  }

  /// 星墙进出动画：相机 + 过渡程度一起走
  void _runWallAnim({
    required _Camera to,
    required double mixTo,
    VoidCallback? onDone,
  }) {
    _stopWallAnim();
    _wallAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    final curve =
        CurvedAnimation(parent: _wallAnim!, curve: Curves.easeInOutCubic);
    final zoomTween = Tween<double>(begin: _camera.zoom, end: to.zoom);
    final offsetTween =
        Tween<Offset>(begin: _camera.offset, end: to.offset);
    final mixTween = Tween<double>(begin: _wallMix, end: mixTo);
    void listener() {
      setState(() {
        _camera = _Camera(
          offset: offsetTween.evaluate(curve),
          zoom: zoomTween.evaluate(curve),
        );
        _wallMix = mixTween.evaluate(curve);
      });
    }

    _wallAnim!.addListener(listener);
    _wallAnim!.forward().whenComplete(() {
      _wallAnim?.removeListener(listener);
      _stopWallAnim();
      onDone?.call();
    });
  }

  void _stopWallAnim() {
    _wallAnim?.stop();
    _wallAnim?.dispose();
    _wallAnim = null;
  }

  void _startWallInertia() {
    _stopWallInertia();
    _lastWallTime = DateTime.now();
    _wallTicker = createTicker(_onWallTick)..start();
  }

  void _onWallTick(Duration elapsed) {
    final now = DateTime.now();
    final dt = _lastWallTime == null
        ? 0.016
        : now.difference(_lastWallTime!).inMicroseconds / 1e6;
    _lastWallTime = now;
    _wallScrollVel *= math.pow(0.06, dt).toDouble();
    setState(() {
      _wallScroll = _clampWallScroll(_wallScroll + _wallScrollVel * dt);
    });
    if (_wallScrollVel.abs() < 24) _stopWallInertia();
  }

  void _stopWallInertia() {
    _wallTicker?.stop();
    _wallTicker?.dispose();
    _wallTicker = null;
    _wallScrollVel = 0;
  }

  // ---------------- 手势 ----------------

  void _onScaleStart(ScaleStartDetails details) {
    _stopInertia();
    _stopZoomAnim();
    _stopSpinInertia();
    _stopWallInertia();
    _cancelPendingTap();
    _gestureStartCamera = _camera;
    _gestureStartFocal = details.focalPoint;
    _downFocal = details.focalPoint;
    _lastFocal = details.focalPoint;
    _downTime = DateTime.now();
    _maxMove = 0;
    _multiTouch = false;
    _exitArmed = true;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // 进/退专注态、星墙进出动画进行中，手势不接管相机
    if (_zoomAnim != null || _wallAnim != null) {
      _lastFocal = details.focalPoint;
      return;
    }
    if (details.pointerCount >= 2) _multiTouch = true;
    _maxMove =
        math.max(_maxMove, (details.focalPoint - _downFocal).distance);

    if (_focusBody != null) {
      if (_wallOpen) {
        // 星墙：单指上下滚动浏览；捏合微调缩放，捏小到阈值返回星体
        if (details.pointerCount >= 2) {
          final newZoom = (_gestureStartCamera.zoom * details.scale)
              .clamp(_minZoom, _maxZoom)
              .toDouble();
          setState(() {
            _camera =
                _Camera(offset: _gestureStartCamera.offset, zoom: newZoom);
          });
          if (_exitArmed && newZoom < _wallZoom * 0.72) {
            _exitArmed = false;
            _closeWall();
          }
        } else if (!_multiTouch) {
          final dy = details.focalPoint.dy - _lastFocal.dy;
          setState(() {
            _wallScroll =
                _clampWallScroll(_wallScroll - dy / _camera.zoom);
          });
        }
      } else if (details.pointerCount >= 2) {
        // 捏合：只变 zoom，星体始终居中
        final newZoom = (_gestureStartCamera.zoom * details.scale)
            .clamp(_minZoom, _maxZoom)
            .toDouble();
        setState(() {
          _camera = _Camera(offset: _focusedOffset(), zoom: newZoom);
        });
        // 捏小到阈值：自动退出专注态
        if (_exitArmed && newZoom < _focusFitZoom * 0.55) {
          _exitArmed = false;
          _exitFocus();
        }
      } else if (!_multiTouch) {
        // 单指：拨转星体（水平 = 偏航，垂直 = 俯仰翻转，俯仰无上限）
        final dx = details.focalPoint.dx - _lastFocal.dx;
        final dy = details.focalPoint.dy - _lastFocal.dy;
        setState(() {
          _userYaw += dx * _yawFactor;
          _userTilt += dy * _tiltFactor;
        });
      }
    } else {
      // 宏观浏览：捏合缩放（焦点锚定）+ 平移
      final newZoom = (_gestureStartCamera.zoom * details.scale)
          .clamp(_minZoom, _maxZoom)
          .toDouble();
      final center = Offset(_viewport.width / 2, _viewport.height / 2);
      final world0 = (_gestureStartFocal - center) /
              _gestureStartCamera.zoom -
          _gestureStartCamera.offset;
      final newOffset = (details.focalPoint - center) / newZoom - world0;
      final clamped = _clampOffset(newOffset, newZoom);
      setState(() => _camera = _Camera(offset: clamped, zoom: newZoom));
    }
    _lastFocal = details.focalPoint;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // 手动点按识别：单指、位移小、时间短
    final isTap = !_multiTouch &&
        _maxMove < _tapSlop &&
        DateTime.now().difference(_downTime).inMilliseconds < 350;
    if (isTap) {
      _handleTapCandidate(_downFocal);
      return;
    }
    if (_focusBody != null) {
      if (_wallOpen) {
        // 星墙滚动松手：纵向惯性
        if (!_multiTouch) {
          _wallScrollVel =
              -details.velocity.pixelsPerSecond.dy /
                  math.max(_camera.zoom, 0.05);
          if (_wallScrollVel.abs() > 60) _startWallInertia();
        }
        return;
      }
      // 拨转松手：带惯性继续转
      if (!_multiTouch) {
        final v = details.velocity.pixelsPerSecond;
        _yawVel = v.dx * _yawFactor;
        _tiltVel = v.dy * _tiltFactor;
        if (_yawVel.abs() > 0.15 || _tiltVel.abs() > 0.15) {
          _startSpinInertia();
        }
      }
      return;
    }
    final v = details.velocity.pixelsPerSecond;
    if (v.distance > 40) {
      _startInertia(v);
    }
  }

  // ---- 手动点按 / 双击 ----

  void _handleTapCandidate(Offset pos) {
    final now = DateTime.now();
    if (now.isBefore(_suppressTapUntil)) return;
    if (now.difference(_lastTapTime).inMilliseconds < 320 &&
        (pos - _lastTapPos).distance < 48) {
      // 双击
      _cancelPendingTap();
      _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);
      _handleDoubleTap(pos);
      return;
    }
    _lastTapTime = now;
    _lastTapPos = pos;
    _pendingTap?.cancel();
    _pendingTap = Timer(_tapDelay, () => _handleSingleTap(pos));
  }

  void _cancelPendingTap() {
    _pendingTap?.cancel();
    _pendingTap = null;
  }

  void _handleSingleTap(Offset pos) {
    _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);
    if (_searchOpen) {
      _closeSearch(); // 搜索面板开着时，点星野任意处收起面板
      return;
    }
    if (_focusBody != null) {
      final hit = _hitShard(pos);
      if (hit != null) _openPhoto(hit.shard);
      return;
    }
    // 宏观态的点击分流：
    //  - 点中「足够大」的照片点（放大到能分清个体）→ 打开照片
    //  - 点中星体区域但没中照片点 → 弹出名字气泡（再次点击切换/关闭）
    final wasBubble = _bubbleBody;
    final hit = _hitShard(pos, minSize: 10);
    if (hit != null) {
      if (_bubbleBody != null) setState(() => _bubbleBody = null);
      _openPhoto(hit.shard);
      return;
    }
    final bodyHit = _hitBody(pos);
    if (bodyHit != null && bodyHit != wasBubble) {
      setState(() => _bubbleBody = bodyHit);
    } else if (_bubbleBody != null) {
      setState(() => _bubbleBody = null);
    }
  }

  void _handleDoubleTap(Offset pos) {
    if (_focusBody != null) return; // 专注态/星墙下双击无操作
    final bodyHit = _hitBody(pos);
    if (bodyHit != null) {
      _enterFocus(bodyHit);
      return;
    }
    // 空白处双击：保留缩放切换
    final targetZoom = _camera.zoom < 0.9 ? 2.4 : 0.35;
    final targetOffset = _camera.zoom < 0.9
        ? _clampOffset(_camera.offset, targetZoom)
        : _clampOffset(-_nearestBodyCenterToScreenCenter(), targetZoom);
    _animateCameraTo(_Camera(offset: targetOffset, zoom: targetZoom));
  }

  _Resolved? _hitShard(Offset tap, {double minSize = 0}) {
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final focus = _activeFocus;
    _Resolved? hit;
    var bestScore = 34.0; // 像素命中半径
    for (final r in _displayResolved) {
      if (focus != null && r.shard.bodyIndex != focus) continue;
      final size = _screenSize(r.depth);
      if (size < minSize) continue; // 太小的点不算「可点照片」
      final screen = (r.world + _camera.offset) * _camera.zoom + center;
      if ((screen.dx - tap.dx).abs() > bestScore * 2 ||
          (screen.dy - tap.dy).abs() > bestScore * 2) {
        continue;
      }
      final dist = (screen - tap).distance - size * 0.45;
      if (dist < bestScore) {
        bestScore = dist;
        hit = r;
      }
    }
    return hit;
  }

  /// 宏观态下按星体整体做命中（双击进入专注态用）
  int? _hitBody(Offset tap) {
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    int? hit;
    var best = double.infinity;
    for (var i = 0; i < _bodies.length; i++) {
      final b = _bodies[i];
      final screen = (b.center + _camera.offset) * _camera.zoom + center;
      final radius = b.extent * _camera.zoom * 1.25 + 20;
      final d = (screen - tap).distance;
      if (d < radius && d < best) {
        best = d;
        hit = i;
      }
    }
    return hit;
  }

  // ---- 专注态进出 ----

  void _enterFocus(int bodyIndex) {
    _stopInertia();
    _stopZoomAnim();
    _overviewCamera = _camera;
    _focusBody = bodyIndex;
    _lastFocusBody = bodyIndex;
    _userYaw = 0;
    _userTilt = 0;
    _bubbleBody = null;
    _setFocusMode(true);
    final b = _bodies[bodyIndex];
    _focusFitZoom =
        (math.min(_viewport.width, _viewport.height) * 0.36 / b.extent)
            .clamp(0.5, 1.4)
            .toDouble();
    _runFocusAnim(
      to: _Camera(offset: -b.center, zoom: _focusFitZoom),
      mixTo: 1,
      yawTo: 0,
      tiltTo: 0,
    );
  }

  void _exitFocus() {
    if (_focusBody == null) return;
    _focusBody = null;
    _resetWall();
    _setFocusMode(false);
    _runFocusAnim(to: _overviewCamera, mixTo: 0, yawTo: 0, tiltTo: 0);
  }

  /// 进/退专注态的过渡动画：相机 + 淡出程度 + 拨转角一起归位
  void _runFocusAnim({
    required _Camera to,
    required double mixTo,
    required double yawTo,
    required double tiltTo,
  }) {
    _stopZoomAnim();
    _zoomAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    final curve =
        CurvedAnimation(parent: _zoomAnim!, curve: Curves.easeOutCubic);
    final zoomTween = Tween<double>(begin: _camera.zoom, end: to.zoom);
    final offsetTween =
        Tween<Offset>(begin: _camera.offset, end: to.offset);
    final mixTween = Tween<double>(begin: _focusMix, end: mixTo);
    final yawTween = Tween<double>(begin: _userYaw, end: yawTo);
    final tiltTween = Tween<double>(begin: _userTilt, end: tiltTo);
    void listener() {
      setState(() {
        _camera = _Camera(
          offset: offsetTween.evaluate(curve),
          zoom: zoomTween.evaluate(curve),
        );
        _focusMix = mixTween.evaluate(curve);
        _userYaw = yawTween.evaluate(curve);
        _userTilt = tiltTween.evaluate(curve);
      });
    }

    _zoomAnim!.addListener(listener);
    _zoomAnim!.forward().whenComplete(() {
      _zoomAnim?.removeListener(listener);
      _stopZoomAnim();
    });
  }

  void _animateCameraTo(_Camera target, {VoidCallback? onDone}) {
    _stopZoomAnim();
    _zoomAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    final curve = CurvedAnimation(
      parent: _zoomAnim!,
      curve: Curves.easeOutCubic,
    );
    final zoomTween = Tween<double>(begin: _camera.zoom, end: target.zoom);
    final offsetTween =
        Tween<Offset>(begin: _camera.offset, end: target.offset);
    void listener() {
      setState(() {
        _camera = _Camera(
          offset: offsetTween.evaluate(curve),
          zoom: zoomTween.evaluate(curve),
        );
      });
    }

    _zoomAnim!.addListener(listener);
    _zoomAnim!.forward().whenComplete(() {
      _zoomAnim?.removeListener(listener);
      _stopZoomAnim();
      onDone?.call();
    });
  }

  // ---- 搜索 / 飞向指定星体 ----

  void _openSearch() {
    setState(() {
      _searchOpen = true;
      _searchQuery = '';
      _searchController.clear();
      _bubbleBody = null;
    });
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    setState(() => _searchOpen = false);
  }

  /// 搜索结果被点击：从当前位置平滑滑到那颗星体，顺势进入专注态（非硬切）
  void _flyToBody(int i) {
    _closeSearch();
    if (i < 0 || i >= _bodies.length) return;
    _stopInertia();
    _stopSpinInertia();
    final b = _bodies[i];
    if (_focusBody != null) {
      // 已在专注态：直接平滑切换到另一颗
      _focusBody = i;
      _lastFocusBody = i;
      _userYaw = 0;
      _userTilt = 0;
      _setFocusMode(true);
      _focusFitZoom =
          (math.min(_viewport.width, _viewport.height) * 0.36 / b.extent)
              .clamp(0.5, 1.4)
              .toDouble();
      _runFocusAnim(
        to: _Camera(offset: -b.center, zoom: _focusFitZoom),
        mixTo: 1,
        yawTo: 0,
        tiltTo: 0,
      );
      return;
    }
    // 两段式：先在宏观视野里滑到目标星体跟前，再进入专注态
    final panZoom = math.max(_camera.zoom, 0.3);
    _animateCameraTo(
      _Camera(offset: _clampOffset(-b.center, panZoom), zoom: panZoom),
      onDone: () => _enterFocus(i),
    );
  }

  // ---- 星体命名 ----

  Map<int, int> _bodyPhotoCounts() {
    final counts = <int, int>{};
    for (final s in _shards) {
      counts[s.bodyIndex] = (counts[s.bodyIndex] ?? 0) + 1;
    }
    return counts;
  }

  /// 重名检测：与其他星体的名字比对（忽略大小写与首尾空格）
  bool _isDuplicateBodyName(String name, {int? exceptIndex}) {
    final key = name.trim().toLowerCase();
    if (key.isEmpty) return false;
    for (var i = 0; i < _bodies.length; i++) {
      if (i == exceptIndex) continue;
      final n = _bodies[i].name;
      if (n != null && n.trim().toLowerCase() == key) return true;
    }
    return false;
  }

  /// 长按名字气泡：编辑星体名字（带重名检测）
  Future<void> _editBodyName(int index) async {
    if (index >= _bodies.length) return;
    final controller = TextEditingController(text: _bodies[index].name ?? '');
    String? errorText;
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          void trySave() {
            final name = controller.text.trim();
            if (_isDuplicateBodyName(name, exceptIndex: index)) {
              setDialogState(() => errorText = '「$name」已经被另一颗星体使用了');
              return;
            }
            Navigator.of(ctx).pop(name);
          }

          return AlertDialog(
            backgroundColor: StarryTheme.nebula,
            title: const Text(
              '给这颗星体起个名字',
              style: TextStyle(fontSize: 15, color: StarryTheme.starLight),
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 20,
              style:
                  const TextStyle(fontSize: 14, color: StarryTheme.starLight),
              onChanged: (_) {
                if (errorText != null) {
                  setDialogState(() => errorText = null);
                }
              },
              decoration: InputDecoration(
                hintText: '比如：那年的夏天',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: StarryTheme.starDim.withValues(alpha: 0.6),
                ),
                errorText: errorText,
                errorStyle:
                    const TextStyle(fontSize: 11, color: Color(0xFFE88B9A)),
                counterStyle:
                    const TextStyle(fontSize: 10, color: StarryTheme.starDim),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: StarryTheme.starPurple),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: StarryTheme.warmGlow),
                ),
              ),
              onSubmitted: (_) => trySave(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消',
                    style: TextStyle(color: StarryTheme.starDim)),
              ),
              TextButton(
                onPressed: trySave,
                child: const Text('保存',
                    style: TextStyle(color: StarryTheme.starPurple)),
              ),
            ],
          );
        },
      ),
    );
    // 对话框退出动画还在播放时 TextField 仍在树里，controller 延迟一帧再释放
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
    if (saved == null || !mounted) return;
    final name = saved.trim();
    await _persistBodyNames({index: name.isEmpty ? null : name});
  }

  /// 把名字写进 star_layout.json。
  /// 若原本是自动编排（无编排文件），此刻把当前星体的类型/位置/容量
  /// 原样固化下来，再叠上名字——星野外观不发生任何变化。
  Future<void> _persistBodyNames(Map<int, String?> updates) async {
    final counts = _bodyPhotoCounts();
    final bodies = <StarLayoutBody>[
      for (var j = 0; j < _bodies.length; j++)
        StarLayoutBody(
          type: _bodies[j].type.name,
          cx: _bodies[j].center.dx,
          cy: _bodies[j].center.dy,
          cap: counts[j] ?? 1,
          name: updates.containsKey(j) ? updates[j] : _bodies[j].name,
        ),
    ];
    await StarLayoutService.save(StarLayout(bodies));
    if (!mounted) return;
    setState(() {
      updates.forEach((j, n) {
        if (j < _bodies.length) _bodies[j].name = n;
      });
    });
    // 让 provider 重新读文件（推迟一帧：等命名对话框的路由退出动画
    // 完全结束，避免重建撞上路由卸载触发框架断言）；
    // 配合 _effectiveLayout 粘性缓存，重建视觉无感
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(starLayoutProvider);
    });
  }

  // ---- 右上角三条杠菜单 ----

  void _openMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: StarryTheme.nebula,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        // 横屏下高度受限，包一层滚动防 BOTTOM OVERFLOWED
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            const SizedBox(height: 6),
            ListTile(
              leading:
                  const Icon(Icons.search, color: StarryTheme.warmGlow),
              title: const Text('搜索星体',
                  style: TextStyle(color: StarryTheme.starLight)),
              subtitle: const Text('按名字找到那颗星，直接飞过去',
                  style:
                      TextStyle(fontSize: 11, color: StarryTheme.starDim)),
              onTap: () {
                Navigator.of(ctx).pop();
                _openSearch();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined,
                  color: StarryTheme.starPurple),
              title: const Text('相册导入',
                  style: TextStyle(color: StarryTheme.starLight)),
              subtitle: const Text('自动导入，或自定义编排星体',
                  style:
                      TextStyle(fontSize: 11, color: StarryTheme.starDim)),
              onTap: () {
                Navigator.of(ctx).pop();
                ImportFlow.pickAndRun(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_special_outlined,
                  color: StarryTheme.starPurple),
              title: const Text('备份与恢复',
                  style: TextStyle(color: StarryTheme.starLight)),
              subtitle: const Text('导出 / 导入 .nianlun 备份文件',
                  style:
                      TextStyle(fontSize: 11, color: StarryTheme.starDim)),
              onTap: () {
                Navigator.of(ctx).pop();
                showBackupSheet(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt,
                  color: StarryTheme.starDim),
              title: const Text('重置星体编排',
                  style: TextStyle(color: StarryTheme.starLight)),
              subtitle: const Text('清除所有星体的名字与摆位，恢复自动编排',
                  style:
                      TextStyle(fontSize: 11, color: StarryTheme.starDim)),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmResetLayout();
              },
            ),
            const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 重置星体编排：删除 star_layout.json，恢复自动编排。
  /// 只影响星体的名字/位置/容量分配，照片与日记数据一概不动。
  Future<void> _confirmResetLayout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: StarryTheme.nebula,
        title: const Text(
          '重置星体编排？',
          style: TextStyle(fontSize: 15, color: StarryTheme.starLight),
        ),
        content: const Text(
          '所有星体的名字和摆放位置都会被清除，星野恢复为自动编排。\n\n照片、日记、音乐等数据不受影响。',
          style: TextStyle(fontSize: 13, color: StarryTheme.starDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消',
                style: TextStyle(color: StarryTheme.starDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('重置',
                style: TextStyle(color: StarryTheme.warmGlow)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await StarLayoutService.clear();
    if (!mounted) return;
    setState(() {
      // 连粘性缓存一起清，否则刷新期间会继续沿用旧编排，重置不生效
      _effectiveLayout = null;
      _bubbleBody = null;
      _rebuildShards();
    });
    // 后台同步 provider（reload 返回 null，其他监听者保持一致）
    ref.invalidate(starLayoutProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复为自动编排')),
    );
  }

  // ---- 惯性（相机平移 / 星体拨转）----

  void _startInertia(Offset screenVelocity) {
    _stopInertia();
    var v = screenVelocity;
    const maxSpeed = 3000.0; // 初速度封顶，避免一甩飞出半条银河
    if (v.distance > maxSpeed) {
      v = v / v.distance * maxSpeed;
    }
    _inertiaVelocity = v / math.max(_camera.zoom, 0.05);
    _lastInertiaTime = DateTime.now();
    _inertiaTicker = createTicker(_onInertiaTick)..start();
  }

  void _onInertiaTick(Duration elapsed) {
    final now = DateTime.now();
    final dt = _lastInertiaTime == null
        ? 0.016
        : now.difference(_lastInertiaTime!).inMicroseconds / 1e6;
    _lastInertiaTime = now;

    final newOffset = _clampOffset(
      _camera.offset + _inertiaVelocity * dt,
      _camera.zoom,
    );
    _inertiaVelocity = _inertiaVelocity *
        math.pow(0.03, dt).toDouble(); // 强阻尼，约 0.35s 停下

    setState(() => _camera = _Camera(offset: newOffset, zoom: _camera.zoom));

    if (_inertiaVelocity.distance < 30) {
      _stopInertia();
    }
  }

  void _stopInertia() {
    _inertiaTicker?.stop();
    _inertiaTicker?.dispose();
    _inertiaTicker = null;
    _inertiaVelocity = Offset.zero;
  }

  void _startSpinInertia() {
    _stopSpinInertia();
    _lastSpinTime = DateTime.now();
    _spinTicker = createTicker(_onSpinTick)..start();
  }

  void _onSpinTick(Duration elapsed) {
    final now = DateTime.now();
    final dt = _lastSpinTime == null
        ? 0.016
        : now.difference(_lastSpinTime!).inMicroseconds / 1e6;
    _lastSpinTime = now;

    final decay = math.pow(0.1, dt).toDouble();
    _yawVel *= decay;
    _tiltVel *= decay;
    setState(() {
      _userYaw += _yawVel * dt;
      _userTilt += _tiltVel * dt; // 俯仰无上限，可整圈翻转
    });

    if (_yawVel.abs() < 0.05 && _tiltVel.abs() < 0.05) {
      _stopSpinInertia();
    }
  }

  void _stopSpinInertia() {
    _spinTicker?.stop();
    _spinTicker?.dispose();
    _spinTicker = null;
  }

  void _stopZoomAnim() {
    _zoomAnim?.stop();
    _zoomAnim?.dispose();
    _zoomAnim = null;
  }

  Offset _nearestBodyCenterToScreenCenter() {
    if (_bodies.isEmpty) return Offset.zero;
    final centerWorld = -_camera.offset; // 屏幕中心对应的世界点
    var best = _bodies.first.center;
    var bestDist = double.infinity;
    for (final b in _bodies) {
      final d = (b.center - centerWorld).distanceSquared;
      if (d < bestDist) {
        bestDist = d;
        best = b.center;
      }
    }
    return best;
  }

  double _screenSize(double depth) {
    return _baseWorldSize * _camera.zoom * (0.55 + 0.45 * depth);
  }

  Offset _clampOffset(Offset offset, double zoom) {
    if (_bodies.isEmpty || _viewport == Size.zero) return offset;

    var minX = double.infinity;
    var maxX = -double.infinity;
    var minY = double.infinity;
    var maxY = -double.infinity;
    for (final b in _bodies) {
      minX = math.min(minX, b.center.dx);
      maxX = math.max(maxX, b.center.dx);
      minY = math.min(minY, b.center.dy);
      maxY = math.max(maxY, b.center.dy);
    }

    final viewPad = math.max(_viewport.width, _viewport.height) / zoom + 240;
    // offset 能让屏幕中心看到世界范围 [-max-viewPad, -min+viewPad]
    return Offset(
      offset.dx.clamp(-maxX - viewPad, -minX + viewPad).toDouble(),
      offset.dy.clamp(-maxY - viewPad, -minY + viewPad).toDouble(),
    );
  }

  // ---------------- 跳转 / 删除 ----------------

  Future<void> _openPhoto(_Shard shard) async {
    // 节点页尚未做横屏适配：进入前锁竖屏，返回后恢复（星河 tab 允许横屏）
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NodePage(
          date: shard.date,
          initialPhotoIndex: shard.indexInDay,
        ),
      ),
    );
    if (!mounted) return;
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  /// 贴片自己处理了点击时，屏蔽父级手动点按，防止二次触发
  void _suppressTap() {
    _suppressTapUntil =
        DateTime.now().add(const Duration(milliseconds: 400));
  }

  Future<void> _confirmRemovePhoto(_Shard shard) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StarryTheme.nebula,
        title: const Text(
          '从「年轮」移除这张照片？',
          style: TextStyle(fontSize: 16, color: StarryTheme.starLight),
        ),
        content: Text(
          '只会删除年轮里的副本，系统相册中的原图不受影响。\n'
          '${shard.date.year}.${shard.date.month}.${shard.date.day}',
          style: const TextStyle(
            fontSize: 13,
            color: StarryTheme.starDim,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消',
                style: TextStyle(color: StarryTheme.starDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除',
                style: TextStyle(color: StarryTheme.starPurple)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    await ref.read(mediaAttachServiceProvider).removePhoto(shard.photo);
    refreshAllDays(ref);
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    final totalPhotos = _shards.length;
    final dayCount = widget.days.where((d) => d.hasPhotos).length;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final focus = _activeFocus;
    // 横屏 = 纯净观星模式：顶栏滑出、提示条贴底（与 main.dart 的 Tab 栏联动）
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final hideTopChrome = _focusBody != null || isLandscape;

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);

        // 首帧按星体包围盒自动取景（星体多了也能全部入画）
        if (_needsFraming && _viewport != Size.zero && _bodies.isNotEmpty) {
          _needsFraming = false;
          var maxR = 1.0;
          for (final b in _bodies) {
            maxR = math.max(maxR, b.center.distance + b.extent);
          }
          final z = (math.min(_viewport.width, _viewport.height) * 0.46 /
                  maxR)
              .clamp(_minZoom, 0.9)
              .toDouble();
          _camera = _Camera(zoom: z, offset: Offset.zero);
        }

        final resolved = _resolve();
        _fillDisplayResolved(resolved);
        final overlays = _buildOverlays(dpr, _displayResolved);
        final gateOpen = _camera.zoom * _baseWorldSize >= _imageThreshold;

        return Stack(
          fit: StackFit.expand,
          children: [
            // 宇宙底：星云团 + 闪烁星空 + 尘埃（视差）
            // 两层 CustomPaint 各自套 RepaintBoundary，重绘互不牵连
            RepaintBoundary(
              child: CustomPaint(
                size: _viewport,
                painter: _CosmosPainter(camera: _camera, time: _motionT),
                child: const SizedBox.expand(),
              ),
            ),
            // 未放大到阈值的照片全部用 CustomPaint 画成点（含星体光晕）
            RepaintBoundary(
              child: CustomPaint(
                size: _viewport,
                painter: _PhotoFieldPainter(
                  resolved: _displayResolved,
                  bodies: _bodies,
                  camera: _camera,
                  viewport: _viewport,
                  baseSize: _baseWorldSize,
                  dotThreshold: _dotThreshold,
                  motionStamp: _motionT,
                  focusIndex: focus,
                  focusMix: _focusMix,
                  gateOpen: gateOpen,
                  wallMix: _wallMix,
                ),
              ),
            ),
            // 放大后可见的真实照片
            ...overlays,
            // 手势层（半透明，让子元素也能收到 tap / long press）
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
              ),
            ),
            // 顶部操作栏（专注态时向上滑出，退出后滑回；与底部 Tab 栏对称）
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: AnimatedSlide(
                  offset: hideTopChrome
                      ? const Offset(0, -1.3)
                      : Offset.zero,
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: hideTopChrome ? 0 : 1,
                    duration: const Duration(milliseconds: 300),
                    child: _RiverHeader(
                      totalPhotos: totalPhotos,
                      dayCount: dayCount,
                      onMenu: _openMenu,
                    ),
                  ),
                ),
              ),
            ),
            // 星体名字气泡（宏观态点星体弹出；长按气泡可命名）
            if (_bubbleBody != null &&
                _focusBody == null &&
                _bubbleBody! < _bodies.length)
              ..._buildNameBubble(),
            // 搜索面板（菜单里「搜索星体」打开）
            if (_searchOpen) _buildSearchPanel(),
            // 手势提示（宏观态左对齐并给右下 FAB 让位；专注态/星墙居中贴底）
            if (totalPhotos > 0)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                left: _focusBody != null ? 0 : 16,
                right: _focusBody != null ? 0 : 88,
                bottom: hideTopChrome ? 14 : 100,
                child: Align(
                  alignment: _focusBody != null
                      ? Alignment.center
                      : Alignment.centerLeft,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _focusBody != null
                          ? 1
                          : (_camera.zoom > 1.0 ? 0 : 1),
                      duration: const Duration(milliseconds: 220),
                      child: _GestureHint(
                        text: _wallOpen
                            ? '上下拖动浏览星墙 · 点击照片进入那一天 · 捏小回到星体'
                            : _focusBody != null
                                ? '拨动旋转星体 · 捏合放大看照片 · 双指捏小返回银河'
                                : '捏合展开星体 · 双击进入专注 · 点星体看名字',
                      ),
                    ),
                  ),
                ),
              ),
            // 专注态：平铺浏览 / 回到星体 切换按钮
            if (_focusBody != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 54,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      _suppressTap();
                      if (_wallOpen) {
                        _closeWall();
                      } else {
                        _openWall();
                      }
                    },
                    child: _FocusGridButton(
                      count: _focusPhotoCount(),
                      wallOpen: _wallOpen,
                    ),
                  ),
                ),
              ),
            // 空态
            if (totalPhotos == 0)
              _EmptyRiver(onImport: () => ImportFlow.pickAndRun(context, ref)),
          ],
        );
      },
    );
  }

  /// 宏观态名字气泡：跟随星体屏幕位置，点气泡关闭，长按进入命名
  List<Widget> _buildNameBubble() {
    final i = _bubbleBody!;
    final b = _bodies[i];
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final screen = (b.center + _camera.offset) * _camera.zoom + center;
    final bodyR = b.extent * _camera.zoom * 1.1;
    const bubbleW = 182.0;
    final left = (screen.dx - bubbleW / 2)
        .clamp(8.0, math.max(8.0, _viewport.width - bubbleW - 8));
    final top = (screen.dy - bodyR - 84)
        .clamp(8.0, math.max(8.0, _viewport.height - 90));
    final hasName = b.name != null && b.name!.isNotEmpty;
    return [
      Positioned(
        left: left.toDouble(),
        top: top.toDouble(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _suppressTap();
            setState(() => _bubbleBody = null);
          },
          onLongPress: () {
            _suppressTap();
            _editBodyName(i);
          },
          child: CosmosBubble(
            title: hasName ? b.name! : '无名星体',
            subtitle: hasName ? '长按气泡可改名' : '长按气泡给它起个名字',
          ),
        ),
      ),
    ];
  }

  /// 搜索面板：按名字模糊匹配星体，点击结果平滑飞入该星体专注态
  Widget _buildSearchPanel() {
    final q = _searchQuery.trim().toLowerCase();
    final counts = _bodyPhotoCounts();
    final results = <int>[];
    for (var i = 0; i < _bodies.length; i++) {
      final name = _bodies[i].name;
      if (q.isEmpty) {
        if (name != null && name.isNotEmpty) results.add(i);
      } else if (name != null && name.toLowerCase().contains(q)) {
        results.add(i);
      }
    }
    final anyNamed = _bodies.any((b) => b.name != null && b.name!.isNotEmpty);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Container(
            decoration: BoxDecoration(
              color: StarryTheme.nebula.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: StarryTheme.starPurple.withValues(alpha: 0.35),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 14),
                    const Icon(Icons.search,
                        size: 18, color: StarryTheme.starPurple),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        onChanged: (v) => setState(() => _searchQuery = v),
                        style: const TextStyle(
                            fontSize: 14, color: StarryTheme.starLight),
                        decoration: InputDecoration(
                          hintText: '输入星体的名字…',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color:
                                StarryTheme.starDim.withValues(alpha: 0.6),
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: StarryTheme.starDim),
                      onPressed: _closeSearch,
                    ),
                  ],
                ),
                if (results.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: results.length,
                      itemBuilder: (context, idx) {
                        final i = results[idx];
                        final b = _bodies[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(_bodyIcon(b.type),
                              size: 18, color: b.glow),
                          title: Text(
                            b.name!,
                            style: const TextStyle(
                                fontSize: 13,
                                color: StarryTheme.starLight),
                          ),
                          subtitle: Text(
                            '${StarLayoutService.displayNameOf(b.type.name)} · ${counts[i] ?? 0} 张照片',
                            style: const TextStyle(
                                fontSize: 10,
                                color: StarryTheme.starDim),
                          ),
                          trailing: const Icon(Icons.north_east,
                              size: 14, color: StarryTheme.starDim),
                          onTap: () => _flyToBody(i),
                        );
                      },
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Text(
                      anyNamed
                          ? '没有名字里包含「$_searchQuery」的星体'
                          : '还没有被命名的星体：回到星野，点击一颗星体，长按弹出的气泡就能给它起名字',
                      style: const TextStyle(
                          fontSize: 11,
                          color: StarryTheme.starDim,
                          height: 1.5),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _bodyIcon(_BodyType t) => switch (t) {
        _BodyType.sphere => Icons.public,
        _BodyType.ring => Icons.toll,
        _BodyType.spiral => Icons.blur_circular,
        _BodyType.cloud => Icons.cloud_outlined,
      };

  int _cacheBucket(double width, double dpr) {
    final need = width * dpr * 1.2;
    for (final b in _cacheBuckets) {
      if (b >= need) return b;
    }
    return _cacheBuckets.last;
  }

  List<Widget> _buildOverlays(double dpr, List<_Resolved> resolved) {
    if (_viewport == Size.zero || resolved.isEmpty) {
      return const [];
    }
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    const margin = 80.0;
    final focus = _activeFocus;
    final gateOpen = _camera.zoom * _baseWorldSize >= _imageThreshold;
    final picked = <Widget>[];

    // resolved 按深度升序：从尾部（最靠近观察者）往前挑贴片名额，
    // 最后反向入栈，保持「远先近后」的叠盖顺序
    for (var i = resolved.length - 1; i >= 0 && picked.length < _maxTiles; i--) {
      final r = resolved[i];
      // 专注态下只显示主体星体的贴片
      if (focus != null && r.shard.bodyIndex != focus) {
        continue;
      }
      final inWall =
          _wallMix > 0 && focus != null && r.shard.bodyIndex == focus;
      // 星体级闸门：整颗星体前后全贴（远的更小更暗，立体感靠排布与深浅）
      if (!inWall && !gateOpen) {
        continue;
      }

      final ease = _easeByShard[r.shard] ?? 0;
      final size3d = _screenSize(r.depth);
      // NaN/无穷防御：坏数据（宽高为 0 的照片）不能让布局直接崩溃
      var ar = r.shard.photo.aspectRatio;
      if (ar.isNaN || ar.isInfinite || ar <= 0) ar = 3 / 4;
      ar = ar.clamp(0.35, 2.8).toDouble();
      double rawW;
      double rawH;
      if (inWall) {
        // 三维尺寸 → 星墙槽位尺寸 的平滑形变
        final slotW = _wallSlotW * _camera.zoom;
        final slotH = _wallSlotH * _camera.zoom;
        rawW = size3d + (slotW - size3d) * ease;
        rawH = size3d / ar + (slotH - size3d / ar) * ease;
      } else {
        rawW = size3d;
        rawH = size3d / ar;
      }

      final screen = (r.world + _camera.offset) * _camera.zoom + center;
      if (screen.dx + rawW < -margin ||
          screen.dy + rawH < -margin ||
          screen.dx - rawW > _viewport.width + margin ||
          screen.dy - rawH > _viewport.height + margin) {
        continue;
      }

      // 宽/高按 6px 量化：只在跨档时重新 layout/重绘
      final width = (rawW.clamp(18.0, 150.0) / 6).round() * 6.0;
      final height = (rawH.clamp(14.0, 190.0) / 6).round() * 6.0;
      final cacheWidth = _cacheBucket(width, dpr);
      // 远近明暗：背面/侧面的贴片更小更暗，组成真正的立体感
      var depthAlpha = (0.30 + 0.70 * r.depth).clamp(0.0, 1.0);
      if (depthAlpha.isNaN) depthAlpha = 1.0;

      Widget tile = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        builder: (context, v, child) => Opacity(
          opacity: v,
          child: Transform.scale(scale: 0.72 + 0.28 * v, child: child),
        ),
        child: _PhotoTile(
          shard: r.shard,
          rootPath: widget.rootPath,
          width: width,
          height: height,
          cacheWidth: cacheWidth,
          onTap: () {
            _suppressTap();
            _openPhoto(r.shard);
          },
          onLongPress: () {
            _suppressTap();
            _confirmRemovePhoto(r.shard);
          },
        ),
      );
      if (depthAlpha < 0.99) {
        tile = Opacity(opacity: depthAlpha, child: tile);
      }

      picked.add(
        Positioned(
          // 用数据库行 id 做 key（天然唯一）：历史遗留的重复照片记录
          // （同 relativePath 不同 id）不会再撞键引发渲染异常
          key: ValueKey(r.shard.photo.id ?? r.shard.photo.relativePath),
          left: screen.dx - width / 2,
          top: screen.dy - height / 2,
          child: tile,
        ),
      );
    }
    return picked.reversed.toList();
  }
}

// ------------------------------------------------------------------
// 数据模型与布局
// ------------------------------------------------------------------

class _Camera {
  final Offset offset;
  final double zoom;
  const _Camera({this.offset = Offset.zero, this.zoom = 1.0});
}

class _Shard {
  final PhotoItem photo;
  final DateTime date;
  final int indexInDay;
  final int bodyIndex; // 所属星体下标
  final _Vec3 local; // 星体局部三维坐标（未加倾角/自转，运动时每帧解算）
  final int seed; // 相位种子（星云脉冲/漂浮用）

  const _Shard({
    required this.photo,
    required this.date,
    required this.indexInDay,
    required this.bodyIndex,
    required this.local,
    required this.seed,
  });
}

/// 一颗星解算后的瞬时状态
class _Resolved {
  final _Shard shard;
  final Offset world;
  final double depth; // 0..1，1 表示最靠近观察者
  const _Resolved(this.shard, this.world, this.depth);
}

/// 星体规格：位置、姿态、运动与配色
class _BodySpec {
  final Offset center;
  final _BodyType type;
  final double tiltX;
  final double tiltY;
  final double spin; // 自转角速度 rad/s（含方向）
  final double phase; // 呼吸相位
  final double extent; // 星体半径量级（光晕范围用）
  final double depthScale; // 深度归一化除数
  final Color glow; // 光晕配色
  String? name; // 星体名字（可编辑，持久化在 star_layout.json）

  _BodySpec({
    required this.center,
    required this.type,
    required this.tiltX,
    required this.tiltY,
    required this.spin,
    required this.phase,
    required this.extent,
    required this.depthScale,
    required this.glow,
    this.name,
  });
}

enum _BodyType { sphere, ring, spiral, cloud }

_BodyType _bodyTypeFromName(String name) => switch (name) {
      'ring' => _BodyType.ring,
      'spiral' => _BodyType.spiral,
      'cloud' => _BodyType.cloud,
      _ => _BodyType.sphere,
    };

class _Vec3 {
  final double x;
  final double y;
  final double z;
  const _Vec3(this.x, this.y, this.z);

  _Vec3 rotateX(double rad) {
    final c = math.cos(rad);
    final s = math.sin(rad);
    return _Vec3(x, y * c - z * s, y * s + z * c);
  }

  _Vec3 rotateY(double rad) {
    final c = math.cos(rad);
    final s = math.sin(rad);
    return _Vec3(x * c + z * s, y, -x * s + z * c);
  }
}

double _tiltXFor(_BodyType type, math.Random rand) => switch (type) {
      _BodyType.sphere => 0.42 + rand.nextDouble() * 0.32,
      _BodyType.ring => 0.42 + rand.nextDouble() * 0.22,
      _BodyType.spiral => 0.22 + rand.nextDouble() * 0.18,
      _BodyType.cloud => rand.nextDouble() * 0.42,
    };

double _spinFor(_BodyType type, math.Random rand, int bodyIndex) {
  final base = switch (type) {
    _BodyType.sphere => 0.12,
    _BodyType.ring => 0.22,
    _BodyType.spiral => 0.10,
    _BodyType.cloud => 0.045,
  };
  final jitter = 0.85 + rand.nextDouble() * 0.3;
  final dir = bodyIndex.isEven ? 1.0 : -1.0; // 相邻星体反向自转，更有层次
  return base * jitter * dir;
}

double _extentFor(_BodyType type) => switch (type) {
      _BodyType.sphere => 135,
      _BodyType.ring => 165,
      _BodyType.spiral => 205,
      _BodyType.cloud => 185,
    };

double _depthScaleFor(_BodyType type) => switch (type) {
      _BodyType.sphere => 135,
      _BodyType.ring => 165,
      _BodyType.spiral => 205,
      _BodyType.cloud => 210,
    };

Color _glowFor(_BodyType type) => switch (type) {
      _BodyType.sphere => const Color(0xFFFFCF9E), // 暖金
      _BodyType.ring => const Color(0xFF9FD8FF), // 冰蓝
      _BodyType.spiral => const Color(0xFFB9A6FF), // 星紫
      _BodyType.cloud => const Color(0xFFF0A8D8), // 霓粉
    };

/// 星体编排：
/// - 有自定义编排（StarLayout）时，照片按拍摄日期升序，按编排顺序与容量
///   依次切块装进指定类型、指定位置的星体
/// - 容量装不下的溢出照片（或没有编排时），用黄金角 + 递增半径螺旋自动成星体
({List<_Shard> shards, List<_BodySpec> bodies}) _buildShards(
    List<DaySummary> days, StarLayout? layout) {
  final items = <({PhotoItem photo, DateTime date, int index})>[];
  for (final day in days) {
    for (var i = 0; i < day.photos.length; i++) {
      items.add((
        photo: day.photos[i],
        date: day.date,
        index: i,
      ));
    }
  }
  if (items.isEmpty) {
    return (shards: const <_Shard>[], bodies: const <_BodySpec>[]);
  }

  // 按时间顺序排列，让相邻日子的照片在星体里相邻
  items.sort((a, b) => a.date.compareTo(b.date));

  final total = items.length;
  final shards = <_Shard>[];
  final bodies = <_BodySpec>[];
  var cursor = 0;
  var bi = 0;

  void addBody(_BodyType type, Offset center, int start, int end,
      {String? name}) {
    final rand = math.Random(bi * 7777 + 13);
    bodies.add(_BodySpec(
      center: center,
      type: type,
      tiltX: _tiltXFor(type, rand),
      tiltY: rand.nextDouble() * math.pi * 2,
      spin: _spinFor(type, rand, bi),
      phase: rand.nextDouble() * math.pi * 2,
      extent: _extentFor(type),
      depthScale: _depthScaleFor(type),
      glow: _glowFor(type),
      name: name,
    ));
    final locals = _layoutBody(type, end - start, bi);
    for (var i = start; i < end; i++) {
      final item = items[i];
      shards.add(_Shard(
        photo: item.photo,
        date: item.date,
        indexInDay: item.index,
        bodyIndex: bi,
        local: locals[i - start],
        seed: i,
      ));
    }
    bi++;
  }

  // 1) 自定义编排的星体优先
  final custom = layout?.bodies ?? const <StarLayoutBody>[];
  for (final lb in custom) {
    if (cursor >= total) break;
    final end = math.min(cursor + lb.cap, total);
    addBody(_bodyTypeFromName(lb.type), Offset(lb.cx, lb.cy), cursor, end,
        name: lb.name);
    cursor = end;
  }

  // 2) 溢出照片（或没有编排时）：自动黄金螺旋星体
  if (cursor < total) {
    final remaining = total - cursor;
    final autoCount = (remaining / 28).ceil();
    final groupSize = (remaining / autoCount).ceil();
    final golden = math.pi * (3 - math.sqrt(5));
    while (cursor < total) {
      final end = math.min(cursor + groupSize, total);
      final type = _BodyType.values[bi % _BodyType.values.length];
      final angle = bi * golden;
      // 递增半径螺旋：星体之间留足距离，不再重叠
      final radius = 620.0 + bi * 110.0;
      final center = Offset(
        math.cos(angle) * radius,
        math.sin(angle) * radius * 0.8 + (bi.isEven ? 60 : -60),
      );
      addBody(type, center, cursor, end);
      cursor = end;
    }
  }

  return (shards: shards, bodies: bodies);
}

/// 返回星体局部的原始三维坐标（不加倾角，运动解算在 _resolve 里做）
List<_Vec3> _layoutBody(_BodyType type, int count, int seed) {
  switch (type) {
    case _BodyType.sphere:
      return _layoutSphere(count);
    case _BodyType.ring:
      return _layoutRing(count, seed);
    case _BodyType.spiral:
      return _layoutSpiral(count, seed);
    case _BodyType.cloud:
      return _layoutCloud(count, seed);
  }
}

List<_Vec3> _layoutSphere(int count) {
  if (count <= 0) return [];
  if (count == 1) return const [_Vec3(0, 0, 0)];

  const radius = 135.0;
  final goldenAngle = math.pi * (3 - math.sqrt(5));
  final result = <_Vec3>[];

  for (var i = 0; i < count; i++) {
    final yNorm = 1 - (i / (count - 1)) * 2; // 1 .. -1
    final r = math.sqrt(1 - yNorm * yNorm);
    final theta = goldenAngle * i;
    result.add(_Vec3(
      r * math.cos(theta) * radius,
      yNorm * radius,
      r * math.sin(theta) * radius,
    ));
  }
  return result;
}

/// 星环 = 圆柱面：照片沿 Y 轴分多圈排布在圆柱侧面上，鼓形立体感
List<_Vec3> _layoutRing(int count, int seed) {
  if (count <= 0) return [];
  if (count == 1) return const [_Vec3(0, 0, 0)];

  final rand = math.Random(seed * 54321);
  const R = 150.0; // 圆柱半径
  const H = 88.0; // 圆柱半高
  final rows = (count / 9).ceil().clamp(2, 5); // 每圈约 9 张
  final golden = math.pi * (3 - math.sqrt(5));
  final result = <_Vec3>[];

  for (var i = 0; i < count; i++) {
    final row = i % rows;
    final angle = i * golden + (rand.nextDouble() - 0.5) * 0.2;
    final yBase = -H + (row / (rows - 1)) * 2 * H;
    final y = yBase + (rand.nextDouble() - 0.5) * 12;
    final rr = R + (rand.nextDouble() - 0.5) * 12;
    result.add(_Vec3(
      rr * math.cos(angle),
      y,
      rr * math.sin(angle),
    ));
  }
  return result;
}

List<_Vec3> _layoutSpiral(int count, int seed) {
  if (count <= 0) return [];
  if (count == 1) return const [_Vec3(0, 0, 0)];

  final rand = math.Random(seed * 98765);
  const arms = 2;
  const maxR = 175.0;
  const revs = 1.55;
  final result = <_Vec3>[];

  for (var i = 0; i < count; i++) {
    final arm = i % arms;
    final t = i / (count - 1);
    final armOffset = arm * 2 * math.pi / arms;
    final theta = armOffset +
        t * 2 * math.pi * revs +
        (rand.nextDouble() - 0.5) * 0.28;
    final r = 28 + maxR * math.pow(t, 0.55);
    result.add(_Vec3(
      r * math.cos(theta),
      r * math.sin(theta),
      (rand.nextDouble() - 0.5) * 24,
    ));
  }
  return result;
}

List<_Vec3> _layoutCloud(int count, int seed) {
  if (count <= 0) return [];
  if (count == 1) return const [_Vec3(0, 0, 0)];

  final rand = math.Random(seed * 11111);
  const sigma = 115.0;
  final result = <_Vec3>[];
  for (var i = 0; i < count; i++) {
    final u1 = rand.nextDouble();
    final u2 = rand.nextDouble();
    final radius = sigma * math.sqrt(-2 * math.log(math.max(u1, 1e-9)));
    final angle = 2 * math.pi * u2;
    result.add(_Vec3(
      radius * math.cos(angle),
      radius * math.sin(angle),
      (rand.nextDouble() - 0.5) * sigma * 1.3,
    ));
  }
  return result;
}

// ------------------------------------------------------------------
// 绘制层
// ------------------------------------------------------------------

/// 照片点阵 + 星体光晕
class _PhotoFieldPainter extends CustomPainter {
  final List<_Resolved> resolved;
  final List<_BodySpec> bodies;
  final _Camera camera;
  final Size viewport;
  final double baseSize;
  final double dotThreshold;
  final double motionStamp; // 运动时刻：变化即重绘
  final int? focusIndex; // 专注主体（null = 宏观）
  final double focusMix; // 0 宏观 ↔ 1 专注
  final bool gateOpen; // 星体级贴片闸门：开则点阵整体让位给贴片
  final double wallMix; // 0 星体 ↔ 1 星墙（星墙里点阵淡出）

  const _PhotoFieldPainter({
    required this.resolved,
    required this.bodies,
    required this.camera,
    required this.viewport,
    required this.baseSize,
    required this.dotThreshold,
    required this.motionStamp,
    required this.focusIndex,
    required this.focusMix,
    required this.gateOpen,
    required this.wallMix,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(viewport.width / 2, viewport.height / 2);
    final paint = Paint()..style = PaintingStyle.fill;
    final dimOthers = (focusIndex == null ? 1.0 : 1 - 0.85 * focusMix) *
        (1 - 0.9 * wallMix);

    // 1) 星体光晕 + 星核（低 zoom 或专注态时显形，按星体类型配色）
    if (camera.zoom < 0.95 || focusIndex != null) {
      final k = focusIndex != null
          ? 1.0
          : ((0.95 - camera.zoom) / 0.95).clamp(0.0, 1.0);
      for (var i = 0; i < bodies.length; i++) {
        final b = bodies[i];
        final isFocus = i == focusIndex;
        var alphaK = isFocus ? k * (1 + 0.4 * focusMix) : k * dimOthers;
        // 星墙打开后主体星体的光晕也让位给照片墙
        if (isFocus) alphaK *= (1 - wallMix);
        if (alphaK <= 0.01) continue;
        final screen = (b.center + camera.offset) * camera.zoom + center;
        if (screen.dx < -160 ||
            screen.dx > viewport.width + 160 ||
            screen.dy < -160 ||
            screen.dy > viewport.height + 160) {
          continue;
        }

        final haloR = b.extent * camera.zoom * 1.35 + 56;
        paint.shader = RadialGradient(
          colors: [
            b.glow.withValues(alpha: 0.10 * alphaK),
            b.glow.withValues(alpha: 0.035 * alphaK),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: screen, radius: haloR));
        canvas.drawCircle(screen, haloR, paint);

        // 明亮星核
        final coreR = 22 * camera.zoom + 7;
        paint.shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.20 * alphaK),
            b.glow.withValues(alpha: 0.10 * alphaK),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: screen, radius: coreR * 2.2));
        canvas.drawCircle(screen, coreR * 2.2, paint);
        paint.shader = null;
      }
    }

    // 2) 照片点（resolved 已按深度升序，先画远处）
    if (gateOpen) return; // 贴片闸门一开，点阵整体让位（前后都贴照片）
    for (final r in resolved) {
      final screen = (r.world + camera.offset) * camera.zoom + center;
      final sz = baseSize * camera.zoom * (0.55 + 0.45 * r.depth);
      if (sz < dotThreshold) {
        continue;
      }
      if (screen.dx + sz < 0 ||
          screen.dx - sz > viewport.width ||
          screen.dy + sz < 0 ||
          screen.dy - sz > viewport.height) {
        continue;
      }

      var dim = focusIndex != null && r.shard.bodyIndex != focusIndex
          ? dimOthers
          : 1.0;
      // 星墙过渡期间，主体星体的点阵随贴片淡出让位
      if (focusIndex != null &&
          r.shard.bodyIndex == focusIndex &&
          wallMix > 0) {
        dim *= (1 - wallMix);
      }
      if (dim <= 0.02) continue;
      final base = r.shard.photo.color ?? const Color(0xFFD0CFF5);
      final color = Color.lerp(base, Colors.white, 0.14)!;
      final alpha =
          ((0.35 + 0.55 * r.depth) * (0.55 + camera.zoom * 0.45) * dim)
              .clamp(0.0, 1.0);
      final dotR = math.max(sz / 2, 1.2);

      // 靠近观察者的点加一圈柔光，增强立体感
      if (r.depth > 0.78) {
        paint.color = color.withValues(alpha: alpha * 0.22);
        canvas.drawCircle(screen, dotR * 2.3, paint);
      }
      paint.color = color.withValues(alpha: alpha);
      canvas.drawCircle(screen, dotR, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PhotoFieldPainter old) =>
      old.camera.zoom != camera.zoom ||
      old.camera.offset != camera.offset ||
      old.resolved.length != resolved.length ||
      old.motionStamp != motionStamp ||
      old.focusIndex != focusIndex ||
      old.focusMix != focusMix ||
      old.gateOpen != gateOpen ||
      old.wallMix != wallMix;
}

/// 宇宙背景：星云团 + 三层视差闪烁星星 + 亮星十字芒 + 漂浮尘埃
class _CosmosPainter extends CustomPainter {
  final _Camera camera;
  final double time;

  const _CosmosPainter({required this.camera, required this.time});

  static double _wrap(double v, double m) {
    final r = v % m;
    return r < 0 ? r + m : r;
  }

  void _nebulaBlob(
      Canvas canvas, Offset c, double radius, Color color, double alpha) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha),
          color.withValues(alpha: alpha * 0.4),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: c, radius: radius));
    canvas.drawCircle(c, radius, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // 相机视差基准（屏幕像素）
    final px = camera.offset.dx * camera.zoom;
    final py = camera.offset.dy * camera.zoom;

    // 1) 星云团（极弱视差，营造纵深）
    _nebulaBlob(
      canvas,
      Offset(w * 0.18 + px * 0.05, h * 0.24 + py * 0.05),
      w * 0.52,
      const Color(0xFF3A2E6E),
      0.16,
    );
    _nebulaBlob(
      canvas,
      Offset(w * 0.85 + px * 0.07, h * 0.62 + py * 0.07),
      w * 0.60,
      const Color(0xFF1E3A5E),
      0.14,
    );
    _nebulaBlob(
      canvas,
      Offset(w * 0.45 + px * 0.04, h * 0.88 + py * 0.04),
      w * 0.46,
      const Color(0xFF4E2450),
      0.11,
    );

    // 2) 星星：三层视差 + 闪烁，取模实现无限星野
    final rand = math.Random(2025);
    final count = (w * h / 6200).clamp(70, 260).toInt();
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final layer = i % 3; // 0 远 1 中 2 近
      final par = switch (layer) {
        0 => 0.02,
        1 => 0.05,
        _ => 0.10,
      };
      final x = _wrap(rand.nextDouble() * w + px * par, w);
      final y = _wrap(rand.nextDouble() * h + py * par, h);
      final phase = rand.nextDouble() * math.pi * 2;
      final speed = 0.5 + rand.nextDouble() * 1.4;
      final twinkle = 0.5 + 0.5 * math.sin(time * speed + phase);
      final alpha = (0.06 + 0.20 * twinkle) * (0.55 + layer * 0.25);
      final r = (0.4 + rand.nextDouble() * 1.1) * (0.7 + layer * 0.3);
      paint.color = Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0));
      canvas.drawCircle(Offset(x, y), r, paint);
    }

    // 3) 亮星 + 十字芒
    final bright = math.Random(99);
    final flarePaint = Paint()
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final x = _wrap(bright.nextDouble() * w + px * 0.08, w);
      final y = _wrap(bright.nextDouble() * h + py * 0.08, h);
      final phase = bright.nextDouble() * math.pi * 2;
      final tw = 0.5 + 0.5 * math.sin(time * 0.9 + phase);
      final alpha = 0.22 + 0.42 * tw;
      final c = Offset(x, y);
      paint.color = Colors.white.withValues(alpha: alpha);
      canvas.drawCircle(c, 1.3, paint);
      flarePaint.color = Colors.white.withValues(alpha: alpha * 0.75);
      final len = 3.2 + 2.8 * tw;
      canvas.drawLine(Offset(x - len, y), Offset(x + len, y), flarePaint);
      canvas.drawLine(Offset(x, y - len), Offset(x, y + len), flarePaint);
    }

    // 4) 漂浮尘埃（视差最大，缓慢漂移）
    final dust = math.Random(7);
    for (var i = 0; i < 34; i++) {
      final driftA = dust.nextDouble() * math.pi * 2;
      final drift = 10 + dust.nextDouble() * 22;
      final x = _wrap(
        dust.nextDouble() * w +
            px * 0.16 +
            math.cos(time * 0.12 + driftA) * drift,
        w,
      );
      final y = _wrap(
        dust.nextDouble() * h +
            py * 0.16 +
            math.sin(time * 0.09 + driftA * 1.7) * drift,
        h,
      );
      paint.color = const Color(0xFFC8C6FF)
          .withValues(alpha: 0.05 + dust.nextDouble() * 0.07);
      canvas.drawCircle(Offset(x, y), 0.8 + dust.nextDouble() * 1.4, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CosmosPainter old) =>
      old.time != time ||
      old.camera.zoom != camera.zoom ||
      old.camera.offset != camera.offset;
}

// ------------------------------------------------------------------
// 照片贴片
// ------------------------------------------------------------------

class _PhotoTile extends StatelessWidget {
  final _Shard shard;
  final String rootPath;
  final double width;
  final double height;
  final int cacheWidth;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PhotoTile({
    required this.shard,
    required this.rootPath,
    required this.width,
    required this.height,
    required this.cacheWidth,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(p.join(rootPath, shard.photo.relativePath));
    final showLabel = width > 54;
    // 星墙/大贴片给完整日期，小贴片只给月日（内部下方，更沉浸）
    final label = width >= 84
        ? '${shard.date.year}.${shard.date.month}.${shard.date.day}'
        : '${shard.date.month}.${shard.date.day}';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: RepaintBoundary(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1E3A),
            borderRadius: BorderRadius.circular(showLabel ? 9 : 6),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.38),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
              BoxShadow(
                color: (shard.photo.color ?? StarryTheme.starPurple)
                    .withValues(alpha: 0.20),
                blurRadius: 14,
              ),
            ],
          ),
          padding: const EdgeInsets.all(2.5),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(showLabel ? 6 : 3.5),
                  child: SizedBox(
                    width: double.infinity,
                    height: showLabel ? height - 16 : height - 5,
                    child: Image.file(
                      file,
                      fit: BoxFit.cover,
                      cacheWidth: cacheWidth,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: const Color(0xFF25294A),
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: StarryTheme.starDim.withValues(alpha: 0.6),
                          size: width * 0.25,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (showLabel)
                SizedBox(
                  height: 13,
                  child: Center(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 8.5,
                        color: Color(0xFFBAB6D8),
                        fontWeight: FontWeight.w500,
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
}

// ------------------------------------------------------------------
// UI 组件
// ------------------------------------------------------------------

class _GestureHint extends StatelessWidget {
  final String text;
  const _GestureHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: StarryTheme.nebula.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: StarryTheme.starPurple.withValues(alpha: 0.18),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        child: Text(
          text,
          style: const TextStyle(color: StarryTheme.starDim, fontSize: 11),
        ),
      ),
    );
  }
}

/// 专注态底部的「平铺浏览 / 回到星体」切换按钮
class _FocusGridButton extends StatelessWidget {
  final int count;
  final bool wallOpen;
  const _FocusGridButton({required this.count, required this.wallOpen});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
      decoration: BoxDecoration(
        color: StarryTheme.nebula.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: StarryTheme.starPurple.withValues(alpha: 0.30),
        ),
        boxShadow: [
          BoxShadow(
            color: StarryTheme.starPurple.withValues(alpha: 0.12),
            blurRadius: 16,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            wallOpen ? Icons.auto_awesome : Icons.grid_view_rounded,
            size: 15,
            color: StarryTheme.starPurple,
          ),
          const SizedBox(width: 7),
          Text(
            wallOpen ? '收起星墙，回到星体' : '平铺浏览这 $count 张照片',
            style: const TextStyle(
              color: StarryTheme.starLight,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _RiverHeader extends StatelessWidget {
  final int totalPhotos;
  final int dayCount;
  final VoidCallback onMenu;

  const _RiverHeader({
    required this.totalPhotos,
    required this.dayCount,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 10, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '星河',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w500,
                    color: StarryTheme.starLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  totalPhotos == 0
                      ? '每一颗星，都是那一天的光'
                      : '$dayCount 个日子 · $totalPhotos 颗星',
                  style: const TextStyle(
                    fontSize: 12,
                    color: StarryTheme.starDim,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '菜单',
            icon: const Icon(
              Icons.menu,
              color: StarryTheme.starPurple,
            ),
            onPressed: onMenu,
          ),
        ],
      ),
    );
  }
}

class _EmptyRiver extends StatelessWidget {
  final VoidCallback onImport;
  const _EmptyRiver({required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.auto_awesome, size: 54, color: StarryTheme.warmGlow),
        const SizedBox(height: 18),
        const Text(
          '银河还很安静',
          style: TextStyle(fontSize: 16, color: StarryTheme.starLight),
        ),
        const SizedBox(height: 8),
        const Text(
          '导入你的照片，让它们开始发光',
          style: TextStyle(fontSize: 13, color: StarryTheme.starDim),
        ),
        const SizedBox(height: 26),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: StarryTheme.starPurple,
            foregroundColor: StarryTheme.deepSpace,
          ),
          onPressed: onImport,
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('导入照片'),
        ),
      ],
    );
  }
}

class _ImportDialog extends StatelessWidget {
  final ValueNotifier<ImportProgress?> progress;
  final VoidCallback onCancel;

  const _ImportDialog({
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
          child: const Text(
            '停下',
            style: TextStyle(color: StarryTheme.starDim),
          ),
        ),
      ],
    );
  }
}

abstract final class ImportFlow {
  static Future<void> pickAndRun(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<_ImportChoice>(
      context: context,
      backgroundColor: StarryTheme.nebula,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        // 横屏下高度受限，包一层滚动防 BOTTOM OVERFLOWED
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                '把相册里的照片收进年轮',
                style: TextStyle(fontSize: 15, color: StarryTheme.starLight),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '照片按拍摄日期自动归到那一天，已导入的不会重复。',
                style: TextStyle(
                  fontSize: 12,
                  color: StarryTheme.starDim,
                  height: 1.6,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.auto_fix_high,
                color: StarryTheme.warmGlow,
              ),
              title: const Text(
                '自定义编排导入',
                style: TextStyle(color: StarryTheme.starLight),
              ),
              subtitle: const Text(
                '自己挑星体样式，亲手摆进宇宙',
                style: TextStyle(fontSize: 11, color: StarryTheme.starDim),
              ),
              onTap: () => Navigator.of(ctx).pop(_ImportChoice.custom),
            ),
            ListTile(
              leading: const Icon(
                Icons.all_inclusive,
                color: StarryTheme.starPurple,
              ),
              title: const Text(
                '导入全部照片',
                style: TextStyle(color: StarryTheme.starLight),
              ),
              subtitle: const Text(
                '照片多时耗时久、占空间大',
                style: TextStyle(fontSize: 11, color: StarryTheme.starDim),
              ),
              onTap: () => Navigator.of(ctx).pop(_ImportChoice.all),
            ),
            ListTile(
              leading: const Icon(
                Icons.history,
                color: StarryTheme.starPurple,
              ),
              title: const Text(
                '只导入最近一年',
                style: TextStyle(color: StarryTheme.starLight),
              ),
              subtitle: const Text(
                '推荐，先跑通再补全',
                style: TextStyle(fontSize: 11, color: StarryTheme.starDim),
              ),
              onTap: () => Navigator.of(ctx).pop(_ImportChoice.year),
            ),
            ListTile(
              leading: const Icon(
                Icons.check_circle_outline,
                color: StarryTheme.starPurple,
              ),
              title: const Text(
                '从相册挑选',
                style: TextStyle(color: StarryTheme.starLight),
              ),
              subtitle: const Text(
                '调用系统相册选择照片',
                style: TextStyle(fontSize: 11, color: StarryTheme.starDim),
              ),
              onTap: () => Navigator.of(ctx).pop(_ImportChoice.pick),
            ),
            const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) {
      return;
    }

    if (choice == _ImportChoice.custom) {
      // 自定义编排向导：选来源 → 挑星体 → 摆位置 → 导入（向导内部完成）。
      // 向导未做横屏适配：进入前锁竖屏，返回后恢复
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      if (!context.mounted) return;
      final result = await Navigator.of(context).push<ImportResult?>(
        MaterialPageRoute(builder: (_) => const CustomImportPage()),
      );
      if (context.mounted) {
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
      if (result != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.permissionDenied
                  ? '需要相册权限才能导入照片，请在系统设置里允许「年轮」访问照片'
                  : result.summary,
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    if (choice == _ImportChoice.pick) {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty || !context.mounted) {
        return;
      }
      await _runImportFiles(context, ref, files);
      return;
    }

    await runSince(
      context,
      ref,
      since: choice == _ImportChoice.all
          ? null
          : DateTime.now().subtract(const Duration(days: 365)),
    );
  }

  static Future<void> runSince(
    BuildContext context,
    WidgetRef ref, {
    DateTime? since,
  }) async {
    final service = ref.read(photoImportServiceProvider);
    final progress = ValueNotifier<ImportProgress?>(null);
    var cancelled = false;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportDialog(
        progress: progress,
        onCancel: () => cancelled = true,
      ),
    );

    ImportResult result;
    try {
      result = await service.importFromLibrary(
        since: since,
        onProgress: (value) => progress.value = value,
        isCancelled: () => cancelled,
      );
    } catch (_) {
      result = const ImportResult();
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    refreshAllDays(ref);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.permissionDenied
              ? '需要相册权限才能导入照片，请在系统设置里允许「年轮」访问照片'
              : result.summary,
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  static Future<void> _runImportFiles(
    BuildContext context,
    WidgetRef ref,
    List<XFile> files,
  ) async {
    final service = ref.read(photoImportServiceProvider);
    final progress = ValueNotifier<ImportProgress?>(null);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportDialog(progress: progress, onCancel: () {}),
    );

    ImportResult result;
    try {
      result = await service.importFiles(
        files,
        onProgress: (value) => progress.value = value,
      );
    } catch (_) {
      result = const ImportResult();
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    refreshAllDays(ref);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.summary),
        duration: const Duration(seconds: 4),
      ),
    );
  }
}

enum _ImportChoice { all, year, pick, custom }

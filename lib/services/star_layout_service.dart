import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 自定义星体编排：一颗星体的规格（自定义导入向导产出）
class StarLayoutBody {
  /// 星体类型：sphere / ring / spiral / cloud
  final String type;

  /// 在星野世界坐标系里的中心位置
  final double cx;
  final double cy;

  /// 该星体容纳的照片数（按拍摄日期顺序切块分配）
  final int cap;

  /// 星体名字（可选；在导入向导或星野里命名后持久化）
  final String? name;

  const StarLayoutBody({
    required this.type,
    required this.cx,
    required this.cy,
    required this.cap,
    this.name,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'cx': cx,
        'cy': cy,
        'cap': cap,
        if (name != null && name!.isNotEmpty) 'name': name,
      };

  factory StarLayoutBody.fromJson(Map<String, dynamic> j) => StarLayoutBody(
        type: j['type'] as String? ?? 'sphere',
        cx: (j['cx'] as num?)?.toDouble() ?? 0,
        cy: (j['cy'] as num?)?.toDouble() ?? 0,
        cap: (j['cap'] as num?)?.toInt() ?? 28,
        name: j['name'] as String?,
      );
}

/// 一整套编排（有序：照片按日期升序依次填满各星体）
class StarLayout {
  final List<StarLayoutBody> bodies;
  const StarLayout(this.bodies);
}

/// 星体编排的持久化（应用支持目录下的 star_layout.json）。
///
/// 语义：对当前整个照片库生效——照片按拍摄日期升序，按 bodies 顺序与容量
/// 依次切块；容量总和装不下的溢出照片继续用默认黄金螺旋自动成星体。
abstract final class StarLayoutService {
  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File(p.join(base.path, 'star_layout.json'));
  }

  static Future<StarLayout?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic>) return null;
      final list = j['bodies'];
      if (list is! List) return null;
      final bodies = list
          .whereType<Map<String, dynamic>>()
          .map(StarLayoutBody.fromJson)
          .where((b) => b.cap > 0)
          .toList();
      if (bodies.isEmpty) return null;
      return StarLayout(bodies);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(StarLayout layout) async {
    final f = await _file();
    await f.writeAsString(jsonEncode({
      'version': 2,
      'bodies': [for (final b in layout.bodies) b.toJson()],
    }));
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 各类型星体的默认容量（自定义编排时选一颗扣一颗）。
  /// 容量要足够大：照片多了才能堆出肉眼可辨的立体形状，
  /// 几千张照片也只需要二三十颗星体，而不是几百颗小点。
  static int capacityOf(String type) => switch (type) {
        'sphere' => 220,
        'ring' => 260,
        'spiral' => 360,
        'cloud' => 240,
        _ => 220,
      };

  /// 各类型星体的半径量级（摆放编辑器画光晕用，与星野 _extentFor 对齐）
  static double extentOf(String type) => switch (type) {
        'sphere' => 135,
        'ring' => 165,
        'spiral' => 205,
        'cloud' => 185,
        _ => 150,
      };

  static String displayNameOf(String type) => switch (type) {
        'sphere' => '星球',
        'ring' => '星环',
        'spiral' => '银河',
        'cloud' => '星云',
        _ => '星体',
      };
}

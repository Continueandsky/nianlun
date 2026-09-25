import 'package:flutter/material.dart';
import 'package:nianlun/theme/starry_theme.dart';

/// 全屏星空背景：深空底 + 静态星点（后续版本加微闪动画）
class StarryBackground extends StatelessWidget {
  final Widget child;
  const StarryBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StarryPainter(),
      child: child,
    );
  }
}

class _StarryPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = StarryTheme.deepSpace;
    canvas.drawRect(Offset.zero & size, paint);
    for (final s in StarSpec.field) {
      final starPaint = Paint()
        ..color = Colors.white.withValues(alpha: s.opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6);
      canvas.drawCircle(
        Offset(s.x * size.width, s.y * size.height),
        s.r,
        starPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

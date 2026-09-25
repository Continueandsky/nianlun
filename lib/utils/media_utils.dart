import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 媒体根目录：照片 / 音乐副本统一放这里，备份包以此为根
Future<Directory> mediaRoot() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'media'));
  await dir.create(recursive: true);
  return dir;
}

/// 相对路径 → 绝对 File（照片/音乐读取用）
Future<File> mediaFile(String relativePath) async {
  final root = await mediaRoot();
  return File(p.join(root.path, relativePath));
}

/// 加入媒体目录的相对路径（跨设备备份可迁移）
Future<String> relativeToMedia(File file) async {
  final root = await mediaRoot();
  return p.relative(file.path, from: root.path);
}

/// 图片探测结果：原始宽高 + 平均主色
class ImageMeta {
  final int width;
  final int height;
  final int? color;

  const ImageMeta({required this.width, required this.height, this.color});
}

/// 用原始字节探测图片：不解码全图即可拿到宽高，再小尺寸解码取平均主色
/// （瀑布流靠宽高算比例，氛围渐变靠主色）
Future<ImageMeta?> probeImageBytes(Uint8List bytes) async {
  ui.ImageDescriptor? descriptor;
  ui.ImmutableBuffer? buffer;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    var width = descriptor.width;
    var height = descriptor.height;

    codec = await descriptor.instantiateCodec(targetWidth: 32);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    // 有些照片画面数据是横着存的、靠 EXIF 旋转标记"立起来"，
    // 以真正解码出来的那块画面为准，避免把竖图当横图（会连带翻书页排版错位）
    if ((width > height) != (image.width > image.height)) {
      final swap = width;
      width = height;
      height = swap;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();

    int? color;
    if (data != null) {
      final px = data.buffer.asUint8List();
      var r = 0, g = 0, b = 0, n = 0;
      for (var i = 0; i + 3 < px.length; i += 4) {
        if (px[i + 3] < 8) continue;
        r += px[i];
        g += px[i + 1];
        b += px[i + 2];
        n++;
      }
      if (n > 0) {
        color = Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n).toARGB32();
      }
    }
    return ImageMeta(width: width, height: height, color: color);
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// 从（可能是缩略图的）字节里取平均主色，失败返回 null
Future<int?> averageColorFromBytes(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 24);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    final px = data.buffer.asUint8List();
    var r = 0, g = 0, b = 0, n = 0;
    for (var i = 0; i + 3 < px.length; i += 4) {
      if (px[i + 3] < 8) continue;
      r += px[i];
      g += px[i + 1];
      b += px[i + 2];
      n++;
    }
    if (n == 0) return null;
    return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n).toARGB32();
  } catch (_) {
    return null;
  }
}

/// 把主色调暗，用作照片底衬的氛围光（避免亮色刺眼）
Color ambienceOf(int? argb, {double dim = 0.45}) {
  final base = argb == null ? const Color(0xFF2A3160) : Color(argb);
  final hsl = HSLColor.fromColor(base);
  return hsl
      .withSaturation((hsl.saturation * 0.9).clamp(0.0, 1.0))
      .withLightness((hsl.lightness * dim).clamp(0.06, 0.42))
      .toColor();
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// 富文本 Delta 工具：解析 / 序列化 / 只读渲染控制器

/// 由 Delta JSON 字符串建文档（解析失败给空文档，绝不抛异常）
Document documentFromJson(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is List && decoded.isNotEmpty) {
      return Document.fromJson(decoded);
    }
  } catch (_) {
    // 落回空文档
  }
  return Document();
}

/// 只读渲染控制器（节点页翻书态读日记用）
QuillController buildReadOnlyController(String contentJson) {
  return QuillController(
    document: documentFromJson(contentJson),
    selection: const TextSelection.collapsed(offset: 0),
    readOnly: true,
  );
}

/// 可编辑控制器（日记编辑器用）
QuillController buildEditableController(String contentJson) {
  return QuillController(
    document: documentFromJson(contentJson),
    selection: const TextSelection.collapsed(offset: 0),
  );
}

/// 把控制器里的内容序列化为 Delta JSON 字符串
String encodeDocument(QuillController controller) =>
    jsonEncode(controller.document.toDelta().toJson());

/// 文档是否为空（只有空行 / 空白）
bool isDocumentBlank(QuillController controller) {
  final text = controller.document.toPlainText().trim();
  return text.isEmpty;
}

/// 纯文本预览（列表页/分享用）
String plainPreview(String contentJson, {int maxLength = 60}) {
  final text = documentFromJson(contentJson).toPlainText().trim();
  final single = text.replaceAll('\n', ' ');
  if (single.length <= maxLength) return single;
  return '${single.substring(0, maxLength)}…';
}

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nianlun/providers/app_providers.dart';
import 'package:nianlun/theme/starry_theme.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 备份与恢复面板
Future<void> showBackupSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: StarryTheme.nebula,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _BackupSheet(hostContext: context),
  );
}

class _BackupSheet extends ConsumerStatefulWidget {
  final BuildContext hostContext;
  const _BackupSheet({required this.hostContext});

  @override
  ConsumerState<_BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends ConsumerState<_BackupSheet> {
  Map<String, int>? _stats;
  bool _busy = false;
  String _busyLabel = '';

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final stats = await ref.read(backupServiceProvider).stats();
      if (!mounted) return;
      setState(() => _stats = stats);
    } catch (_) {
      // 统计失败不影响导出/恢复
    }
  }

  String _sizeText(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('备份与恢复',
                style: TextStyle(fontSize: 16, color: StarryTheme.starLight)),
            const SizedBox(height: 8),
            Text(
              stats == null
                  ? '正在统计…'
                  : '${stats['days']} 个日子 · ${stats['photos']} 张照片 · '
                      '${stats['journals']} 篇日记 · ${stats['music']} 首歌 · '
                      '媒体 ${_sizeText(stats['mediaBytes'] ?? 0)}',
              style: const TextStyle(
                  fontSize: 12, color: StarryTheme.starDim, height: 1.7),
            ),
            const SizedBox(height: 14),
            if (_busy) ...[
              Row(
                children: [
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: StarryTheme.starPurple),
                  ),
                  const SizedBox(width: 12),
                  Text(_busyLabel,
                      style: const TextStyle(
                          fontSize: 12, color: StarryTheme.starPurple)),
                ],
              ),
              const SizedBox(height: 10),
            ],
            _actionTile(
              icon: Icons.ios_share,
              title: '导出备份文件',
              subtitle: '生成 .nianlun 文件（含全部照片与音乐），自己保存到网盘即可',
              onTap: _busy ? null : _export,
            ),
            _actionTile(
              icon: Icons.restore,
              title: '从备份恢复',
              subtitle: '选择 .nianlun 文件恢复数据（同名内容会被覆盖）',
              onTap: _busy ? null : _import,
            ),
            const SizedBox(height: 4),
            const Text(
              '提示：换手机时，把备份文件拷过去，在新设备上恢复即可。',
              style:
                  TextStyle(fontSize: 11, color: StarryTheme.starDim, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: StarryTheme.starPurple),
      title: Text(title, style: const TextStyle(color: StarryTheme.starLight)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 11, color: StarryTheme.starDim)),
      onTap: onTap,
    );
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _busyLabel = '正在打包…';
    });
    try {
      final service = ref.read(backupServiceProvider);
      final file = await service.exportToTemp();
      final bytes = await file.readAsBytes();

      if (!mounted) return;
      setState(() => _busyLabel = '等待选择保存位置…');

      final savedPath = await _saveAs(service.defaultFileName(), bytes);

      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = '';
      });

      _toast(savedPath == null ? '已取消保存' : '备份已保存到：$savedPath');
      _loadStats();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = '';
      });
      _toast('导出失败：$e');
    }
  }

  /// 先试系统「另存为」；不行则落到应用外部存储目录（文件管理器可见）
  /// 返回保存位置描述，取消返回 null
  Future<String?> _saveAs(String fileName, Uint8List bytes) async {
    try {
      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/octet-stream',
      );
      if (uri == null) return null;
      return uri.path.isEmpty ? uri.toString() : uri.path;
    } catch (_) {
      try {
        final base = await getExternalStorageDirectory();
        if (base == null) return null;
        final dir = Directory(p.join(base.path, 'backups'));
        await dir.create(recursive: true);
        final target = File(p.join(dir.path, fileName));
        await target.writeAsBytes(bytes);
        return target.path;
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFile(type: FileType.any);
    if (picked == null) return;
    final path = picked.path;
    if (path == null) {
      _toast('无法读取该文件');
      return;
    }
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: StarryTheme.nebula,
        title: const Text('从备份恢复？',
            style: TextStyle(fontSize: 16, color: StarryTheme.starLight)),
        content: const Text(
          '当前数据里与备份同名的那部分会被覆盖（不会删除备份之外的内容）。\n建议先导出一份当前数据再恢复。',
          style: TextStyle(fontSize: 13, color: StarryTheme.starDim, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: StarryTheme.starDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('开始恢复',
                style: TextStyle(color: StarryTheme.starPurple)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _busyLabel = '正在恢复…';
    });
    try {
      await ref.read(backupServiceProvider).importFrom(path);
      refreshAllDays(ref);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = '';
      });
      _toast('恢复完成');
      _loadStats();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = '';
      });
      _toast('恢复失败：$e');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(widget.hostContext).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }
}

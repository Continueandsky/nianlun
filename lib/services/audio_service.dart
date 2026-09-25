import 'dart:async';
import 'dart:developer' as dev;

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// 「年轮」音乐播放服务
/// 核心体验：进入节点自动淡入，退出淡出；沉浸态/翻书态切换不断
class PlayerService {
  final AudioPlayer player = AudioPlayer();

  /// 正在播放的音乐标题（UI 显示用）
  String? currentTitle;

  /// 最近一次播放失败的错误信息
  String? lastError;

  bool _sessionReady = false;
  StreamSubscription? _stateSub;

  PlayerService() {
    // 把播放状态异常（比如解码失败）打印出来，方便排查
    _stateSub = player.processingStateStream.listen((state) {
      dev.log('just_audio processingState: $state');
    }, onError: (e, st) {
      dev.log('just_audio 状态流错误', error: e, stackTrace: st);
    });
  }

  Future<void> _ensureSession() async {
    if (_sessionReady) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _sessionReady = true;
    } catch (e, st) {
      dev.log('AudioSession 配置失败', error: e, stackTrace: st);
    }
  }

  /// 带淡入播放（进入节点时调用）
  Future<String?> playWithFade(
    String path, {
    String? title,
    double targetVolume = 1.0,
    Duration fade = const Duration(milliseconds: 1400),
  }) async {
    lastError = null;
    await _ensureSession();

    try {
      // 激活音频会话，避免被系统静音策略压制
      if (_sessionReady) {
        try {
          final session = await AudioSession.instance;
          await session.setActive(true);
        } catch (e, st) {
          dev.log('AudioSession setActive 失败', error: e, stackTrace: st);
        }
      }

      await player.stop();
      await player.setVolume(0);

      // 加载本地文件；just_audio 会解析时长，返回 null 说明文件无法解码
      final duration = await player.setFilePath(path);
      if (duration == null || duration == Duration.zero) {
        final msg = '音乐文件加载失败或时长为空：$path';
        dev.log(msg);
        lastError = '无法读取这首音乐，换一首试试';
        return lastError;
      }

      currentTitle = title;

      // 等待播放器真正 ready，避免 play() 在缓冲期调用导致无声
      if (player.processingState != ProcessingState.ready) {
        await player.processingStateStream
            .firstWhere((s) => s == ProcessingState.ready)
            .timeout(const Duration(seconds: 5), onTimeout: () {
          dev.log('等待音乐 ready 超时');
          return ProcessingState.idle;
        });
      }

      if (player.processingState != ProcessingState.ready) {
        lastError = '音乐还没准备好，请重试';
        return lastError;
      }

      // 设置循环并开始播放
      await player.setLoopMode(LoopMode.all);
      await player.play();

      // 淡入：分步提升音量，不依赖 player.playing 状态，确保一定能涨到目标音量
      const steps = 20;
      final stepDelay = Duration(milliseconds: fade.inMilliseconds ~/ steps);
      for (var i = 1; i <= steps; i++) {
        await Future.delayed(stepDelay);
        try {
          await player.setVolume(targetVolume * i / steps);
        } catch (_) {
          break;
        }
      }
      return null;
    } catch (e, st) {
      final msg = '播放音乐失败：$e';
      dev.log(msg, error: e, stackTrace: st);
      lastError = '播放失败：${e.toString().split('\n').first}';
      return lastError;
    }
  }

  /// 淡出停止（退出节点时调用）
  Future<void> stopWithFade({Duration fade = const Duration(milliseconds: 800)}) async {
    try {
      if (player.playing) {
        const steps = 12;
        final start = player.volume;
        for (var i = steps; i >= 0; i--) {
          await player.setVolume(start * i / steps);
          await Future.delayed(Duration(milliseconds: fade.inMilliseconds ~/ steps));
        }
      }
      await player.stop();
      currentTitle = null;
    } catch (_) {}
    try {
      await player.setVolume(1);
    } catch (_) {}
  }

  Future<void> pause() => player.pause();
  Future<void> resume() => player.play();

  void dispose() {
    _stateSub?.cancel();
    player.dispose();
  }
}

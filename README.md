# 年轮 (nianlun)

> 每一圈年轮，都是那一天的光。

照片、日记与音乐交织的私人时光容器。纯本地离线，无云端、无账号、无广告。

一切以「某一天」为节点：照片按 EXIF 拍摄时间自动归属到那一天，日记一天可多篇，每天可以配一首歌。双入口殊途同归——从星河点开一张照片，或从日历点开某一天，落在同一个节点页：沉浸态照片流（音乐自动淡入）+ 上滑翻书态（3D 翻页的纸质日记本）。

## 功能总览（v1）

| 模块 | 状态 | 说明 |
|------|------|------|
| 照片导入 | ✅ | 系统相册全量 / 最近一年 / 系统选择器手动挑选；EXIF 归天、去重、取主色 |
| 星河照片流 | ⚠️ | 照片散落桌面（可拖动/缩放），体验待继续打磨 |
| 日历 | ✅ | 月网格，有照片的日子用当天首图做底，心情星星 |
| 节点页 | ✅ | 沉浸态 + 翻书态，音乐贯穿两态；横图翻页时旋转 90° 立起铺满 |
| 日记编辑器 | ✅ | 富文本（Quill）+ 心情标记，一天多篇 |
| 音乐 | ✅ | 本地音频文件，进入节点自动淡入、退出淡出；酷狗链接仅作记录跳转 |
| 备份 | ✅ | 导出/导入 `.nianlun`（zip 容器，含数据库+媒体副本） |

完整进度、架构解析、待办事项见：[`docs/迁移文档.md`](docs/迁移文档.md)

## 构建环境

- Flutter 3.47.5（stable）
- Android SDK（compileSdk 36）
- 仅 Android 平台；其他平台目录未入库，需要时 `flutter create --platforms=web,ios . ` 生成

```bash
flutter pub get
flutter run            # 连接 Android 设备
flutter build apk      # release APK（约 20MB）
```

Windows 本机构建可直接双击仓库根目录的 `一键初始化构建.cmd`（版本检查 → 依赖 → 静态分析 → debug APK）。

## 目录结构

```
lib/
├── main.dart                       # 入口 + ProviderScope + 首页双 Tab
├── models/
│   └── day_entry.dart              # 核心数据模型（天=节点、照片、日记、音乐、心情）
├── providers/
│   └── app_providers.dart          # Riverpod provider 总闸
├── services/
│   ├── database.dart               # SQLite v2（sqflite）
│   ├── day_repository.dart         # 数据统一出口
│   ├── photo_import_service.dart   # 相册导入（EXIF 归天/去重/主色）
│   ├── media_attach_service.dart   # 节点页挂照片/挂音乐
│   ├── audio_service.dart          # 音乐淡入淡出（just_audio）
│   └── backup_service.dart         # .nianlun 备份导出/导入
├── pages/
│   ├── home/star_river_page.dart   # Tab1 星河：照片散落桌面
│   ├── calendar/calendar_page.dart # Tab2 日历
│   ├── node/node_page.dart         # ⭐ 节点页：沉浸态+翻书态
│   ├── editor/journal_editor_page.dart # 日记编辑器
│   └── settings/backup_sheet.dart  # 备份弹层
├── theme/
│   └── starry_theme.dart           # 暗夜星空主题 + 纸质浅色子主题
├── utils/
│   ├── delta_utils.dart            # Quill 文档编解码
│   └── media_utils.dart            # 媒体路径/EXIF 探测/主色提取
└── widgets/
    └── starry_background.dart      # 星空背景
```

## 许可

个人项目，未附开源许可证。

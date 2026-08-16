# Snip

Snip 是一个面向 macOS 的原生截图贴图工具，定位在“快速截取、即时标注、直接贴图”。项目基于 Swift + AppKit 实现，当前已覆盖区域截图、标注编辑、滚动长截图、浮动贴图、剪贴板贴图和快捷键自定义等核心流程。

## 功能概览

- 区域截图：拖拽选区、实时尺寸提示、支持多显示器、支持 Retina 分辨率。
- 截图编辑：箭头/直线、矩形/椭圆、画笔、文字、马赛克、撤销/重做。
- 圆角输出：支持快捷切换、右键菜单选择、滚轮微调圆角半径。
- 滚动长截图：在选区内滚动目标应用，自动连续采集并智能拼接。
- 输出方式：完成后生成浮动贴图，也可 `Cmd + C` 复制或 `Cmd + S` 保存为 PNG/JPEG。
- 浮动贴图：窗口置顶、拖拽移动、滚轮缩放、双击或 `Esc` / `Delete` / `Cmd + W` 关闭。
- 剪贴板贴图：直接把剪贴板中的图片转换成浮动窗口。
- 快捷键设置：支持自定义截图与贴图快捷键。

默认快捷键：

- 截图：`⌥A`
- 贴图：`⌥V`

## 技术栈

- Swift 5
- AppKit
- ScreenCaptureKit
- Vision
- Carbon Event HotKey

项目无第三方依赖，最低支持 `macOS 13.0`。

## 快速开始

### 运行方式

1. 使用 Xcode 打开 [Snip.xcodeproj](Snip.xcodeproj)。
2. 选择 `Snip` Scheme。
3. 运行到 `My Mac`。

也可以使用命令行构建：

```bash
xcodebuild -project Snip.xcodeproj -scheme Snip -configuration Debug build
```

### 工程文件说明

仓库同时包含 `Snip.xcodeproj` 与 [project.yml](project.yml)。日常开发可以直接打开 `xcodeproj`；如果需要调整 Target、Build Settings 或资源编排，建议以 `project.yml` 为准重新生成工程。

## 使用流程

### 1. 启动应用

应用启动后以菜单栏工具形式运行，提供以下入口：

- 状态栏菜单中的“截图”“贴图”“偏好设置”“退出”
- 全局快捷键触发截图或贴图

### 2. 截图与编辑

1. 使用快捷键或状态栏菜单进入截图模式。
2. 鼠标拖拽选区，松开后进入编辑态。
3. 在编辑工具栏中添加标注、调整样式、撤销/重做。
4. 可通过选区右上角的圆角控件快速调整输出圆角。
5. 点击“完成贴图”后生成浮动窗口。

### 3. 滚动长截图

1. 先完成选区选择并进入编辑态。
2. 点击工具栏中的“滚动长截图”按钮。
3. 在选区区域内对目标应用执行滚动。
4. Snip 会按滚动距离自动采集多帧并去重拼接。
5. 点击“完成贴图”后输出长图。

### 4. 浮动贴图

生成后的浮动窗口支持：

- 拖拽移动
- 滚轮缩放，范围 `0.1x ~ 5x`
- `Cmd + C` 复制原图
- 双击、`Esc`、`Delete`、`Cmd + W` 关闭

### 5. 剪贴板贴图

当剪贴板中存在图片时，可通过状态栏菜单或贴图快捷键直接生成浮动贴图，默认出现在当前鼠标位置。

## 权限说明

应用当前依赖以下系统权限：

- 屏幕录制权限：用于区域截图与长截图采集。
- 辅助功能权限：用于监听全局快捷键，以及长截图模式下将滚轮事件转发给目标应用。

首次触发截图时，应用会先请求屏幕录制权限；未授权时不会进入灰色截图选择界面。辅助功能权限仍会在快捷键初始化时请求。

## 文档索引

- [开发与发布文档](DEVELOPMENT.md)
- [项目设计文档](Snip/README.md)
- [长截图实现说明](SCROLL_CAPTURE_IMPLEMENTATION.md)
- [截图时机与浮动窗口系统阴影](SCREEN_CAPTURE_TIMING_AND_SHADOW.md)
- [更新日志](CHANGELOG.md)

## 仓库结构

```text
.
├── README.md
├── CHANGELOG.md
├── SCROLL_CAPTURE_IMPLEMENTATION.md
├── project.yml
├── Snip.xcodeproj
└── Snip
    ├── App
    ├── Managers
    ├── Resources
    ├── Utils
    └── Views
```

如果你要从代码结构和模块协作关系入手阅读项目，直接从 [项目设计文档](Snip/README.md) 开始更合适。

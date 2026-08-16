# Snip

[English](README.md) | **简体中文**

Snip 是一款原生 macOS 截图与贴图工具，专注于快速截图、即时标注和浮动贴图。项目使用 Swift 与 AppKit 开发，支持区域截图、标注编辑、滚动长截图、剪贴板贴图和自定义快捷键。

## 功能特性

- 区域截图：拖拽选区、实时尺寸提示、多显示器和 Retina 分辨率支持
- 截图标注：箭头/直线、矩形/椭圆、画笔、文字、马赛克、撤销/重做
- 画笔直线：使用画笔时按住 `Option` 或 `Shift` 绘制直线
- 圆角输出：快捷切换、右键选择或滚轮调整圆角半径
- 滚动长截图：自动采集、智能拼接，并支持在同一会话中向上和向下扩展
- 多种输出：生成浮动贴图，或通过 `Cmd + C` 复制、`Cmd + S` 保存为 PNG/JPEG
- 浮动贴图：窗口置顶、拖拽、滚轮缩放和快捷关闭
- 剪贴板贴图：将剪贴板图片直接显示为浮动窗口
- 自定义快捷键：支持设置截图与贴图快捷键

默认快捷键：

- 截图：`Option + A`
- 贴图：`Option + V`

## 系统要求

- macOS 14.0 或更高版本
- Xcode

项目无第三方依赖。

## 下载

推送版本标签后，GitHub Actions 会自动构建同时支持 Apple Silicon 和 Intel Mac 的通用 DMG。可从仓库的 **Releases** 页面下载安装包，打开 DMG 后将 `Snip.app` 拖入 `Applications`。

当前安装包尚未签名和公证，首次启动时可能需要在 macOS 中手动允许打开。

## 技术栈

- Swift 5
- AppKit
- ScreenCaptureKit
- Vision
- Carbon Event HotKey

## 构建与运行

1. 使用 Xcode 打开 [Snip.xcodeproj](Snip.xcodeproj)。
2. 选择 `Snip` Scheme。
3. 选择 `My Mac` 并运行。

也可以使用命令行构建：

```bash
xcodebuild \
  -project Snip.xcodeproj \
  -scheme Snip \
  -configuration Debug \
  build
```

使用 Xcode 打开 `Snip.xcodeproj`，即可管理 Target、Build Settings、资源和其他工程配置。

## 使用方法

### 截图与标注

1. 使用全局快捷键或状态栏菜单开始截图。
2. 拖动鼠标创建截图选区。
3. 使用编辑工具栏添加标注、调整样式或撤销/重做。
4. 点击完成按钮生成浮动贴图，也可以复制或保存截图。

### 滚动长截图

1. 创建选区并进入编辑状态。
2. 点击滚动长截图按钮。
3. 在目标应用中滚动页面，Snip 会自动采集并拼接内容。
4. 可在同一会话中向下扩展，返回起始位置后再向上扩展。
5. 点击完成按钮输出长图。

### 浮动贴图

浮动窗口支持：

- 拖拽移动
- 滚轮缩放，范围 `0.1x` 至 `5x`
- `Cmd + C` 复制原图
- 双击、`Esc`、`Delete` 或 `Cmd + W` 关闭

### 剪贴板贴图

当剪贴板中包含图片时，可通过状态栏菜单或贴图快捷键直接创建浮动窗口。窗口默认显示在当前鼠标位置附近。

## 权限

Snip 使用以下 macOS 权限：

- 屏幕录制：用于区域截图和滚动长截图
- 辅助功能：用于全局快捷键和系统事件协作

首次截图时，Snip 会请求屏幕录制权限。授权后请再次触发截图。

## 项目结构

```text
.
├── README.md
├── README_CN.md
├── Snip.xcodeproj
└── Snip
    ├── App
    ├── Managers
    ├── Resources
    ├── Utils
    └── Views
```

更详细的代码架构说明见 [Snip/README.md](Snip/README.md)。

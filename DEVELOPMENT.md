# Snip 开发文档

本文档用于项目交接、日常开发和发布前检查，也可直接导入 Notion 作为开发主页。

## 1. 项目定位

Snip 是一个原生 macOS 菜单栏截图与贴图工具，基于 Swift、AppKit、ScreenCaptureKit、Vision 和 Carbon Event HotKey 实现，不依赖第三方库，最低支持 macOS 13.0。

核心能力：

- 多显示器区域截图与 Retina 像素输出
- 箭头、图形、画笔、文字和马赛克标注
- 同一会话双向扩展的滚动长截图
- 浮动贴图、缩放、复制和快速关闭
- 剪贴板贴图与全局快捷键
- PNG/JPEG 保存与输出圆角

## 2. 开发环境

建议环境：

- macOS 13.0 或更高版本
- 当前稳定版 Xcode
- Swift 5
- 可选：XcodeGen，用于根据 `project.yml` 重新生成工程

打开工程：

```bash
open Snip.xcodeproj
```

Debug 构建：

```bash
xcodebuild \
  -project Snip.xcodeproj \
  -scheme Snip \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Release 构建：

```bash
xcodebuild \
  -project Snip.xcodeproj \
  -scheme Snip \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

涉及 Target、Build Settings、Info.plist 或资源组织时，以 `project.yml` 为工程配置来源，并同步更新 `Snip.xcodeproj`。

## 3. 系统权限

Snip 使用以下权限：

- 屏幕录制：区域截图、长截图和屏幕内容采样
- 辅助功能：全局快捷键及部分系统事件协作
- Apple Events：需要与其他应用协作的系统路径

首次截图时，`CaptureManager` 会检查屏幕录制权限。未授权时请求系统权限并结束当前截图动作，用户授权后再次触发截图。

发布前需要检查 `Snip/Resources/Info.plist` 中的权限描述仍与实际功能一致。

## 4. 总体架构

```text
StatusBarManager / HotkeyManager
                |
            AppDelegate
                |
          CaptureManager
                |
           CaptureView
                |
CaptureEditToolbar / AnnotationLayer / ScrollCaptureManager
                |
      FloatingImageManager
```

主要职责：

- `AppDelegate`：应用生命周期、菜单入口、快捷键动作和偏好设置窗口
- `CaptureManager`：权限检查、触发瞬间预采集、多显示器遮罩窗口和截图会话生命周期
- `CaptureView`：选区、编辑态、普通截图、长截图切换和最终输出
- `AnnotationLayer`：标注模型、绘制、撤销重做、马赛克采样和长截图坐标偏移
- `ScrollCaptureManager`：滚动观察、采样调度、Vision 配准和双端增量拼接
- `FloatingImageManager`：浮动贴图窗口、缩放、复制、关闭和资源释放
- `PreferencesManager` / `HotkeyManager`：快捷键存储与 Carbon 全局注册

## 5. 普通截图流程

1. 菜单栏或全局快捷键触发截图。
2. `CaptureManager` 检查屏幕录制权限。
3. 创建遮罩前，优先获取每个显示器的 WindowServer 合成图像。
4. 为每块显示器创建 `CaptureWindow` 并注入预采集底图。
5. 用户拖出选区，进入编辑态。
6. `AnnotationLayer` 和 `CaptureEditToolbar` 处理标注与样式。
7. 完成时按像素级流程合成底图、标注和圆角。
8. 输出到浮动贴图，也可复制或保存。

遮罩前预采集用于保留触发瞬间的菜单下拉框和浮动贴图原生阴影。详细说明见 `SCREEN_CAPTURE_TIMING_AND_SHADOW.md`。

## 6. 标注系统

当前工具：

- 直线及多种箭头
- 矩形和椭圆
- 自由画笔
- 文字
- 马赛克

画笔支持在拖动时按住 `Option` 或 `Shift` 锁定为直线。直线预览使用完整标注层重绘，避免旋转过程中出现旧线段残影。

马赛克以固定像素块和独立覆盖宽度工作，笔划增量记录网格单元并按相邻批次绘制。长截图期间，最新拼接底图会同步作为马赛克采样源，确保编辑预览和最终导出颜色一致。

## 7. 滚动长截图

长截图建立在普通截图编辑态之上：

1. 固定选区的屏幕绝对坐标。
2. 浏览态让滚轮原生进入底层应用。
3. 全局监听只旁路观察实际滚动，用于预览偏移和采样调度。
4. ScreenCaptureKit 重复采集同一屏幕区域。
5. Vision 对相邻帧做垂直平移配准。
6. 已捕获范围内只更新配准锚点；越过上边界或下边界时才扩展画布。
7. 完成后统一合成标注和圆角。

当前支持同一会话先向下扩展，回到起点后继续向上扩展。详细状态、事件路径和拼接算法见 `SCROLL_CAPTURE_IMPLEMENTATION.md`。

## 8. 图像和内存约定

- 截图、拼接、标注导出和圆角尽量使用 `CGImage` / `CGContext`。
- 逻辑点与物理像素必须显式换算，避免 Retina 下的半像素裁切。
- 长截图只保留增量合成图和最近配准帧，不保留全部历史帧。
- 截图会话和异步任务使用 session ID 或 generation token 隔离旧结果。
- 窗口关闭、取消截图和内存压力路径必须释放底图、缓存、回调和任务。

## 9. 工程目录

```text
Snip/
├── App/                 # 启动与应用生命周期
├── Managers/            # 截图、长截图、浮窗、快捷键和偏好设置
├── Resources/           # Info.plist、Assets 和应用图标
├── Utils/               # 日志和图像封装
└── Views/
    ├── Capture/         # 选区、编辑工具栏和标注层
    └── Preferences/     # 偏好设置窗口
```

仓库根目录：

- `README.md`：产品和使用说明
- `DEVELOPMENT.md`：开发与发布说明
- `SCROLL_CAPTURE_IMPLEMENTATION.md`：长截图专题
- `SCREEN_CAPTURE_TIMING_AND_SHADOW.md`：截图时机和原生阴影专题
- `CHANGELOG.md`：版本变化
- `project.yml`：XcodeGen 工程配置

## 10. 验证清单

当前没有自动化测试 Target，发布前至少完成以下人工回归：

- 普通区域截图、多显示器和 Retina 清晰度
- 菜单下拉框与浮动贴图原生阴影保留
- 所有标注工具、撤销重做、画笔直线和马赛克尺寸
- 长截图向下扩展、回到起点、向上扩展和标注同步
- 长截图中连续标注及选区内原生滚动
- PNG/JPEG 保存、剪贴板复制和剪贴板贴图
- 浮动贴图拖动、缩放、双击关闭和快捷键关闭
- 屏幕录制权限首次请求及拒绝后的行为
- 应用图标在 Finder、Dock 和应用信息窗口中的显示

代码提交前至少执行：

```bash
git diff --check
xcodebuild \
  -project Snip.xcodeproj \
  -scheme Snip \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

发布候选还应执行一次 Release 构建。

## 11. 发布流程

1. 更新 `CHANGELOG.md` 和版本号。
2. 完成 Debug、Release 构建及人工回归。
3. 使用有效的 Developer ID 签名 Release 应用。
4. 创建归档并进行 Apple notarization。
5. 验证 Gatekeeper、权限提示和首次启动行为。
6. 创建 Git tag 和 GitHub Release，上传签名且公证后的产物。

当前仓库构建验证使用 `CODE_SIGNING_ALLOWED=NO`，只能证明代码可编译，不能替代签名、公证和发布验证。

## 12. 已知边界

- `CaptureView` 职责较重，仍包含截图会话、编辑、输出和长截图协调逻辑。
- 长截图依赖图像配准，吸顶栏、悬浮元素、动态广告和大面积异步刷新可能降低稳定性。
- 长截图主要针对纵向滚动，不以横向滚动为目标。
- `WindowDetectionManager` 尚未接入主流程。
- 缺少自动化测试，长截图、标注合成和保存流程仍依赖人工回归。

## 13. 后续优先级

1. 拆分 `CaptureView` 的会话控制、输出管线和长截图协调职责。
2. 为图像合成、坐标换算和长截图状态机增加测试 Target。
3. 增加签名、公证和 GitHub Release 自动化。
4. 评估并产品化窗口探测与窗口吸附截图。

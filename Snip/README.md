# Snip 项目设计文档

本文档基于当前仓库里的实际实现编写，目标是解释 Snip 的模块划分、核心流程、关键技术决策，以及当前架构的边界。它描述的是“现状设计”，不是理想化规划。

配套文档：

- 根目录 [README.md](../README.md)：面向使用者和贡献者的总览。
- [DEVELOPMENT.md](../DEVELOPMENT.md)：开发环境、验证清单和发布流程。
- [SCROLL_CAPTURE_IMPLEMENTATION.md](../SCROLL_CAPTURE_IMPLEMENTATION.md)：长截图算法与拼接实现细节。
- [SCREEN_CAPTURE_TIMING_AND_SHADOW.md](../SCREEN_CAPTURE_TIMING_AND_SHADOW.md)：截图时机与原生阴影处理。
- [CHANGELOG.md](../CHANGELOG.md)：版本变化记录。

## 1. 设计目标

Snip 当前聚焦四件事：

- 以菜单栏工具的形式提供尽可能快的截图入口。
- 在截图完成前把标注、圆角、长截图都收敛到同一条编辑链路。
- 在输出阶段统一进入“浮动贴图”模型，减少截图、长截图、贴图三套结果处理逻辑。
- 优先保证截图清晰度和交互稳定性，而不是引入更多抽象层。

因此，这个项目采用了比较直接的 AppKit 架构：用少量管理器负责系统交互，用 `CaptureView` 负责截图态的大部分状态，用 `AnnotationLayer` 负责标注模型和绘制。

## 2. 总体架构

整体调用关系如下：

```text
StatusBarManager / HotkeyManager
                ↓
            AppDelegate
                ↓
          CaptureManager
                ↓
           CaptureView
                ↓
CaptureEditToolbar / AnnotationLayer / ScrollCaptureManager
                ↓
      FloatingImageManager
```

几个关键特点：

- `AppDelegate` 只做应用级协调，不承载具体业务细节。
- 普通截图和长截图共用同一个 `CaptureView` 编辑上下文。
- 长截图不是单独窗口，而是在截图态中切换到“滚动采集模式”。
- 所有最终图片都走统一的后处理链路：标注合成、圆角裁切、输出到浮窗/剪贴板/文件。

## 3. 模块职责

### 3.1 App 层

- [App/main.swift](App/main.swift)
  负责以主线程方式启动 AppKit 应用。
- [App/SnipApp.swift](App/SnipApp.swift)
  定义 `AppDelegate`，负责应用生命周期、管理器装配、菜单栏入口、偏好设置窗口与贴图入口。

这里有两个重要设计点：

- 应用启动后通过 `NSApp.setActivationPolicy(.accessory)` 以菜单栏工具方式运行。
- 打开保存面板时会临时切换到 `.regular`，避免 accessory 模式下 `NSSavePanel` 的交互问题。

### 3.2 管理器层

- [Managers/CaptureManager.swift](Managers/CaptureManager.swift)
  负责创建每块屏幕对应的截图窗口，管理截图窗口生命周期，并在截图完成后把结果交给 `FloatingImageManager`。
- [Managers/FloatingImageManager.swift](Managers/FloatingImageManager.swift)
  负责创建和持有浮动贴图窗口，避免窗口因引用释放而消失。
- [Managers/ScrollCaptureManager.swift](Managers/ScrollCaptureManager.swift)
  负责长截图模式下的滚动监听、节流采集、去重、拼接和滚动偏移状态。
- [Managers/StatusBarManager.swift](Managers/StatusBarManager.swift)
  负责状态栏图标和菜单项。
- [Managers/HotkeyManager.swift](Managers/HotkeyManager.swift)
  通过 Carbon `EventHotKey` 注册全局快捷键。
- [Managers/PreferencesManager.swift](Managers/PreferencesManager.swift)
  基于 `UserDefaults` 保存截图/贴图快捷键。
- [Managers/WindowDetectionManager.swift](Managers/WindowDetectionManager.swift)
  提供窗口边界探测能力，但当前未接入主流程，属于保留中的实验模块。

### 3.3 视图层

- [Views/Capture/CaptureView.swift](Views/Capture/CaptureView.swift)
  截图态的核心视图，负责屏幕采集、选区交互、编辑模式切换、长截图模式切换、保存/复制/完成输出。
- [Views/Capture/CaptureEditToolbar.swift](Views/Capture/CaptureEditToolbar.swift)
  编辑工具栏，负责工具选择、样式面板、撤销重做、长截图按钮和完成/取消动作。
- [Views/Capture/AnnotationLayer.swift](Views/Capture/AnnotationLayer.swift)
  标注模型与绘制中心，负责箭头、矩形、画笔、文字、马赛克，以及撤销/重做与长截图时的可视偏移。
- [Views/Capture/AnnotationToolbar.swift](Views/Capture/AnnotationToolbar.swift)
  放置标注相关枚举与样式定义。
- [Views/Preferences/PreferencesWindow.swift](Views/Preferences/PreferencesWindow.swift)
  偏好设置窗口与快捷键录制控件。

### 3.4 资源与工具

- [Resources/Info.plist](Resources/Info.plist)
  维护应用版本和权限描述。
- [Utils/Logger.swift](Utils/Logger.swift)
  统一日志输出入口。

## 4. 核心流程

### 4.1 应用启动与入口装配

启动时的顺序是：

1. `AppDelegate` 检查辅助功能权限。
2. 应用切换到 accessory 模式。
3. 初始化 `CaptureManager`、`StatusBarManager`、`HotkeyManager`。
4. 菜单栏和快捷键通过闭包回调统一回到 `AppDelegate`。

这样做的目的，是把“系统入口”与“业务动作”解耦，避免视图层直接感知状态栏或快捷键实现。

### 4.2 普通截图流程

普通截图的主链路如下：

1. `StatusBarManager` 或 `HotkeyManager` 触发截图。
2. `AppDelegate.handleCapture()` 调用 `CaptureManager.startCapture()`。
3. `CaptureManager` 先检查屏幕录制权限；若系统尚未授权，则先触发系统权限请求并中止本次截图。
4. 权限可用后，`CaptureManager` 为每块屏幕创建一个透明无边框窗口。
5. 每个窗口挂载一个 `CaptureView`，并异步采集该屏幕截图底图。
6. 用户拖拽形成 `selectionRect`，松开鼠标后进入编辑态。
7. `CaptureView` 创建 `AnnotationLayer` 和 `CaptureEditToolbar`。
8. 完成后进入统一输出流程，调用 `FloatingImageManager` 创建浮窗。

这个流程里，`CaptureView` 同时承担了“截图容器”和“编辑上下文”两个角色，因此普通截图与编辑状态切换不需要跨对象迁移数据。

### 4.3 编辑与标注流程

编辑态下的设计重点是“在原选区上直接叠加交互层”：

- 选区本身仍由 `CaptureView` 管理，支持拖动和缩放。
- 标注内容由 `AnnotationLayer` 管理，工具栏只负责发出动作和样式变化。
- 标注撤销/重做状态通过回调驱动工具栏按钮状态。
- 马赛克工具并不是简单填色，而是对底图做像素化采样后局部裁切绘制。

当前支持的工具：

- 线条工具：直线、实心箭头、描边箭头、开放箭头
- 图形工具：矩形、椭圆
- 画笔
- 文字
- 马赛克

### 4.4 长截图流程

长截图在架构上不是“新建一个模式页面”，而是普通编辑态上的一次模式切换：

1. 点击工具栏长截图按钮。
2. `CaptureView` 切换 `isScrollCaptureMode`。
3. 保存当前选区对应的屏幕绝对坐标。
4. 释放普通截图底图，收缩窗口到选区附近，降低遮挡和内存占用。
5. `ScrollCaptureManager` 开始监听滚轮事件，并按滚动距离节流采集。
6. 每次需要新帧时，回调 `CaptureView.captureCurrentSelection()` 重新抓取同一屏幕绝对区域。
7. `ScrollCaptureManager` 用 Vision 的平移配准估算新增高度，并执行增量拼接。
8. 完成时，`CaptureView` 统一合成长图、标注和圆角，再输出到浮窗。

这里有三个关键设计：

- 固定屏幕绝对坐标采集，而不是依赖第一次抓到的全屏图裁切。
- 标注层通过 `viewportOffset` 感知滚动位移，让标注预览与长截图内容同步滚动。
- 工具栏在长截图期间被拆到独立 `NSPanel`，避免主截图窗口缩小时工具栏被裁掉。

长截图的详细算法说明见 [SCROLL_CAPTURE_IMPLEMENTATION.md](../SCROLL_CAPTURE_IMPLEMENTATION.md)。

### 4.5 浮动贴图流程

所有成功输出的图片都会进入 `FloatingImageManager`：

1. 管理器创建 `FloatingImageWindow`。
2. 窗口使用 borderless + resizable 风格，并保持置顶。
3. 初始显示尺寸会限制在屏幕可视区域内，但保留原图用于复制。
4. 用户可拖拽窗口、滚轮缩放，或通过快捷键关闭/复制。

这里把“显示图像”和“原始图像”分开保存，是为了兼顾初始窗口大小控制与复制原图质量。

### 4.6 贴图与偏好设置流程

贴图流程很简单：

1. 读取系统剪贴板。
2. 若存在 `NSImage`，直接在鼠标位置创建浮窗。
3. 否则显示提示框。

偏好设置流程则是：

1. 打开 `PreferencesWindow`。
2. 快捷键录制控件更新 `PreferencesManager`。
3. 回调触发 `HotkeyManager.updateHotkeys()` 与 `StatusBarManager.updateMenuShortcuts()`。

这样保证设置修改后无需重启应用即可立即生效。

## 5. 状态与通信设计

项目没有引入额外状态管理框架，当前主要依赖三种机制：

- 管理器单例：例如 `FloatingImageManager.shared`、`PreferencesManager.shared`、`ScrollCaptureManager.shared`
- 闭包回调：用于模块间事件回传，避免直接相互持有
- 视图内部状态：例如 `CaptureView` 持有当前选区、编辑态、长截图态、底图和工具栏引用

这样设计的优点是简单直接，缺点也很明确：

- `CaptureView` 体量较大，既管交互又管输出。
- 一些跨模块流程依赖时序配合，例如长截图结束、保存面板模式切换、滚轮事件转发。
- 当前更偏向“易落地”，而不是“高度可测试”。

## 6. 关键技术决策

### 6.1 以 AppKit 为主，而不是 SwiftUI

原因很直接：

- 需要无边框截图窗口、精细鼠标事件控制、状态栏菜单、全局快捷键。
- 长截图涉及滚轮事件转发、窗口透明与交互切换，AppKit 控制粒度更合适。

### 6.2 使用 ScreenCaptureKit 做截图

相比传统方案，当前实现更看重两点：

- 可以按屏幕和区域做高分辨率采集。
- 可以在采集时排除当前截图窗口，减少自截图问题。

### 6.3 使用 Vision 做重叠检测

长截图拼接的关键不是“盲目累加”，而是识别相邻帧的实际新增区域。当前通过平移配准估算新增高度，这比固定步长裁切更稳。

### 6.4 全链路尽量保持像素级处理

在普通截图、长截图拼接、标注合成和圆角裁切时，当前实现都尽量直接围绕 `CGImage` 与 `CGContext` 处理，减少 `NSImage.lockFocus()` 带来的重采样和清晰度损失。

## 7. 工程约定

当前仓库的工程约定如下：

- 根目录 [project.yml](../project.yml) 描述工程配置。
- [Snip.xcodeproj](../Snip.xcodeproj) 已提交，便于直接打开运行。
- 核心源码集中在 `Snip/` 目录下，按 `App`、`Managers`、`Views`、`Utils`、`Resources` 分层。
- 项目当前没有自动化测试目录，验证主要依赖手工运行与交互回归。

## 8. 当前边界与后续优化方向

从当前实现看，几个比较明确的边界是：

- `CaptureView` 职责偏重，后续可拆分为截图会话控制器、输出管线、长截图协调器。
- `WindowDetectionManager` 尚未接入主流程，窗口吸附与窗口捕获能力还没有完成产品化。
- 自动化测试缺失，尤其是长截图、标注合成、保存流程更依赖人工验证。
- 偏好设置当前只覆盖快捷键，尚未扩展到图片格式、默认圆角、输出策略等配置项。

如果后续继续演进，优先级更高的方向应当是：

1. 拆分 `CaptureView` 的状态与职责。
2. 为图片后处理和长截图拼接补充可独立验证的测试入口。
3. 把未接入的窗口探测能力整合为可见的产品功能，而不是保留在孤立管理器中。

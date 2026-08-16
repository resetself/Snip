# 截图时机与浮动窗口系统阴影

## 问题现象

Snip 进入区域截图选择界面后，已有的浮动贴图仍然可见，但其 macOS 原生窗口阴影消失。此前通过贴图内容绘制边框或渐变阴影进行补偿，视觉效果不稳定，也会把模拟边框误认为截图内容的一部分。

同一条截图流程还存在菜单下拉框消失的问题：截图遮罩窗口创建并激活 Snip 后，macOS 菜单会关闭，因此遮罩出现后再截图无法得到触发快捷键瞬间的画面。

## 根本原因

### 1. 截图遮罩改变了 WindowServer 状态

旧流程大致如下：

1. 创建并激活 Snip 的全屏透明遮罩窗口。
2. 遮罩窗口成为更高层级窗口。
3. 系统菜单被关闭，浮动贴图失去原来的窗口合成状态。
4. 再通过 ScreenCaptureKit 采集屏幕或选区。

因此，后续采集到的是遮罩激活后的状态，而不是用户触发截图时的状态。

### 2. ScreenCaptureKit 内容帧不等同于完整窗口合成画面

`SCScreenshotManager.captureImage` 配合 `SCContentFilter` 主要返回 ScreenCaptureKit 的内容帧。即使浮动窗口配置了：

```swift
hasShadow = true
sharingType = .readOnly
```

也不能保证窗口 frame 外部由 WindowServer 绘制的原生阴影会出现在返回图像中。系统阴影属于窗口合成和 framing 效果，不是贴图图片本身的像素。

### 3. 系统阴影位于窗口 frame 外部

原生阴影通常扩展到 `NSWindow.frame` 之外。即使底层屏幕图像包含了阴影，如果最终选区只覆盖贴图 frame，裁剪时仍然会把阴影去掉。

## 最终解决方案

### 1. 在创建遮罩前预采集

`CaptureManager.startCapture()` 先调用 `captureInitialScreenImages()`，完成每个显示器的预采集后，才执行：

```swift
closeAllWindows()
createCaptureWindows(initialImages: initialImages)
```

预采集图像通过 `initialScreenImage` 注入 `CaptureView`。当预采集成功时，`CaptureView.viewDidMoveToWindow()` 不再延迟执行一次新的整屏采集；只有预采集失败的显示器才使用原有回退路径。

这样可以保留下列触发瞬间状态：

- macOS 菜单下拉框；
- 已有浮动贴图；
- WindowServer 当时合成的原生窗口阴影；
- 其他应用在截图快捷键触发瞬间的可见内容。

### 2. 预采集使用 WindowServer 合成图像

预采集优先使用 Quartz 的 `CGWindowListCreateImage`，并传入对应显示器的 Quartz 全局矩形：

```swift
let quartzBounds = CGDisplayBounds(displayID)
```

调用选项使用：

```swift
.optionOnScreenOnly
.bestResolution
```

不设置 `kCGWindowImageBoundsIgnoreFraming`，以请求包含窗口 framing 的合成屏幕图像。这样比 ScreenCaptureKit 内容帧更适合保留 AppKit 窗口的原生阴影。

当前 SDK 已将 `CGWindowListCreateImage` 标记为 macOS 15 obsolete。为保持项目 macOS 13 的部署目标，同时通过当前 SDK 编译，代码使用 `dlopen`/`dlsym` 动态查找 `CGWindowListCreateImage` 符号。若系统不提供该符号或调用失败，则保留 ScreenCaptureKit 的延迟采集回退路径。

### 3. 不再绘制模拟边框或阴影

浮动贴图本身继续使用：

```swift
hasShadow = true
```

但 `RasterImageView` 不再绘制额外的边框、渐变或模拟阴影。原因是：

- 模拟效果与 macOS 原生阴影不一致；
- 多层描边容易变成粗边框；
- 模拟阴影可能被误合并进截图内容；
- 预采集已经负责获取真实的 WindowServer 合成结果。

## 相关代码

- 预采集和 WindowServer 合成截图：[CaptureManager.swift](Snip/Managers/CaptureManager.swift)
- 预采集图像注入和选择界面：[CaptureView.swift](Snip/Views/Capture/CaptureView.swift)
- 浮动窗口原生阴影配置：[FloatingImageManager.swift](Snip/Managers/FloatingImageManager.swift)

## 验证要点

修改后应重点验证：

1. 触发截图时已有菜单下拉框仍出现在选择背景中。
2. 已有浮动贴图的系统阴影能在选择背景中保留。
3. 新的截图遮罩不会把浮动窗口提升到其上方。
4. 多显示器，尤其是非主屏和垂直排列屏幕，预采集坐标正确。
5. 选区覆盖贴图 frame 外围的阴影区域时，阴影能进入最终截图；只选贴图内容时，阴影被裁掉属于预期行为。
6. Quartz 合成截图失败时，单个显示器仍能回退到 ScreenCaptureKit 路径。

## 维护注意事项

不要把“ScreenCaptureKit 返回了图像”理解为“已经获得 WindowServer 完整合成图像”。涉及菜单、窗口外部阴影、窗口 framing 或截图触发时机的改动，应优先确认采集发生在遮罩激活前，并确认使用的是合适的合成截图路径。

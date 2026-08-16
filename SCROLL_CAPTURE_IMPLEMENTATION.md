# 长截图实现说明

本文档描述 Snip 当前仓库中实际生效的长截图实现。重点不是产品视角的使用说明，而是代码层面的实现链路、关键状态、事件流转和收尾策略。

如果你想先看项目总架构，再回来看长截图细节，建议先读：

- [README.md](README.md)
- [Snip/README.md](Snip/README.md)

## 1. 当前生效的代码路径

长截图不是一套独立模块，而是挂在截图编辑态上的一条特殊流程。核心文件如下：

- `Snip/Views/Capture/CaptureEditToolbar.swift`
- `Snip/Views/Capture/CaptureView.swift`
- `Snip/Views/Capture/AnnotationLayer.swift`
- `Snip/Managers/ScrollCaptureManager.swift`
- `Snip/Managers/CaptureManager.swift`
- `Snip/Managers/FloatingImageManager.swift`

入口调用链：

1. `CaptureEditToolbar.scrollCaptureClicked()`
2. `CaptureView.handleScrollCapture()`
3. `CaptureView.startScrollCaptureModeAsync()`
4. `ScrollCaptureManager.startAutoCapture(selectionHeight:captureBlock:)`

最终输出链路：

1. `CaptureView.finishCapture()`
2. `CaptureView.finishScrollCapture()`
3. `ScrollCaptureManager.stitchImages()`
4. `CaptureView.mergeAnnotations(...)`
5. `CaptureView.createRoundedImage(...)`
6. `CaptureManager.handleCapturedImage(...)`
7. `FloatingImageManager.createFloatingWindow(...)`

## 2. 整体设计思路

当前长截图的核心思路是：

- 先进入普通截图编辑态。
- 把用户框出的选区转换成固定的屏幕绝对区域。
- 在用户滚动目标应用时，重复采集这块固定区域。
- 用 Vision 估算相邻帧新增了多少内容。
- 只把“新增部分”追加到长图底部。
- 完成后再统一叠加标注、圆角并交给浮窗系统。

它不是 DOM 级截图，也不是针对某个控件树的语义截图；本质上仍然是屏幕重复采样，只是额外加入了滚动驱动、去重和增量拼接。

## 3. 进入长截图前的准备阶段

### 3.1 进入截图模式

用户触发截图后，`CaptureManager.startCapture()` 会为每块屏幕创建一个透明无边框 `CaptureWindow`，并把 `CaptureView` 挂到窗口上。

`CaptureView` 挂载到窗口后会异步执行 `captureScreenImage()`：

- 通过 `SCShareableContent` 找到当前屏幕对应的 display。
- 使用 `SCContentFilter(display:excludingWindows:)` 排除当前截图窗口自身。
- 使用 `SCStreamConfiguration` 按屏幕 backing scale 请求高分辨率底图。
- 在 macOS 14+ 上设置 `captureResolution = .best`。

这张图保存到 `screenImage`，只服务于普通截图编辑态。

### 3.2 进入编辑态

用户拖出选区并松开鼠标后，`CaptureView.enterEditMode()` 会：

- 创建 `AnnotationLayer`
- 创建 `CaptureEditToolbar`
- 绑定工具选择、样式变化、撤销/重做、完成、取消和长截图回调

在这个阶段，长截图还没有开始，当前仍然只是普通截图编辑态。

## 4. 开启长截图模式

### 4.1 模式切换入口

点击工具栏按钮后，`CaptureView.handleScrollCapture()` 会切换 `isScrollCaptureMode`。

如果切到开启状态，流程是：

1. 先把工具栏按钮高亮。
2. 异步调用 `startScrollCaptureModeAsync()`，避免阻塞当前 UI 事件。

如果切到关闭状态，则调用 `stopScrollCaptureMode()`，恢复普通编辑态。

### 4.2 `startScrollCaptureModeAsync()` 做了什么

这个方法是长截图正式开始前的准备中心，主要做六件事：

1. 调用 `bindScrollCaptureAnnotationTracking()`，把 `ScrollCaptureManager` 的滚动偏移同步到 `AnnotationLayer`。
2. 调用 `ScrollCaptureManager.shared.clear()`，清掉上一轮长截图状态。
3. 在窗口仍然是全屏时，记录选区的屏幕绝对坐标到 `scrollCaptureScreenRect`。
4. 释放 `screenImage`，避免长截图期间同时持有整屏底图。
5. 把编辑工具栏拆到独立的 `ScrollCaptureToolbarWindow`，再把主窗口缩小到选区附近。
6. 调用 `ScrollCaptureManager.startAutoCapture(...)`，启动滚动监听和自动采集。

这里最重要的设计点是：`scrollCaptureScreenRect` 会在窗口缩小之前就被固定下来。后续每一帧都围绕这块屏幕区域采集，不再依赖窗口坐标或普通截图底图。

## 5. 滚动事件是怎么流转的

长截图窗口缩小到选区后分为浏览态和标注态：

- 浏览态下捕获窗口设置 `ignoresMouseEvents = true`，选区内外的滚轮都由系统直接交给底层应用。Snip 不接收、不转发这些滚轮事件。
- 用户点击独立工具栏中的标注工具时，捕获窗口恢复点击和拖拽交互，工具保持激活，可连续创建多个同类标注。
- 长截图期间安装只监听的 CGEvent tap。工具激活时若检测到选区内滚轮，会在原始事件分发前临时暂停捕获窗口交互，使事件直接命中底层应用；tap 不消费、不复制、不注入滚轮。
- 滚动停止后恢复捕获窗口交互，之前选中的标注工具保持不变，可直接继续标注。

`ScrollCaptureManager` 只安装 global scroll monitor，不安装 local monitor。它旁路观察底层应用实际收到的滚轮事件，用于累计采样距离并更新标注预览，但不会拦截、重写或再次发布事件。

这就是当前实现里非常关键的一点：页面原生收到的滚动事件是采样调度和标注预览的共同来源，覆盖层不参与滚轮路由。Vision 测量仍只负责最终拼接高度。

## 6. `ScrollCaptureManager` 的状态模型

`ScrollCaptureManager` 是长截图期间的状态机，主要状态如下：

- `stitchedImage`：当前已经增量合成的长图。
- `lastCapturedImage`：最后一张通过配准确认的采样帧。
- `captureCount`：当前有效帧数。
- `totalAppendedHeight`：已经成功拼到长图上的总新增高度。
- `currentViewportOffset`：当前视口相对起始选区的实时标注预览偏移，向下为正、向上为负。
- `confirmedViewportPosition`：由相邻帧 Vision 位移累计得到的确认位置，起始选区为 0。
- `topCapturedPosition` / `bottomCapturedPosition`：当前已捕获范围相对起点的上、下边界。
- `topAppendedHeight` / `bottomAppendedHeight`：长图顶部和底部分别新增的高度。
- `pendingScrollDistance`：尚未进入采样任务的滚轮活动量，只用于调度。
- `inFlightScrollDistance`：当前采样任务开始时消费的滚轮活动量；系统采样失败时会归还给待采样队列。
- `minimumCaptureDistance`：最低触发抓图距离。
- `preferredCaptureDistance`：理想抓图距离。
- `isCaptureInFlight`：当前是否已有采集任务进行中。
- `delayedCaptureTask`：由于采样频率限制而被延后执行的任务。
- `captureSessionID`：用来隔离旧任务、防止旧结果写回新会话。

状态模型明确区分“实时预览”和“最终拼接”：

- `pendingScrollDistance` 控制抓图阈值。
- `currentViewportOffset` 由滚轮进度同步更新，用于实时移动标注；首次 Vision 配准会校准滚轮符号与文档方向的关系。
- `totalAppendedHeight` 只由相邻帧 Vision 配准结果更新，用于长图拼接和最终导出。
- 截图完成不会把实时标注偏移重置到低频采样位置，因此滚动过程中不会出现周期性回弹。

## 7. 抓图触发策略

### 7.1 开始时会先抓第一帧

`startAutoCapture(selectionHeight:captureBlock:)` 会先：

- `clear()`
- 根据选区高度计算阈值
- 安装滚轮监听
- 立刻调用 `requestCapture(isInitial: true)`

所以长截图一开启，就会先抓一张“起始帧”，哪怕用户还没开始滚动。

### 7.2 距离阈值

阈值随选区高度变化：

- `minimumCaptureDistance = max(18, min(selectionHeight * 0.10, 60))`
- `preferredCaptureDistance = max(min(selectionHeight * 0.40, 180), minimumCaptureDistance)`

含义是：

- 少量滚动先累积，不要过于频繁截图。
- 滚动到一个更理想的步长时，优先立即抓图。

### 7.3 时间阈值

除了距离，还有节流时间：

- `minimumCaptureInterval = 0.16`
- `settlementInterval = 0.28`

逻辑是：

- 如果距离到了，但距离上次抓图太近，则延后执行。
- 每次滚动都会重置 settlement timer。
- 用户停止滚动一小段时间后，如果还有未捕获内容，会补抓最后一帧。

### 7.4 主导滚动方向

`handleObservedScrollEvent(_:)` 会先把滚动量标准化，并用 `dominantScrollSign` 建立本次会话稳定的滚轮进度坐标。物理上的向上或向下不直接由滚轮正负决定，因为 macOS 自然滚动设置会改变符号语义；第一组有效 Vision 配准会校准滚轮进度与文档方向的符号关系。

长截图以初始选区为位置 0，并维护已捕获的上、下边界。用户在已捕获范围内反向滚动时仍持续采样和更新 `lastCapturedImage`，但不重复拼图；越过下边界时向长图底部追加，回到起点并越过上边界时向长图顶部追加。因此同一会话可以先完成默认的向下截图，再补充起始位置上方的截图和标注。

## 8. 每一帧是如何采集的

### 8.1 采集入口

`ScrollCaptureManager` 本身不直接采图，而是通过 `captureProvider` 回调到：

- `CaptureView.captureCurrentSelection()`
- `CaptureView.captureScreenRegion(in:)`

### 8.2 固定屏幕绝对区域

`captureCurrentSelection()` 直接使用 `scrollCaptureScreenRect`，也就是开启长截图前保存下来的屏幕绝对坐标。

这个设计解决了几个问题：

- 窗口缩小后坐标系变化不会影响采样区域。
- 工具栏拆到独立窗口后，不会干扰采样目标区域。
- 采集源始终来自系统当前屏幕，而不是一张旧底图的重复裁切。

### 8.3 像素对齐

`pixelAlignedCaptureRegion(forScreenRect:)` 会把逻辑坐标转换成像素坐标，并确保边界稳定：

- 左/上边界向下取整
- 右/下边界向上取整
- 重新推导对齐后的 `logicalSize`
- 同时生成 `sourceRect` 和 `cropRect`

这样做的意义是：

- 避免半像素裁切
- 保证 Retina 下文字和细线尽量清晰
- 降低多帧拼接时 1px 误差累积的概率

### 8.4 ScreenCaptureKit 配置

区域采集使用：

- `SCContentFilter(display:excludingWindows:)`
- `SCStreamConfiguration.sourceRect`
- `SCStreamConfiguration.width`
- `SCStreamConfiguration.height`

同时：

- 排除当前截图窗口自身
- `showsCursor = false`
- macOS 14+ 使用 `captureResolution = .best`

## 9. 标注层如何跟随滚动预览

长截图不是只有底图在变，标注层也必须跟着可视区域移动，否则用户在滚动后继续标注会错位。

### 9.1 预览偏移

`bindScrollCaptureAnnotationTracking()` 会把 `ScrollCaptureManager.onViewportOffsetChanged` 绑定到 `AnnotationLayer.setViewportOffset(_:)`。

manager 通过唯一的 global monitor 观察页面实际收到的滚轮事件，并在回调已经位于主线程时直接更新预览偏移，避免无条件排入下一个 run loop；异常后台回调才切回 main actor。标注层内外的滚动因此进入同一个状态入口，不会出现一侧只动页面、另一侧只动标注的分裂状态。

`setViewportOffset(_:)` 会按当前窗口的 `backingScaleFactor` 把预览偏移对齐到物理像素边界，再同步移动正在编辑中的文本输入框。这样可以避免触控板小数 point 偏移让细线在相邻像素之间反复抗锯齿。该方法不会立刻改写已有标注的真实坐标。

### 9.2 标注的坐标系

`AnnotationLayer` 内部区分两种坐标：

- document 坐标：标注真实存储坐标
- view 坐标：当前可视状态下的绘制坐标

关键转换是：

- `documentPoint(from:)` 会把视图点减去 `viewportOffsetY`
- `viewPoint(from:offsetY:)` 会把 document 点加上偏移再绘制

这样用户在滚动后的可视区域上继续画标注时，记录到的数据仍然是“长图坐标”，不是“当前窗口局部坐标”。

### 9.3 为什么有时要提交偏移，有时不要

长截图相关有两种收尾方式：

1. 用户只是关闭长截图模式，想回到普通编辑态继续改图。
2. 用户已经完成长截图，要直接输出结果。

对应实现：

- `endScrollCaptureAnnotationTracking(committingVisibleState: true)`：
  调用 `AnnotationLayer.commitViewportOffset()`，把当前可视偏移真正写回标注数据，适合“退出长截图但继续编辑”。
- `endScrollCaptureAnnotationTracking(committingVisibleState: false)`：
  只把预览偏移清零，不改写标注数据，适合“已经按长图逻辑导出完毕”。

最终导出长图时，`mergeAnnotations(...)` 会传入 `annotationOffsetForOutput`，其值始终为 `bottomAppendedHeight`。底部新增内容会把原有画布和标注整体抬高；顶部新增内容不会改变既有内容坐标。向上区域中新建的标注通过负 `currentViewportOffset` 自动写入起始位置上方的文档坐标，因此已有截图和标注在补充顶部内容时保持不变。

## 10. 帧去重与新增高度估算

### 10.1 第一帧

第一帧没有前驱图像，会成为 `stitchedImage` 和 `lastCapturedImage`，不会产生新增高度。

### 10.2 后续帧

后续每一帧进入 `appendCapture(_:)` 后，会优先尝试：

- `estimatedVerticalTranslation(from:to:)`

这个方法基于：

- `VNTranslationalImageRegistrationRequest`

处理逻辑是：

1. 对当前帧和上一帧做平移配准。
2. 读取 `alignmentTransform.ty`。
3. 用当前图像的像素密度换算成 points。
4. 保留正负方向，并把结果限制在 `-currentImage.size.height...currentImage.size.height`。
5. 将有符号位移累加到 `confirmedViewportPosition`，用于判断当前视口是在已捕获范围内，还是越过了顶部或底部边界。

### 10.3 去重与兜底

如果估算结果存在，则会进一步做：

- 使用位移绝对值作为新增高度，并限制在 `0...currentImage.logicalSize.height`，防止异常配准结果越界。
- 若小于 `minimumMeaningfulStep = 6pt`，视为重复帧，直接跳过。

如果 Vision 配准失败，当前帧不会写入长图，也不会使用滚轮距离移动标注。manager 保留上一张已确认帧，等待下一次采样跨帧重新配准。这样会牺牲一次采样进度，但不会把未经图像验证的距离永久写进长图和标注坐标。

## 11. 拼接算法

拼接入口是 `ScrollCaptureManager.stitchImages()`。

当前实现会在相邻帧完成配准后更新确认位置，并只在越过已捕获边界时调用 `composite(base:with:appendedHeight:edge:)`：

1. 第一帧作为初始 `stitchedImage`，起始位置记为 0。
2. Vision 计算新帧相对 `lastCapturedImage` 的有符号垂直位移并更新当前位置。
3. 当前视口仍在已捕获范围内时，只替换 `lastCapturedImage`，不修改长图。
4. 越过下边界时创建扩展画布，把旧长图上移、新帧绘制在底部。
5. 越过上边界时旧长图留在底部、新帧绘制在顶部，已有内容坐标不变。
6. 不保留所有历史采样帧，只保留增量长图和最近的配准锚点。

### 11.1 为什么是“增量拼接”

不是每一帧都整张往下堆，而是：

- 旧图完整保留
- 新图只贡献会话方向一端的新增部分

这样可以降低：

- 重复内容累积
- 粘连错位
- 长图尺寸膨胀

### 11.2 为什么直接用 `CGContext`

当前实现没有走 `NSImage.lockFocus()`，而是：

- 先把 `NSImage` 转成带像素密度信息的 `RasterImage`
- 基于 `CGContext` 创建像素级画布
- 用像素高度计算新增区域位置
- 最后再包装回 `NSImage`

这样做的目的是尽量保留原始像素密度，避免在 Retina 屏幕上被重新栅格化成模糊的 1x 图像。

## 12. 结束长截图时的三条分支

`CaptureView.finishCapture()` 会根据当前状态走不同路径。

### 12.1 正常长截图输出

条件：

- `isScrollCaptureMode == true`
- `ScrollCaptureManager.shared.captureCount > 0`

流程：

1. `finishScrollCapture()`
2. `ScrollCaptureManager.stopAutoCapture()`
3. `ScrollCaptureManager.waitForIdle()`
4. 如果还有未捕获内容，则再抓最后一张并 `addFinalImage(_:)`
5. `performStitchAndSave()`

### 12.2 长截图模式已开，但还没有有效帧

条件：

- `isScrollCaptureMode == true`
- `captureCount == 0`

这时不会强行拼接，而是：

1. 清理长截图状态
2. 保留 `scrollCaptureScreenRect`
3. 直接对保存下来的固定区域做一次普通采集

也就是说，就算用户打开了长截图模式但几乎没滚动，最终仍然能拿到一张基于当前选区的正常图片。

### 12.3 普通截图输出

如果根本不在长截图模式，就走普通的 `captureSelection()` 路径。

## 13. `performStitchAndSave()` 之后发生了什么

### 13.1 拼接失败时

如果 `stitchImages()` 返回 `nil`，当前实现不会直接报错退出，而是回退到普通截图方案：

- 提交当前标注可视偏移
- 清掉长截图状态
- 恢复全屏窗口
- 关闭长截图按钮高亮
- 对保存的 `scrollCaptureScreenRect` 再做一次普通区域采样

这是一个非常实用的兜底：即使拼接失败，用户至少还能拿到当前可视区域的截图。

### 13.2 拼接成功时

成功后进入统一后处理链路：

1. `mergeAnnotations(baseImage:annotationLayer:annotationOffsetY:)`
2. `createRoundedImage(from:cornerRadius:)`
3. 用 `scrollCaptureScreenRect.origin` 作为浮窗位置
4. 清理长截图状态
5. 通过 `onCapture` 回调交给 `CaptureManager`

这里 `annotationOffsetY` 传的是：

- `ScrollCaptureManager.shared.totalAppendedHeight`

这表示标注导出时会按照最终长图高度来绘制，而不是当前窗口可视位置。

## 14. 标注合成、圆角和输出质量

### 14.1 标注合成

`mergeAnnotations(...)` 的流程是：

1. 把底图转成像素级 `RasterizedImage`
2. 调用 `AnnotationLayer.captureAsImage(...)` 导出标注位图
3. 在同一个像素画布里先画底图，再画标注层

`AnnotationLayer.captureAsImage(...)` 会：

- 使用 `NSBitmapImageRep` 创建指定像素尺寸的透明画布
- 按 `logicalSize -> pixelWidth/pixelHeight` 做坐标缩放
- 调用 `drawAnnotations(offsetY:showsEditingOverlay:)`
- 明确关闭编辑控制点等 overlay，只导出真正标注内容

### 14.2 圆角处理

`createRoundedImage(...)` 不是用逻辑点裁圆角，而是：

- 先读取图像的 `pixelsPerPointX / pixelsPerPointY`
- 把圆角半径换算到像素空间
- 在像素画布中 clip 后重绘

这样能尽量减少圆角边缘模糊。

### 14.3 最终浮窗

长截图完成后，并不会进入一套单独的“长图查看器”，而是和普通截图走同一条浮窗输出链路：

- `CaptureManager.handleCapturedImage(...)`
- `FloatingImageManager.createFloatingWindow(...)`

浮窗会：

- 限制初始显示尺寸在可视区域内
- 但保留原始图片用于复制
- `Cmd + C` 时复制原图，而不是当前显示缩放结果

## 15. 关闭长截图模式但不输出时的恢复逻辑

如果用户点击长截图按钮再次关闭该模式，而不是点击完成，则会走 `stopScrollCaptureMode()`：

1. 取消滚动转发恢复任务
2. 提交当前标注可视偏移
3. 清空 `ScrollCaptureManager`
4. 恢复主窗口交互
5. 把工具栏从独立面板重新挂回主窗口
6. 把截图窗口恢复到全屏
7. 重新执行 `captureScreenImage()`，拿回普通编辑态底图

这说明当前实现并不是“一旦开启长截图就只能完成或取消”，而是支持从长截图模式平滑退回普通编辑模式继续操作。

## 16. 清理与生命周期

长截图相关资源主要在三处被清理：

- `ScrollCaptureManager.stopAutoCapture()`
  停掉采样调度、延迟任务和 settlement timer。
- `ScrollCaptureManager.clear()`
  重置全部采集与拼接状态，并让视口偏移回到 0。
- `CaptureView.cleanup()`
  取消任务、解绑回调、移除工具栏/标注层/独立面板、清掉底图。

`CaptureWindow` 本身通过 `allowsInteractiveInput` 控制是否允许成为 key/main window。长截图浏览态关闭交互并忽略鼠标，只有用户主动选择标注工具时才临时恢复输入。

## 17. 标注层滚动抖动问题记录

### 17.1 现象

长截图滚动时曾出现以下几种不一致：

- 标注层相对页面内容轻微抖动或晚一拍。
- 鼠标位于标注层内时，标注移动但底层页面不滚动。
- 鼠标位于标注层外时，页面滚动但标注不移动。
- 触控板产生小数 point 位移时，细线在相邻物理像素之间反复抗锯齿。

### 17.2 根因

长截图窗口缩小后，标注层内外的滚轮由不同路径处理。旧实现同时安装 global/local monitor，并通过异步 main actor 任务更新标注；标注层内又尝试使用 `postToPid` 转发事件。这造成了四个问题：

1. 同一个滚轮可能被不同监听路径重复或延迟处理。
2. `postToPid` 不能可靠驱动 AppKit/WebKit 的实际滚动。
3. 页面先滚动，标注偏移在下一个主线程周期才更新。
4. 未对齐物理像素的小数偏移会造成细线视觉闪动。

### 17.3 最终方案

- 浏览态下整个选区窗口原生穿透，标注层内外的滚轮都直接进入底层页面。
- 标注工具保持连续激活；只监听的事件 tap 在滚轮分发前临时暂停窗口交互，原始滚轮直接进入底层页面。
- tap 不消费、不复制、不注入滚轮；滚动停止后恢复标注交互，工具选择保持不变。
- `ScrollCaptureManager` 只保留一个 global monitor，旁路观察页面实际收到的滚轮事件。
- global monitor 已在主线程时直接更新状态，不再无条件排入下一个 run loop；后台回调才切换到 main actor。
- 原始滚轮距离负责实时标注预览和采样调度，Vision 配准结果负责最终拼接高度。
- `AnnotationLayer` 按窗口 `backingScaleFactor` 对齐偏移到物理像素边界。
- Vision 配准失败时不再使用滚轮估算距离追加长图，避免把未经图像确认的误差固化到结果中。

### 17.4 未采用的方案

- 直接使用 `postToPid`：运行时不能稳定推动目标页面滚动。
- 临时穿透后通过 HID tap 重新注入：目标应用激活和 WindowServer 分发存在竞态，事件可能重新命中标注层并造成卡顿。
- 同时使用 global/local monitor：会形成重复、乱序或区域分裂的滚动状态。
- 仅等待 Vision 完成后移动标注：虽然稳定，但采样有节流，标注会表现为不滚动或明显跳帧。
- 每个滚轮事件都异步派发到主线程：快速滚动时任务排队，产生一拍延迟和轻微抖动。

### 17.5 残余限制

标注预览由滚轮事件估算，最终拼接由 Vision 测量，两者职责不同。目标应用的滚动加速、边界阻尼、吸顶元素和动态内容仍可能带来少量视觉误差，但不会再由重复监听或亚像素绘制造成持续抖动。

## 18. 当前实现的限制

这套方案已经足够实用，但边界很明确：

- 它依赖图像平移配准，不保证对吸顶栏、悬浮元素、动态广告、自动播放视频完全稳定。
- 支持同一会话先向下扩展、回到起点后再向上扩展；在已捕获范围内滚动只更新配准锚点，不重复拼图。
- 主要针对纵向滚动优化，横向滚动不是主目标。
- 如果页面在滚动时同时发生大面积异步刷新，新增高度估算会变差。
- 当前没有自动识别“应该结束长截图”，结束动作仍然由用户触发。
- 目前没有针对长截图的自动化回归样例，验证主要依赖手工测试。

## 19. 一句话总结

当前长截图实现可以概括为：

“在截图编辑态中固定屏幕绝对区域，让底层应用原生接收滚轮，由全局旁路观察按距离节流采样，使用 Vision 估算新增高度，再基于原始像素做双端增量拼接，并在输出前统一合成标注与圆角。”

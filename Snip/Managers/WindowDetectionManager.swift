import AppKit
import CoreGraphics

@available(macOS 13.0, *)
class WindowDetectionManager {
    static let shared = WindowDetectionManager()

    private init() {}

    // MARK: - 窗口检测

    /// 检测鼠标位置的窗口边界
    func detectWindowAtPoint(_ point: NSPoint) -> NSRect? {
        // 获取所有窗口信息
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // 遍历窗口，找到鼠标所在的窗口
        for windowInfo in windowList {
            guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"] else {
                continue
            }

            // 转换坐标系（CGWindow 使用左上角为原点，NSScreen 使用左下角为原点）
            guard let screenHeight = NSScreen.main?.frame.height else { continue }
            let windowRect = NSRect(
                x: x,
                y: screenHeight - y - height,
                width: width,
                height: height
            )

            // 检查点是否在窗口内
            if windowRect.contains(point) {
                // 过滤掉太小的窗口（可能是菜单栏图标等）
                if width > 100 && height > 100 {
                    return windowRect
                }
            }
        }

        return nil
    }

    /// 获取所有可见窗口的边界
    func getAllVisibleWindows() -> [NSRect] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var windows: [NSRect] = []
        guard let screenHeight = NSScreen.main?.frame.height else { return [] }

        for windowInfo in windowList {
            guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"],
                  width > 100 && height > 100 else {
                continue
            }

            let windowRect = NSRect(
                x: x,
                y: screenHeight - y - height,
                width: width,
                height: height
            )
            windows.append(windowRect)
        }

        return windows
    }

    /// 查找最接近给定矩形的窗口
    func findNearestWindow(to rect: NSRect) -> NSRect? {
        let windows = getAllVisibleWindows()
        guard !windows.isEmpty else { return nil }

        let rectCenter = NSPoint(x: rect.midX, y: rect.midY)

        var nearestWindow: NSRect?
        var minDistance: CGFloat = .infinity

        for window in windows {
            let windowCenter = NSPoint(x: window.midX, y: window.midY)
            let distance = hypot(rectCenter.x - windowCenter.x, rectCenter.y - windowCenter.y)

            if distance < minDistance {
                minDistance = distance
                nearestWindow = window
            }
        }

        return nearestWindow
    }

    /// 智能吸附：如果选区接近窗口边界，自动吸附
    func snapToWindow(_ rect: NSRect, threshold: CGFloat = 20) -> NSRect {
        let windows = getAllVisibleWindows()

        for window in windows {
            // 检查是否接近窗口边界
            if abs(rect.minX - window.minX) < threshold &&
               abs(rect.minY - window.minY) < threshold &&
               abs(rect.maxX - window.maxX) < threshold &&
               abs(rect.maxY - window.maxY) < threshold {
                return window
            }
        }

        return rect
    }
}

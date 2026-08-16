import Foundation
import AppKit

// 标注工具枚举
enum AnnotationTool: Int {
    case select = -1  // 选择工具
    case line = 0     // 箭头工具（支持切换为直线）
    case rectangle = 1
    case pen = 2
    case text = 3
    case mosaic = 4   // 马赛克工具
}

// 线条样式
enum LineStyle: Int {
    case straight = 0       // 直线
    case arrow = 1          // 实心箭头
    case arrowLarge = 2     // 空心箭头
    case arrowHollow = 3    // 开放箭头
}

// 形状样式
enum ShapeStyle: Int {
    case rectangle = 0  // 矩形
    case ellipse = 1    // 椭圆
}

// 标注属性
struct AnnotationStyle {
    var lineStyle: LineStyle = .arrow
    var shapeStyle: ShapeStyle = .rectangle
    var lineWidth: CGFloat = 2
    var color: NSColor = .red
    var lineCurvature: CGFloat = 0

    // 文本属性
    var fontSize: CGFloat = 16
    var isBold: Bool = false
    var isItalic: Bool = false
    var fontName: String = "PingFang SC"
}

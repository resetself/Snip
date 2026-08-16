# Snip

**English** | [简体中文](README_CN.md)

Snip is a native macOS screenshot and image-pinning utility focused on fast capture, immediate annotation, and floating references. It is built with Swift and AppKit and supports region capture, annotation editing, scrolling screenshots, clipboard pinning, and customizable shortcuts.

## Features

- Region capture with live dimensions, multi-display support, and Retina-resolution output
- Annotation tools for arrows/lines, rectangles/ellipses, freehand drawing, text, mosaic, undo, and redo
- Straight pen strokes by holding `Option` or `Shift` while drawing
- Rounded output with quick presets, a context menu, and scroll-wheel adjustment
- Scrolling screenshots with automatic capture, image registration, and upward/downward expansion in one session
- Floating image output, `Cmd + C` copy, and `Cmd + S` PNG/JPEG saving
- Always-on-top image windows with dragging, scroll-wheel scaling, and quick dismissal
- Direct image pinning from the system clipboard
- Customizable global shortcuts for capture and pinning

Default shortcuts:

- Capture: `Option + A`
- Pin clipboard image: `Option + V`

## Requirements

- macOS 14.0 or later
- Xcode

Snip has no third-party dependencies.

## Download

Tagged releases automatically build a universal macOS DMG for Apple Silicon and Intel Macs. Download the latest installer from the repository's **Releases** page, open the DMG, and drag `Snip.app` to `Applications`.

The package is currently unsigned and not notarized. macOS may require explicit approval before the first launch.

## Technology

- Swift 5
- AppKit
- ScreenCaptureKit
- Vision
- Carbon Event HotKey

## Build and Run

1. Open [Snip.xcodeproj](Snip.xcodeproj) in Xcode.
2. Select the `Snip` scheme.
3. Choose `My Mac` and run the project.

You can also build from the command line:

```bash
xcodebuild \
  -project Snip.xcodeproj \
  -scheme Snip \
  -configuration Debug \
  build
```

Open `Snip.xcodeproj` in Xcode to manage targets, build settings, resources, and other project configuration.

## Usage

### Capture and Annotate

1. Start capture from the global shortcut or menu bar menu.
2. Drag to create a capture region.
3. Use the editing toolbar to add annotations, change styles, or undo/redo changes.
4. Finish to create a floating image, or copy/save the screenshot.

### Scrolling Capture

1. Create a region and enter editing mode.
2. Select the scrolling capture tool.
3. Scroll the target application while Snip captures and stitches the content automatically.
4. Extend downward, return to the initial position, and continue upward within the same session when needed.
5. Finish to output the stitched image.

### Floating Images

Floating image windows support:

- Dragging to reposition
- Scroll-wheel scaling from `0.1x` to `5x`
- `Cmd + C` to copy the original image
- Double-click, `Esc`, `Delete`, or `Cmd + W` to dismiss

### Clipboard Pinning

When the clipboard contains an image, use the menu bar action or pin shortcut to create a floating image near the current pointer location.

## Permissions

Snip uses the following macOS permissions:

- Screen Recording for region and scrolling capture
- Accessibility for global shortcuts and system event coordination

Snip requests Screen Recording access when capture is first triggered. Trigger capture again after granting permission.

## Project Structure

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

See [Snip/README.md](Snip/README.md) for a detailed Chinese architecture overview.

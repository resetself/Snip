@preconcurrency import AppKit
import Foundation
import ImageIO
import Darwin

private enum HelperCommand: String, Codable {
    case capture
    case paste
    case quit
}

private struct HelperCommandEnvelope: Codable {
    let command: HelperCommand
}

private struct HelperEventEnvelope: Codable {
    let event: String
    let message: String?
}

@MainActor
enum HelperLifetimeCoordinator {
    private(set) static var operationCount = 0
    static var onActivityChanged: (() -> Void)?

    static func beginOperation() {
        operationCount += 1
        onActivityChanged?()
    }

    static func endOperation() {
        operationCount = max(0, operationCount - 1)
        onActivityChanged?()
    }
}

@MainActor
final class CaptureHelperController {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var pendingCommands: [HelperCommand] = []
    private var commandsAwaitingReplacementHelper: [HelperCommand] = []
    private var isReady = false
    private var didReceiveIdleEvent = false
    private var shutdownCompletion: (() -> Void)?
    private var forcedTerminationWorkItem: DispatchWorkItem?

    func capture() {
        send(.capture)
    }

    func paste() {
        send(.paste)
    }

    func shutdown(completion: @escaping () -> Void) {
        guard let process, process.isRunning else {
            completion()
            return
        }

        shutdownCompletion = completion
        send(.quit)

        let workItem = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            Logger.log("⚠️ 辅助进程未及时退出，发送 terminate")
            process.terminate()
            self.forcedTerminationWorkItem = nil
        }
        forcedTerminationWorkItem?.cancel()
        forcedTerminationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func send(_ command: HelperCommand) {
        if command != .quit {
            forcedTerminationWorkItem?.cancel()
            forcedTerminationWorkItem = nil
        }

        guard let process, process.isRunning else {
            pendingCommands.append(command)
            launchHelperIfNeeded()
            return
        }

        if didReceiveIdleEvent {
            commandsAwaitingReplacementHelper.append(command)
            return
        }

        guard isReady else {
            pendingCommands.append(command)
            return
        }

        write(command)
    }

    private func launchHelperIfNeeded() {
        guard process?.isRunning != true else { return }
        guard let executableURL = Bundle.main.executableURL else {
            Logger.log("❌ 找不到 Snip 可执行文件，无法启动图形辅助进程")
            pendingCommands.removeAll()
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--ui-helper"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Keep diagnostics out of the JSON protocol pipe and visible in the parent console.
        process.standardError = FileHandle.standardError

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { [weak self] in
                self?.consumeHelperOutput(data)
            }
        }

        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, self.process === process else { return }
                let reason: String
                switch terminatedProcess.terminationReason {
                case .exit:
                    reason = "exit"
                case .uncaughtSignal:
                    reason = "signal"
                @unknown default:
                    reason = "unknown"
                }
                Logger.log(
                    "🧹 图形辅助进程已退出 pid=\(terminatedProcess.processIdentifier) " +
                        "reason=\(reason) status=\(terminatedProcess.terminationStatus)"
                )
                self.finishProcessLifecycle()
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            isReady = false
            didReceiveIdleEvent = false
            Logger.log("🚀 已启动图形辅助进程 pid=\(process.processIdentifier)")
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Logger.log("❌ 图形辅助进程启动失败: \(error.localizedDescription)")
            pendingCommands.removeAll()
            finishProcessLifecycle()
        }
    }

    private func consumeHelperOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(HelperEventEnvelope.self, from: Data(line)) else {
                continue
            }

            switch event.event {
            case "ready":
                isReady = true
                let commands = pendingCommands
                pendingCommands.removeAll()
                commands.forEach(write)
            case "idle":
                // The helper is committed to exiting. Only commands received after this
                // acknowledgement may be replayed in a fresh process.
                isReady = false
                didReceiveIdleEvent = true
            case "error":
                Logger.log("⚠️ 辅助进程: \(event.message ?? "未知错误")")
            default:
                break
            }
        }
    }

    private func write(_ command: HelperCommand) {
        guard let input = inputPipe?.fileHandleForWriting,
              let encoded = try? JSONEncoder().encode(HelperCommandEnvelope(command: command)) else {
            return
        }

        var line = encoded
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            Logger.log("⚠️ 无法向图形辅助进程发送命令: \(error.localizedDescription)")
        }
    }

    private func finishProcessLifecycle() {
        forcedTerminationWorkItem?.cancel()
        forcedTerminationWorkItem = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        isReady = false

        if let completion = shutdownCompletion {
            shutdownCompletion = nil
            pendingCommands.removeAll()
            commandsAwaitingReplacementHelper.removeAll()
            completion()
        } else if didReceiveIdleEvent, !commandsAwaitingReplacementHelper.isEmpty {
            // A command can legitimately race with a clean, acknowledged idle exit.
            pendingCommands = commandsAwaitingReplacementHelper
            commandsAwaitingReplacementHelper.removeAll()
            didReceiveIdleEvent = false
            launchHelperIfNeeded()
        } else {
            // Startup failures and crashes must never create a restart storm. The user can
            // explicitly retry with the next shortcut invocation.
            pendingCommands.removeAll()
            commandsAwaitingReplacementHelper.removeAll()
            didReceiveIdleEvent = false
        }
    }
}

@available(macOS 13.0, *)
@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var captureManager: CaptureManager?
    private var commandServer: HelperCommandServer?
    private var idleExitWorkItem: DispatchWorkItem?
    private var hasHandledCommand = false
    private var isPasteInProgress = false
    private var isExplicitQuitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Logger.log("🚀 图形辅助进程启动 pid=\(ProcessInfo.processInfo.processIdentifier)")

        let captureManager = CaptureManager()
        captureManager.onActivityChanged = { [weak self] in
            self?.scheduleExitIfIdle()
        }
        self.captureManager = captureManager

        FloatingImageManager.shared.onActivityChanged = { [weak self] in
            self?.scheduleExitIfIdle()
        }
        HelperLifetimeCoordinator.onActivityChanged = { [weak self] in
            self?.scheduleExitIfIdle()
        }

        IdleMemoryReclaimer.shared.start()
        let commandServer = HelperCommandServer { [weak self] command in
            self?.handle(command)
        }
        self.commandServer = commandServer
        commandServer.start()
        sendEvent("ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleExitWorkItem?.cancel()
        commandServer?.stop()
        HelperLifetimeCoordinator.onActivityChanged = nil
        IdleMemoryReclaimer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isExplicitQuitRequested ? .terminateNow : .terminateCancel
    }

    private func handle(_ command: HelperCommand) {
        hasHandledCommand = true
        idleExitWorkItem?.cancel()
        idleExitWorkItem = nil

        switch command {
        case .capture:
            sendEvent("busy")
            captureManager?.startCapture()
            scheduleExitIfIdle()
        case .paste:
            sendEvent("busy")
            handlePaste()
        case .quit:
            isExplicitQuitRequested = true
            captureManager?.cancelCapture()
            FloatingImageManager.shared.closeAllWindows()
            ScrollCaptureManager.shared.clear()
            Task {
                await ScreenCaptureContentCache.shared.invalidate()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func handlePaste() {
        isPasteInProgress = true
        defer {
            isPasteInProgress = false
            malloc_zone_pressure_relief(nil, 0)
            scheduleExitIfIdle()
        }

        let createdWindow = autoreleasepool { () -> Bool in
            let pasteboard = NSPasteboard.general

            if let pngData = pasteboard.data(forType: .png),
               let rasterImage = makeRasterImage(from: pngData, label: "pasteboard-png") {
                FloatingImageManager.shared.createFloatingWindow(with: rasterImage, at: NSEvent.mouseLocation)
                return true
            }

            if let tiffData = pasteboard.data(forType: .tiff),
               let rasterImage = makeRasterImage(from: tiffData, label: "pasteboard-tiff") {
                FloatingImageManager.shared.createFloatingWindow(with: rasterImage, at: NSEvent.mouseLocation)
                return true
            }

            if let image = NSImage(pasteboard: pasteboard),
               let rasterImage = ManagedRasterImage(nsImage: image, label: "pasteboard") {
                FloatingImageManager.shared.createFloatingWindow(with: rasterImage, at: NSEvent.mouseLocation)
                return true
            }

            return false
        }

        if !createdWindow {
            NSSound.beep()
            sendEvent("error", message: "剪贴板中没有图片")
        }
    }

    private func makeRasterImage(from data: Data, label: String) -> ManagedRasterImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width > 0,
              cgImage.height > 0 else {
            return nil
        }

        let scale: CGFloat = 2
        return ManagedRasterImage(
            cgImage: cgImage,
            logicalSize: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale),
            label: label
        )
    }

    private func scheduleExitIfIdle() {
        idleExitWorkItem?.cancel()
        idleExitWorkItem = nil

        guard hasHandledCommand,
              !isPasteInProgress,
              HelperLifetimeCoordinator.operationCount == 0,
              captureManager?.hasActiveCaptureSession != true,
              FloatingImageManager.shared.activeWindowCount == 0 else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isPasteInProgress,
                  HelperLifetimeCoordinator.operationCount == 0,
                  self.captureManager?.hasActiveCaptureSession != true,
                  FloatingImageManager.shared.activeWindowCount == 0 else {
                return
            }

            self.sendEvent("idle")
            self.isExplicitQuitRequested = true
            Logger.log("🧹 图形辅助进程已空闲，准备退出")
            NSApplication.shared.terminate(nil)
        }
        idleExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func sendEvent(_ event: String, message: String? = nil) {
        guard let data = try? JSONEncoder().encode(HelperEventEnvelope(event: event, message: message)) else {
            return
        }
        var line = data
        line.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: line)
    }
}

private final class HelperCommandServer {
    private let onCommand: @MainActor (HelperCommand) -> Void
    private var buffer = Data()

    init(onCommand: @escaping @MainActor (HelperCommand) -> Void) {
        self.onCommand = onCommand
    }

    func start() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                DispatchQueue.main.async { [onCommand = self.onCommand] in
                    onCommand(.quit)
                }
                return
            }
            self.consume(data)
        }
    }

    func stop() {
        FileHandle.standardInput.readabilityHandler = nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let envelope = try? JSONDecoder().decode(HelperCommandEnvelope.self, from: Data(line)) else {
                continue
            }
            DispatchQueue.main.async { [onCommand] in
                onCommand(envelope.command)
            }
        }
    }
}

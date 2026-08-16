import Darwin
import Foundation

struct Logger {
    private struct MemorySnapshot {
        let residentBytes: UInt64
        let footprintBytes: UInt64?
        let compressedBytes: UInt64?

        nonisolated var formattedSummary: String {
            var parts = ["resident \(Logger.formatBytes(residentBytes))"]

            if let footprintBytes {
                parts.append("footprint \(Logger.formatBytes(footprintBytes))")
            }

            if let compressedBytes {
                parts.append("compressed \(Logger.formatBytes(compressedBytes))")
            }

            return parts.joined(separator: " | ")
        }
    }

    nonisolated static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    nonisolated static func log(_ message: String) {
        guard isEnabled else { return }

        let line = "[Snip] \(message)"
        NSLog("%@", line)
    }

    nonisolated static func logMemory(_ message: String) {
        if let snapshot = processMemorySnapshot() {
            log("\(message) | 进程内存: \(snapshot.formattedSummary)")
        } else {
            log("\(message) | 进程内存: unavailable")
        }
    }

    private nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(bytes),
            countStyle: .memory
        )
    }

    private nonisolated static func processMemorySnapshot() -> MemorySnapshot? {
        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )

        let basicResult: kern_return_t = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &basicCount
                )
            }
        }

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let vmResult: kern_return_t = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &vmCount
                )
            }
        }

        let residentBytes: UInt64?
        if basicResult == KERN_SUCCESS {
            residentBytes = UInt64(basicInfo.resident_size)
        } else if vmResult == KERN_SUCCESS {
            residentBytes = UInt64(vmInfo.resident_size)
        } else {
            residentBytes = nil
        }

        guard let residentBytes else { return nil }

        let footprintBytes = vmResult == KERN_SUCCESS ? UInt64(vmInfo.phys_footprint) : nil
        let compressedBytes = vmResult == KERN_SUCCESS ? UInt64(vmInfo.compressed) : nil

        return MemorySnapshot(
            residentBytes: residentBytes,
            footprintBytes: footprintBytes,
            compressedBytes: compressedBytes
        )
    }
}

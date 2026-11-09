import Darwin
import Foundation
import OSLog

/// The spec's speed targets, timed where they happen. Instruments shows the intervals; launch goes to the log.
enum Speed {
    static let signposter = OSSignposter(subsystem: "pob", category: "Speed")

    /// When the kernel started this process. `NSRunningApplication.launchDate` is nil for an executable started directly.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

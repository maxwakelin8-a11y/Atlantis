import Darwin
import Foundation

/// CPU, memory and wake-up numbers for this process, for the performance HUD (PRD §17).
public struct ProcessStats: Sendable, Equatable {
    /// Total CPU time used so far, in seconds.
    public var cpuSeconds: Double
    /// Physical footprint in bytes (what Activity Monitor calls "Memory").
    public var footprintBytes: UInt64
    /// Total CPU wake-ups so far (interrupt + package idle).
    public var wakeups: UInt64
    public var takenAt: Date

    /// Reads the current numbers. Returns nil if the kernel call fails.
    public static func current() -> ProcessStats? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let nanos = ticks * Double(timebase.numer) / Double(timebase.denom)
        return ProcessStats(cpuSeconds: nanos / 1e9,
                            footprintBytes: info.ri_phys_footprint,
                            wakeups: info.ri_interrupt_wkups + info.ri_pkg_idle_wkups,
                            takenAt: Date())
    }

    /// CPU use between two readings, as a percentage of one core.
    public func cpuPercent(since earlier: ProcessStats) -> Double {
        let wall = takenAt.timeIntervalSince(earlier.takenAt)
        guard wall > 0 else { return 0 }
        return max(0, (cpuSeconds - earlier.cpuSeconds) / wall * 100)
    }

    /// Wake-ups per second between two readings.
    public func wakeupsPerSecond(since earlier: ProcessStats) -> Double {
        let wall = takenAt.timeIntervalSince(earlier.takenAt)
        guard wall > 0, wakeups >= earlier.wakeups else { return 0 }
        return Double(wakeups - earlier.wakeups) / wall
    }

    /// Seconds since this process started, from the kernel's process start time.
    public static func secondsSinceLaunch() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return Date().timeIntervalSince1970 - started
    }
}

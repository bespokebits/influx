// How long after Influx's own code started the timeline first showed rows:
// the launch bar is a cached timeline on screen under 300 ms from there.
// The start point was set on 2026-10-26: before it is the system's own
// app start (an empty SwiftUI app takes about 266 ms on the simulator to
// reach its first line), which Influx can only shrink by linking less.
import Darwin
import Foundation
import os

enum LaunchClock {
    /// Milliseconds since the kernel started this process, or nil if it
    /// can't say.
    static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }

    /// Milliseconds since Influx's first code ran (the "app" mark), or nil
    /// before then.
    static func millisecondsSinceAppStart() -> Double? {
        guard let now = millisecondsSinceProcessStart(),
              let app = marks.withLock({ $0.first(where: { $0.0 == "app" })?.1 }) else { return nil }
        return now - app
    }

    /// Times along the way to the first rows, so a slow launch says where
    /// the time went. Each name is kept the first time it's marked.
    private static let marks = OSAllocatedUnfairLock(initialState: [(String, Double)]())

    static func mark(_ name: String) {
        guard let ms = millisecondsSinceProcessStart() else { return }
        marks.withLock { marks in
            if !marks.contains(where: { $0.0 == name }) { marks.append((name, ms)) }
        }
    }

    /// Whether `name` has been marked.
    static func has(_ name: String) -> Bool {
        marks.withLock { $0.contains(where: { $0.0 == name }) }
    }

    /// "app 120 · store 135 · …", in the order they were marked.
    static var breakdown: String {
        marks.withLock { $0.map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " · ") }
    }
}

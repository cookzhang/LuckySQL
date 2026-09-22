import os

/// Inspect these intervals with Instruments' Points of Interest. Analysis is
/// background latency; editor/grid/color intervals are UI-thread work, not FPS.
enum PerformanceTrace {
    static let signposter = OSSignposter(subsystem: "com.cookzhang.LuckySQL", category: "Responsiveness")
}

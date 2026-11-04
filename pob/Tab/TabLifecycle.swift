import Foundation

enum TabPhase: Equatable { case active, background, suspended, saved }

enum TabLifecycle {
    static let idleLimit: TimeInterval = 600

    static func nextPhase(current: TabPhase, isActive: Bool, isCapturing: Bool, idleSeconds: TimeInterval, memoryPressure: Bool) -> TabPhase {
        if isActive { return .active }
        // A capturing tab must keep running.
        if isCapturing { return .background }
        switch current {
        case .active: return .background
        case .background: return idleSeconds >= idleLimit ? .suspended : .background
        case .suspended: return memoryPressure ? .saved : .suspended
        case .saved: return .saved
        }
    }
}

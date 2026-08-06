import Foundation

struct ImportScheduler {
    private(set) var active: Task<Void, Never>?
    private var wakeRequested = false

    mutating func requestWake() -> Bool {
        wakeRequested = true
        guard active == nil else { return false }
        wakeRequested = false
        return true
    }

    mutating func install(_ task: Task<Void, Never>) {
        precondition(active == nil)
        active = task
    }

    mutating func didBecomeIdle() -> Bool {
        active = nil
        guard wakeRequested else { return false }
        wakeRequested = false
        return true
    }
}

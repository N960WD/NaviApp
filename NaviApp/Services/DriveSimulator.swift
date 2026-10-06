import Foundation
import NaviCore

/// Feeds synthetic GPS fixes that drive along the route in real time, so timing logic and
/// the CarPlay screens can be exercised from the couch (or the Xcode simulator).
@MainActor
final class DriveSimulator {
    var speed: Double // m/s
    private(set) var distance: Double
    private let path: RoutePath
    private var timer: Timer?
    private var lastTick = Date()
    private let onFix: @MainActor (LocationFix) -> Void

    init(path: RoutePath, startDistance: Double, speed: Double, onFix: @escaping @MainActor (LocationFix) -> Void) {
        self.path = path
        self.distance = startDistance
        self.speed = speed
        self.onFix = onFix
    }

    func start() {
        lastTick = Date()
        emit(at: lastTick)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        // A little speed noise keeps "current" and "average" speed honest.
        let jitter = Double.random(in: -0.6...0.6)
        let v = max(speed + jitter, 0)
        distance = min(distance + v * now.timeIntervalSince(lastTick), path.length)
        lastTick = now
        emit(at: now, speed: v)
    }

    private func emit(at time: Date, speed: Double? = nil) {
        onFix(LocationFix(time: time, point: path.point(atDistance: distance), speed: speed ?? self.speed, horizontalAccuracy: 5))
    }
}

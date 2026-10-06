import Combine
import Foundation
import NaviCore
import UIKit

/// The single live tracking session, shared by the iPhone UI and the CarPlay scene.
@MainActor
final class NavSession: ObservableObject {
    static let shared = NavSession()

    @Published private(set) var route: SavedRoute?
    @Published private(set) var snapshot: NavSnapshot?
    @Published private(set) var isSimulating = false

    private var engine: TrackingEngine?
    private let location = LocationService()
    private var simulator: DriveSimulator?
    private var clock: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let settings = AppSettings.shared

    private init() {
        location.onFix = { [weak self] fix in
            guard let self, !self.isSimulating else { return }
            self.ingest(fix)
        }
        settings.$etaBasis
            .sink { [weak self] basis in
                self?.engine?.etaBasis = basis
                self?.refresh()
            }
            .store(in: &cancellables)
        settings.$keepScreenOn
            .sink { [weak self] _ in self?.updateIdleTimer() }
            .store(in: &cancellables)
    }

    var isLoaded: Bool { route != nil }
    var isRunning: Bool { engine?.isRunning ?? false }
    var isFinished: Bool { engine?.finishTime != nil }

    // MARK: Lifecycle

    /// Loads a route and begins receiving GPS (tracking does not start until `start()`).
    func load(_ route: SavedRoute) {
        if self.route?.id == route.id { return }
        stopSimulation()
        var engine = TrackingEngine(route: route)
        engine.etaBasis = settings.etaBasis
        self.engine = engine
        self.route = route
        location.start()
        startClock()
        refresh()
    }

    func unload() {
        stopSimulation()
        location.stop()
        clock?.invalidate()
        clock = nil
        engine = nil
        route = nil
        snapshot = nil
        updateIdleTimer()
    }

    func start() {
        guard engine != nil else { return }
        engine?.start(at: Date())
        refresh()
        updateIdleTimer()
    }

    func stop() {
        engine?.stop(at: Date())
        stopSimulation()
        refresh()
        updateIdleTimer()
    }

    func resetTrip() {
        engine?.reset()
        refresh()
        updateIdleTimer()
    }

    // MARK: Route edits

    func setRequiredTime(_ date: Date?, for waypointID: UUID) {
        updateWaypoint(waypointID) { $0.requiredTime = date }
    }

    func updateWaypoint(_ id: UUID, _ change: (inout Waypoint) -> Void) {
        guard var route, let i = route.waypoints.firstIndex(where: { $0.id == id }) else { return }
        change(&route.waypoints[i])
        apply(route)
    }

    /// Pushes an edited route into the live session (if it is the loaded one) and saves it.
    func apply(_ edited: SavedRoute) {
        RouteStore.shared.save(edited)
        guard route?.id == edited.id else { return }
        route = edited
        engine?.update(route: edited)
        refresh()
    }

    // MARK: Simulation

    func startSimulation() {
        guard let engine else { return }
        stopSimulation()
        let sim = DriveSimulator(
            path: engine.path,
            startDistance: engine.distanceAlong,
            speed: settings.simulatorSpeed
        ) { [weak self] fix in
            self?.ingest(fix)
        }
        simulator = sim
        isSimulating = true
        sim.start()
    }

    func stopSimulation() {
        simulator?.stop()
        simulator = nil
        isSimulating = false
    }

    func setSimulatorSpeed(_ mps: Double) {
        settings.simulatorSpeed = mps
        simulator?.speed = mps
    }

    // MARK: Internals

    private func ingest(_ fix: LocationFix) {
        guard engine != nil else { return }
        let wasRunning = isRunning
        engine?.ingest(fix)
        if wasRunning && !isRunning {
            stopSimulation() // arrived
            updateIdleTimer()
        }
        refresh()
    }

    private func startClock() {
        clock?.invalidate()
        // Ticks the clock and ETAs even when no fixes arrive (e.g. stopped at a light).
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        snapshot = engine?.snapshot(at: Date())
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn && isRunning
    }
}

import CoreLocation
import NaviCore

/// Thin CLLocationManager wrapper configured for continuous, background-capable
/// automotive tracking.
final class LocationService: NSObject, CLLocationManagerDelegate {
    var onFix: (@MainActor (LocationFix) -> Void)?
    var onAuthorizationChange: (@MainActor (CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private(set) var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        // Keeps updates flowing while the phone is locked or CarPlay is in front.
        backgroundSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap(LocationFix.init)
        Task { @MainActor in
            for fix in fixes { self.onFix?(fix) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationService error: \(error)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.onAuthorizationChange?(status) }
    }
}

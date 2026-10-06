import CoreLocation
import MapKit
import NaviCore

extension GeoPoint {
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

extension LocationFix {
    init?(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else { return nil }
        self.init(
            time: location.timestamp,
            point: GeoPoint(location.coordinate),
            speed: location.speed >= 0 ? location.speed : nil,
            horizontalAccuracy: location.horizontalAccuracy
        )
    }
}

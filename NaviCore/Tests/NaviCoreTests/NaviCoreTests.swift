import XCTest
@testable import NaviCore

/// A straight east-west test route along 40°N from 100°W to 99°W (~85.4 km).
private func straightRoute() -> RoutePath {
    RoutePath(points: stride(from: -100.0, through: -99.0, by: 0.01).map { GeoPoint(lat: 40, lon: $0) })
}

final class GeoTests: XCTestCase {
    func testDistanceOneDegreeLatitude() {
        let d = Geo.distance(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 1, lon: 0))
        XCTAssertEqual(d, 111_195, accuracy: 50)
    }

    func testBearingAndCrossingAngle() {
        XCTAssertEqual(Geo.bearing(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 1)), 90, accuracy: 0.01)
        XCTAssertEqual(Geo.crossingAngle(10, 190), 0, accuracy: 1e-9)
        XCTAssertEqual(Geo.crossingAngle(0, 100), 80, accuracy: 1e-9)
    }

    func testProjection() throws {
        let route = straightRoute()
        let mid = try XCTUnwrap(route.project(GeoPoint(lat: 40.001, lon: -99.5)))
        XCTAssertEqual(mid.distanceAlong, route.length / 2, accuracy: 5)
        XCTAssertEqual(mid.crossTrack, 111, accuracy: 2)
        let p = route.point(atDistance: route.length / 2)
        XCTAssertEqual(p.lon, -99.5, accuracy: 1e-6)
    }

    func testSimplifyStraightLine() {
        XCTAssertEqual(straightRoute().simplified(tolerance: 10).count, 2)
    }

    func testChunksCoverRoute() {
        let route = straightRoute()
        let chunks = route.chunks(maxLength: 20_000)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.length).reduce(0, +), route.length, accuracy: 1)
    }
}

final class CrossingTests: XCTestCase {
    func testPerpendicularCrossingFoundOnce() {
        let route = straightRoute()
        // A divided highway: two parallel one-way ways 20 m apart.
        let nb = RoadGeometry(id: 1, name: nil, ref: "I 35", highway: .motorway,
                              points: [GeoPoint(lat: 39.9, lon: -99.5), GeoPoint(lat: 40.1, lon: -99.5)])
        var sb = nb
        sb.id = 2
        sb.points = [GeoPoint(lat: 40.1, lon: -99.4998), GeoPoint(lat: 39.9, lon: -99.4998)]
        let parallel = RoadGeometry(id: 3, name: "Frontage Rd", ref: nil, highway: .primary,
                                    points: [GeoPoint(lat: 40.0001, lon: -99.9), GeoPoint(lat: 40.0001, lon: -99.1)])
        let crossings = CrossingFinder.crossings(route: route, roads: [nb, sb, parallel])
        XCTAssertEqual(crossings.count, 1)
        XCTAssertEqual(crossings[0].road.label, "I-35")
        XCTAssertEqual(crossings[0].distanceAlong, route.length / 2, accuracy: 30)
        XCTAssertEqual(crossings[0].angle, 90, accuracy: 0.5)
    }

    func testShallowCrossingRejected() {
        let route = straightRoute()
        let shallow = RoadGeometry(id: 1, name: nil, ref: "US 6", highway: .primary,
                                   points: [GeoPoint(lat: 39.999, lon: -99.6), GeoPoint(lat: 40.001, lon: -99.4)])
        XCTAssertTrue(CrossingFinder.crossings(route: route, roads: [shallow]).isEmpty)
    }
}

final class WaypointBuilderTests: XCTestCase {
    func testHighwayRefParsing() {
        XCTAssertEqual(WaypointBuilder.highwayRef(in: "Take exit 52B onto I-80 E toward Sacramento"), "I-80 E")
        XCTAssertEqual(WaypointBuilder.highwayRef(in: "Turn right onto CA-99"), "CA-99")
        XCTAssertEqual(WaypointBuilder.highwayRef(in: "Merge onto US-101 N"), "US-101 N")
        XCTAssertNil(WaypointBuilder.highwayRef(in: "Turn left onto Main St"))
    }

    func testBuildsCrossingsTownsAndDestination() {
        let route = straightRoute()
        let i35 = RoadGeometry(id: 1, name: nil, ref: "I 35", highway: .motorway,
                               points: [GeoPoint(lat: 39.9, lon: -99.7), GeoPoint(lat: 40.1, lon: -99.7)])
        let mainSt = RoadGeometry(id: 2, name: "Main Street", ref: nil, highway: .residential,
                                  points: [GeoPoint(lat: 39.99, lon: -99.3002), GeoPoint(lat: 40.01, lon: -99.3002)])
        let town = Place(id: 10, name: "Springfield", type: .town, location: GeoPoint(lat: 40.002, lon: -99.3))
        let farTown = Place(id: 11, name: "Shelbyville", type: .town, location: GeoPoint(lat: 40.03, lon: -99.15))

        let wps = WaypointBuilder().build(
            route: route, maneuvers: [], majorRoads: [i35], places: [town, farTown],
            townStreets: [mainSt], destinationName: "Capital City"
        )
        XCTAssertEqual(wps.map(\.name), ["I-35", "Springfield", "Abeam Shelbyville", "Capital City"])
        XCTAssertEqual(wps[1].kind, .townCenter)
        XCTAssertTrue(wps[1].detail?.contains("Main Street") ?? false)
        XCTAssertEqual(wps.last?.kind, .destination)
        XCTAssertEqual(wps.last!.distanceAlong, route.length, accuracy: 0.001)
    }

    func testMergeKeepsHigherPriority() {
        let a = Waypoint(name: "Abeam X", kind: .abeamTown, coordinate: GeoPoint(lat: 0, lon: 0), distanceAlong: 1000)
        let b = Waypoint(name: "I-5", kind: .highwayCrossing, coordinate: GeoPoint(lat: 0, lon: 0), distanceAlong: 1100)
        let merged = WaypointBuilder.merge([a, b], within: 400)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "I-5")
        XCTAssertEqual(merged[0].detail, "Abeam X")
    }
}

final class TrackingEngineTests: XCTestCase {
    private func makeRoute(required: Date? = nil) -> SavedRoute {
        let path = straightRoute()
        let mid = Waypoint(name: "Midpoint", kind: .custom, coordinate: path.point(atDistance: path.length / 2),
                           distanceAlong: path.length / 2, requiredTime: required)
        let dest = Waypoint(name: "End", kind: .destination, coordinate: path.end!, distanceAlong: path.length)
        return SavedRoute(name: "Test", originName: "A", destinationName: "B", points: path.points,
                          expectedTravelTime: path.length / 25, waypoints: [mid, dest])
    }

    /// Drives the route at a constant speed, one fix per `step` seconds.
    private func drive(_ engine: inout TrackingEngine, from t0: Date, speed: Double, seconds: Int, step: Int = 10) {
        let path = engine.path
        for s in stride(from: 0, through: seconds, by: step) {
            let d = min(Double(s) * speed, path.length)
            engine.ingest(LocationFix(time: t0.addingTimeInterval(Double(s)), point: path.point(atDistance: d), speed: speed))
        }
    }

    func testPlannedSpeedFromExpectedTravelTime() {
        XCTAssertEqual(makeRoute().plannedSpeed, 25, accuracy: 1e-6)
    }

    func testPassageTimesAndAverageSpeed() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var engine = TrackingEngine(route: makeRoute())
        engine.ingest(LocationFix(time: t0, point: engine.path.start!, speed: 0))
        engine.start(at: t0)
        drive(&engine, from: t0, speed: 30, seconds: 2_000)

        let snap = engine.snapshot(at: t0.addingTimeInterval(2_000))
        let mid = snap.waypoints[0]
        XCTAssertTrue(mid.isPassed)
        let expected = t0.addingTimeInterval(engine.path.length / 2 / 30)
        XCTAssertEqual(try XCTUnwrap(mid.actualTime).timeIntervalSince(expected), 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(snap.averageSpeed), 30, accuracy: 0.1)
        XCTAssertEqual(snap.currentSpeed, 30)
        XCTAssertEqual(snap.nextIndex, 1)
        XCTAssertEqual(snap.next?.waypoint.name, "End")
        // ETA to the end at the 30 m/s average.
        let remaining = engine.path.length - 60_000
        XCTAssertEqual(try XCTUnwrap(snap.next?.timeToGo), remaining / 30, accuracy: 1)
    }

    func testArrivalFinishesTrip() {
        let t0 = Date(timeIntervalSince1970: 0)
        var engine = TrackingEngine(route: makeRoute())
        engine.start(at: t0)
        drive(&engine, from: t0, speed: 40, seconds: 2_200)
        XCTAssertNotNil(engine.finishTime)
        let snap = engine.snapshot(at: t0.addingTimeInterval(5_000))
        XCTAssertFalse(snap.isRunning)
        XCTAssertTrue(snap.waypoints.allSatisfy(\.isPassed))
        XCTAssertNil(snap.nextIndex)
    }

    func testRequiredSpeed() throws {
        let t0 = Date(timeIntervalSince1970: 0)
        let half = straightRoute().length / 2
        // Must cross the midpoint 1,000 s after start.
        var engine = TrackingEngine(route: makeRoute(required: t0.addingTimeInterval(1_000)))
        engine.ingest(LocationFix(time: t0, point: engine.path.start!, speed: 0))
        engine.start(at: t0)

        var snap = engine.snapshot(at: t0)
        XCTAssertEqual(try XCTUnwrap(snap.targetSpeed), half / 1_000, accuracy: 0.01)
        XCTAssertEqual(snap.targetWaypointID, snap.waypoints[0].id)
        // Planned 25 m/s → ETA 1,708 s, i.e. ~708 s late.
        XCTAssertEqual(try XCTUnwrap(snap.waypoints[0].delta), half / 25 - 1_000, accuracy: 1)

        // After 500 s at 40 m/s: 20 km done, 22.7 km to go in 500 s.
        drive(&engine, from: t0, speed: 40, seconds: 500)
        snap = engine.snapshot(at: t0.addingTimeInterval(500))
        XCTAssertEqual(try XCTUnwrap(snap.targetSpeed), (half - 20_000) / 500, accuracy: 0.05)

        // Past the required time without arriving: unable.
        snap = engine.snapshot(at: t0.addingTimeInterval(1_100))
        XCTAssertTrue(snap.waypoints[0].isUnable)
        XCTAssertNil(snap.targetSpeed)
    }

    func testLegSpeedsChainConstraints() throws {
        let t0 = Date(timeIntervalSince1970: 0)
        var route = makeRoute(required: t0.addingTimeInterval(1_000))
        route.waypoints[1].requiredTime = t0.addingTimeInterval(3_000)
        let engine = TrackingEngine(route: route)
        let snap = engine.snapshot(at: t0)
        let half = engine.path.length / 2
        XCTAssertEqual(try XCTUnwrap(snap.waypoints[0].legSpeed), half / 1_000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(snap.waypoints[1].legSpeed), half / 2_000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(snap.waypoints[1].requiredSpeed), half * 2 / 3_000, accuracy: 0.01)
    }

    func testFormat() {
        XCTAssertEqual(Format.duration(3_725), "1:02:05")
        XCTAssertEqual(Format.duration(65), "1:05")
        XCTAssertEqual(Format.delta(-40), "-0:40")
        XCTAssertEqual(Format.speed(26.8224, .imperial), "60")
        XCTAssertEqual(Format.distance(1_609.344, .imperial), "1.0 mi")
        XCTAssertEqual(Format.clock(Date(timeIntervalSince1970: 3_661), timeZone: TimeZone(identifier: "UTC")!), "01:01:01")
    }
}

final class OverpassTests: XCTestCase {
    func testParse() throws {
        let json = """
        {"elements":[
          {"type":"way","id":5,"tags":{"highway":"motorway","ref":"I 80"},
           "geometry":[{"lat":40.0,"lon":-100.0},{"lat":40.1,"lon":-100.0}]},
          {"type":"way","id":6,"tags":{"highway":"service"},
           "geometry":[{"lat":40.0,"lon":-100.0},{"lat":40.1,"lon":-100.0}]},
          {"type":"node","id":7,"lat":40.05,"lon":-100.01,"tags":{"place":"town","name":"Ogallala"}}
        ]}
        """
        let result = try Overpass.parse(Data(json.utf8))
        XCTAssertEqual(result.roads.count, 1)
        XCTAssertEqual(result.roads[0].label, "I-80")
        XCTAssertEqual(result.places.first?.name, "Ogallala")
    }

    func testQueryContainsPolyline() {
        let q = Overpass.corridorQuery(line: [GeoPoint(lat: 40, lon: -100), GeoPoint(lat: 41, lon: -101)])
        XCTAssertTrue(q.contains("around:150,40.00000,-100.00000,41.00000,-101.00000"))
    }
}

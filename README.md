# Route Timer (NaviApp)

An iPhone and CarPlay app for timing a drive along a known route, in the style of an aviation nav log.
You plan a route and the app builds a list of checkpoints along it: interstate, US and state highway junctions and crossings, plus the crossing street nearest each town center. Press **START** and it tracks your progress, speeds and the ETA at every checkpoint. It also shows the speed needed to cross any checkpoint at a time you set.

> Built for research and experimentation. Speed advisories are pure arithmetic and ignore speed limits and road conditions.

## Features

| | |
|---|---|
| **Route planning** | Search an origin (or use the current location) and a destination. Apple Maps returns route alternatives, and you pick one. |
| **Auto-generated waypoints** | • *Highway junctions*: Apple Maps maneuvers onto numbered highways (`I-80 E`, `US-50`, `CA-99`, …)<br>• *Highway crossings*: OpenStreetMap motorway, trunk, primary and numbered secondary roads that cross the route at more than 25°. Divided highways are merged into one crossing.<br>• *Town centers*: for each city or town the route passes through, the crossing street closest to the center, or the closest point if no street crosses there<br>• *Abeam points*: the closest approach to towns within about 4 km of the route that it doesn't pass through<br>• *Destination* |
| **Editing** | Hide or delete waypoints, rename them, tap the map to add custom waypoints, and override the planned cruise speed. |
| **Live data** | Current time, current speed, average speed, max speed, elapsed time, distance and time to the next waypoint, ETA at every waypoint, destination ETA and distance remaining |
| **Required times** | Set a required crossing time (to the second) on any waypoint. The app shows the **required speed** from your current position, the **leg speed** from the previous timed waypoint, an early/late **Δ**, and **UNABLE** once the time can't be met. The dashboard's **Target Speed** tile tells you to speed up or slow down to hit the next timed waypoint exactly. |
| **Actual crossing times** | When you pass a waypoint, the app logs its actual time of arrival (ATA). The time is interpolated between GPS fixes and compared against the required time. |
| **ETA basis** | ETAs can use one of three speeds: *Average* (default; speed made good since START), *Current* (GPS speed) or *Planned* (cruise speed) |
| **CarPlay** | Three tabs: a dashboard with Start/Stop, the live nav log, and saved routes (tap one to load it) |
| **Simulator** | Simulated drive: generates fake GPS fixes along the route at an adjustable speed. Useful for testing timing and CarPlay without driving. |
| **Background** | Location tracking keeps running while the phone is locked or CarPlay is in front. The screen can stay on while tracking. |

## Project layout

```
NaviCore/            Swift package with the platform-independent logic (unit tested)
  Geo.swift            haversine, bearings, segment intersection
  RoutePath.swift      along-track projection, Douglas–Peucker simplification, chunking
  Roads.swift          OSM road/place models, CrossingFinder (grid-indexed)
  Overpass.swift       Overpass API query builder and JSON parser
  WaypointBuilder.swift nav-log generation and merging, highway-ref parsing
  TrackingEngine.swift GPS ingestion, speeds, ETAs, required and leg speeds, ATAs
  Units.swift          mph/km/h formatting, H:MM:SS, Δ
NaviApp/             SwiftUI iOS app
  Services/            NavSession (shared live session), LocationService, RoutePlanner,
                       OverpassClient, RouteStore (JSON persistence), DriveSimulator
  Views/               route list, new route, route editor, dashboard, waypoint editor, settings
  CarPlay/             CPTemplateApplicationScene delegate and template controller
project.yml          XcodeGen spec (Info.plist keys, entitlements, CarPlay scene)
```

## Building

Requirements: macOS with Xcode 15 or later, and iOS 17 or later on the device.

```sh
brew install xcodegen
xcodegen generate          # creates NaviApp.xcodeproj and Info.plist
open NaviApp.xcodeproj
```

1. In **Signing & Capabilities**, pick your team. Change the bundle ID in `project.yml` (`com.example.naviapp`) if needed.
2. Run it on your iPhone. When asked for location access, choose **While Using the App**. Background tracking works because tracking starts in the foreground.

Run the core unit tests:

```sh
cd NaviCore && swift test
```

## CarPlay

The app declares the **CarPlay Driving Task** entitlement (`com.apple.developer.carplay-driving-task`), and uses only templates allowed for that category: information, list, tab bar and alert.

- **Simulator:** run on an iOS Simulator, then choose **I/O ▸ External Displays ▸ CarPlay**. No approval is needed.
- **Real car or head unit:** Apple must grant the entitlement to your developer account. Request it at <https://developer.apple.com/contact/carplay/>. Until it's granted, a device build signed with this entitlement won't provision. To install on your phone without CarPlay, remove the entitlement line from `project.yml` and regenerate.

## How the timing works

- **Position along the route:** each GPS fix is projected onto the route polyline. The search is limited to a window around the previous position, so progress stays steady on routes that double back.
- **Average speed** = distance made good along the route since START ÷ elapsed time
- **ETE** to a waypoint = distance to go ÷ the ETA-basis speed. **ETA** = now + ETE.
- **Required speed** = distance to go ÷ (required time − now)
- **Leg speed** = distance between consecutive timed waypoints ÷ the time between their required times. This assumes each earlier required time is met exactly.
- **Δ** = ETA − required time before crossing, and ATA − required time after. Positive means late.

## Data sources

- Routing and maneuvers: Apple MapKit
- Highway and town data: © OpenStreetMap contributors (ODbL), via the public Overpass API (`overpass-api.de`, with `overpass.kumi.systems` as a fallback). The app asks for data in roughly 150 km chunks when you build a route. Saved routes keep their geometry and waypoints, so tracking works offline.

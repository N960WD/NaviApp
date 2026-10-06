import CarPlay
import Combine
import NaviCore
import UIKit

/// Builds and live-updates the CarPlay UI: a dashboard (information template), the nav
/// log (list) and the saved routes (list), in a tab bar. Uses only templates available to
/// the CarPlay "driving task" app category.
@MainActor
final class CarPlayController {
    private let interfaceController: CPInterfaceController
    private let session = NavSession.shared
    private let store = RouteStore.shared
    private let settings = AppSettings.shared

    private let dashboard: CPInformationTemplate
    private let navLog: CPListTemplate
    private let routes: CPListTemplate
    private let tabs: CPTabBarTemplate

    private var cancellables: Set<AnyCancellable> = []
    private var lastDashboardSignature = ""
    private var lastLogSignature = ""
    private var lastLogUpdate = Date.distantPast

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        dashboard = CPInformationTemplate(title: "Route Timer", layout: .twoColumn, items: [], actions: [])
        dashboard.tabTitle = "Dash"
        dashboard.tabImage = UIImage(systemName: "speedometer")

        navLog = CPListTemplate(title: "Nav Log", sections: [])
        navLog.tabTitle = "Nav Log"
        navLog.tabImage = UIImage(systemName: "list.bullet.rectangle")
        navLog.emptyViewTitleVariants = ["No route loaded"]
        navLog.emptyViewSubtitleVariants = ["Choose a route in the Routes tab."]

        routes = CPListTemplate(title: "Routes", sections: [])
        routes.tabTitle = "Routes"
        routes.tabImage = UIImage(systemName: "map")
        routes.emptyViewTitleVariants = ["No saved routes"]
        routes.emptyViewSubtitleVariants = ["Plan a route on your iPhone."]

        tabs = CPTabBarTemplate(templates: [dashboard, navLog, routes])
    }

    func connect() {
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)

        session.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        session.$isSimulating
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(force: true) }
            .store(in: &cancellables)
        store.$routes
            .receive(on: RunLoop.main)
            .sink { [weak self] routes in self?.updateRoutes(routes) }
            .store(in: &cancellables)
        settings.$units
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(force: true) }
            .store(in: &cancellables)

        refresh(force: true)
    }

    func disconnect() {
        cancellables.removeAll()
    }

    // MARK: Updates

    private func refresh(force: Bool = false) {
        updateDashboard(force: force)
        // The nav log changes slowly; avoid hammering the list template.
        if force || Date().timeIntervalSince(lastLogUpdate) >= 3 {
            updateNavLog()
            lastLogUpdate = Date()
        }
    }

    private func updateDashboard(force: Bool) {
        let items = dashboardItems()
        let actions = dashboardActions()
        let signature = items.map { "\($0.title ?? "")=\($0.detail ?? "")" }.joined(separator: "|")
            + actions.map(\.title).joined()
        guard force || signature != lastDashboardSignature else { return }
        lastDashboardSignature = signature
        dashboard.title = session.route?.name ?? "Route Timer"
        dashboard.items = items
        dashboard.actions = actions
    }

    private func dashboardItems() -> [CPInformationItem] {
        guard let s = session.snapshot else {
            return [
                CPInformationItem(title: "Time", detail: Format.clock(Date())),
                CPInformationItem(title: "No route loaded", detail: "Pick one in the Routes tab"),
            ]
        }
        let u = settings.units
        var items: [CPInformationItem] = [
            CPInformationItem(title: "Time", detail: Format.clock(s.now)),
            CPInformationItem(title: "Elapsed", detail: s.startTime == nil ? "Not started" : Format.duration(s.elapsed)),
            CPInformationItem(title: "Speed", detail: Format.speed(s.currentSpeed, u, unit: true)),
            CPInformationItem(title: "Avg Speed", detail: Format.speed(s.averageSpeed, u, unit: true)),
        ]

        if let target = s.target {
            let value = target.isUnable || s.targetSpeed == nil
                ? "UNABLE"
                : "\(Format.speed(s.targetSpeed, u, unit: true)) → \(target.waypoint.name)"
            items.append(CPInformationItem(title: "Target Speed", detail: value))
        }

        if let next = s.next {
            items.append(CPInformationItem(title: "Next", detail: next.waypoint.name))
            items.append(CPInformationItem(
                title: "To Next",
                detail: "\(Format.distance(next.distanceToGo, u)) · \(Format.duration(next.timeToGo))"
            ))
            var eta = Format.clock(next.eta)
            if next.waypoint.requiredTime != nil { eta += "  Δ\(Format.delta(next.delta))" }
            items.append(CPInformationItem(title: "ETA Next", detail: eta))
        } else if s.finishTime != nil {
            items.append(CPInformationItem(title: "Status", detail: "Arrived \(Format.clock(s.finishTime))"))
        }

        items.append(CPInformationItem(title: "Dest ETA", detail: Format.clock(s.destinationETA)))
        items.append(CPInformationItem(title: "Remaining", detail: Format.distance(s.distanceRemaining, u)))
        if s.isOffRoute {
            items.insert(CPInformationItem(title: "⚠︎ Off route", detail: Format.distance(s.crossTrack, u)), at: 0)
        }
        return items
    }

    private func dashboardActions() -> [CPTextButton] {
        guard session.isLoaded else { return [] }
        var actions: [CPTextButton] = []
        if session.isRunning {
            actions.append(CPTextButton(title: "Stop", textStyle: .cancel) { [weak self] _ in
                self?.confirmStop()
            })
        } else if session.isFinished {
            actions.append(CPTextButton(title: "Reset", textStyle: .normal) { [weak self] _ in
                self?.session.resetTrip()
            })
        } else {
            actions.append(CPTextButton(title: "Start", textStyle: .confirm) { [weak self] _ in
                self?.session.start()
            })
        }
        actions.append(CPTextButton(title: session.isSimulating ? "End Sim" : "Simulate", textStyle: .normal) { [weak self] _ in
            guard let self else { return }
            if self.session.isSimulating { self.session.stopSimulation() } else { self.session.startSimulation() }
        })
        return actions
    }

    private func confirmStop() {
        let alert = CPAlertTemplate(
            titleVariants: ["Stop tracking?"],
            actions: [
                CPAlertAction(title: "Stop", style: .destructive) { [weak self] _ in
                    self?.session.stop()
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                },
                CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                },
            ]
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func updateNavLog() {
        guard let s = session.snapshot else {
            if !lastLogSignature.isEmpty { navLog.updateSections([]) }
            lastLogSignature = ""
            return
        }
        let u = settings.units
        let limit = CPListTemplate.maximumItemCount
        // Show from the last passed waypoint onward so the next one is near the top.
        let first = max((s.nextIndex ?? s.waypoints.count) - 1, 0)
        let visible = s.waypoints[first...].prefix(limit)

        var rows: [(text: String, detail: String, symbol: String)] = []
        for (offset, st) in visible.enumerated() {
            let wp = st.waypoint
            let isNext = first + offset == s.nextIndex
            var parts: [String] = []
            if st.isPassed {
                parts.append(st.actualTime.map { "ATA \(Format.clock($0))" } ?? "Passed")
            } else {
                parts.append("ETA \(Format.clock(st.eta))")
                parts.append(Format.distance(st.distanceToGo, u))
            }
            if let req = wp.requiredTime {
                parts.append("REQ \(Format.clock(req, seconds: false))")
                if !st.isPassed {
                    parts.append(st.isUnable ? "UNABLE" : Format.speed(st.requiredSpeed, u, unit: true))
                }
                parts.append("Δ\(Format.delta(st.delta))")
            }
            rows.append((
                text: (isNext ? "▶ " : "") + wp.name,
                detail: parts.joined(separator: " · "),
                symbol: st.isPassed ? "checkmark.circle" : wp.kind.symbolName
            ))
        }

        let signature = rows.map { "\($0.text)\($0.detail)" }.joined(separator: "|")
        guard signature != lastLogSignature else { return }
        lastLogSignature = signature
        let items = rows.map { row -> CPListItem in
            let item = CPListItem(text: row.text, detailText: row.detail, image: UIImage(systemName: row.symbol))
            item.handler = { _, completion in completion() }
            return item
        }
        navLog.updateSections([CPListSection(items: items)])
    }

    private func updateRoutes(_ saved: [SavedRoute]) {
        let items = saved.prefix(CPListTemplate.maximumItemCount).map { route -> CPListItem in
            let item = CPListItem(
                text: route.name,
                detailText: "\(route.activeWaypoints.count) waypoints · \(Format.duration(route.expectedTravelTime))",
                image: UIImage(systemName: session.route?.id == route.id ? "checkmark.circle.fill" : "map")
            )
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                self.session.load(route)
                self.updateRoutes(self.store.routes)
                self.refresh(force: true)
                self.tabs.select(self.dashboard)
                completion()
            }
            return item
        }
        routes.updateSections([CPListSection(items: items)])
    }
}

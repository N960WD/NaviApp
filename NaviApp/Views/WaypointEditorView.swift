import NaviCore
import SwiftUI

/// Edit a waypoint's name and its required crossing time, with a live preview of the
/// speed needed to make that time.
struct WaypointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @State private var waypoint: Waypoint
    @State private var hasRequiredTime: Bool
    @State private var requiredMinute: Date
    @State private var seconds: Int

    /// Distance from the vehicle (or route start, before tracking) to the waypoint.
    let distanceToGo: Double
    let eta: Date?
    let onSave: (Waypoint) -> Void
    var onDelete: (() -> Void)?

    init(waypoint: Waypoint, distanceToGo: Double, eta: Date?,
         onSave: @escaping (Waypoint) -> Void, onDelete: (() -> Void)? = nil) {
        _waypoint = State(initialValue: waypoint)
        _hasRequiredTime = State(initialValue: waypoint.requiredTime != nil)
        // Default to the ETA rounded up to the next minute.
        let base = waypoint.requiredTime ?? eta.map {
            Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
        } ?? Date().addingTimeInterval(3_600)
        let secs = Calendar.current.component(.second, from: base)
        _requiredMinute = State(initialValue: base.addingTimeInterval(-Double(secs)))
        _seconds = State(initialValue: secs)
        self.distanceToGo = distanceToGo
        self.eta = eta
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var requiredTime: Date {
        let t = requiredMinute.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.down) * 60 + Double(seconds))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Waypoint") {
                    TextField("Name", text: $waypoint.name)
                    if let detail = waypoint.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Kind", value: waypoint.kind.label)
                    LabeledContent("Route mile", value: Format.distance(waypoint.distanceAlong, settings.units))
                    LabeledContent("Distance to go", value: Format.distance(max(distanceToGo, 0), settings.units))
                    if let eta { LabeledContent("Current ETA", value: Format.clock(eta)) }
                    Toggle("Include in nav log", isOn: $waypoint.isEnabled)
                }

                Section {
                    Toggle("Required crossing time", isOn: $hasRequiredTime.animation())
                    if hasRequiredTime {
                        DatePicker("Time", selection: $requiredMinute, displayedComponents: [.date, .hourAndMinute])
                        Stepper("Seconds: \(String(format: "%02d", seconds))", value: $seconds, in: 0...55, step: 5)
                        preview
                    }
                } footer: {
                    Text("The dashboard's target speed is the speed needed to cross the next timed waypoint exactly at its required time.")
                }

                if let onDelete {
                    Section {
                        Button("Delete Waypoint", role: .destructive) { onDelete(); dismiss() }
                    }
                }
            }
            .navigationTitle(waypoint.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        waypoint.requiredTime = hasRequiredTime ? requiredTime : nil
                        onSave(waypoint)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let available = requiredTime.timeIntervalSince(context.date)
            VStack(alignment: .leading, spacing: 4) {
                if available <= 0 {
                    Text("Required time is in the past").foregroundStyle(.red)
                } else {
                    LabeledContent("Time available", value: Format.duration(available))
                    LabeledContent("Required speed") {
                        Text(Format.speed(max(distanceToGo, 0) / available, settings.units, unit: true))
                            .font(.title3.monospacedDigit().bold())
                            .foregroundStyle(Color.accentColor)
                    }
                    if let eta {
                        LabeledContent("At current ETA you'd be", value: describe(eta.timeIntervalSince(requiredTime)))
                    }
                }
            }
        }
    }

    private func describe(_ delta: TimeInterval) -> String {
        if abs(delta) < 1 { return "on time" }
        return "\(Format.duration(abs(delta))) \(delta > 0 ? "late" : "early")"
    }
}

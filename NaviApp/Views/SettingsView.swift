import NaviCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Units", selection: $settings.units) {
                        Text("mph / miles").tag(UnitSystem.imperial)
                        Text("km/h / km").tag(UnitSystem.metric)
                    }
                    Toggle("Keep screen on while tracking", isOn: $settings.keepScreenOn)
                }

                Section {
                    Picker("ETA based on", selection: $settings.etaBasis) {
                        ForEach(ETABasis.allCases) { Text("\($0.label) speed").tag($0) }
                    }
                } header: {
                    Text("Timing")
                } footer: {
                    Text("Average: speed made good along the route since START (uses planned speed for the first minute). Current: instantaneous GPS speed. Planned: the route's planned cruise speed.")
                }

                Section {
                    Toggle("Include villages", isOn: $settings.includeVillages)
                    Toggle("Abeam points for nearby towns", isOn: $settings.includeAbeamTowns)
                } header: {
                    Text("Waypoint generation")
                } footer: {
                    Text("Applies to newly planned routes. Highway and town data © OpenStreetMap contributors (ODbL), via the Overpass API.")
                }

                Section("Simulator") {
                    Stepper(value: Binding(
                        get: { settings.units.speed(settings.simulatorSpeed).rounded() },
                        set: { settings.simulatorSpeed = settings.units.metersPerSecond($0) }
                    ), in: 0...200, step: 5) {
                        LabeledContent("Simulated speed", value: Format.speed(settings.simulatorSpeed, settings.units, unit: true))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

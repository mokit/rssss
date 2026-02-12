import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: RefreshSettingsStore

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Refresh feeds every")
                    Stepper(
                        "",
                        value: $settingsStore.refreshIntervalMinutes,
                        in: RefreshSettings.minimumRefreshIntervalMinutes...RefreshSettings.maximumRefreshIntervalMinutes
                    )
                    .labelsHidden()
                    Text("\(settingsStore.refreshIntervalMinutes) min")
                        .monospacedDigit()
                }
            }
            Section("Display") {
                Toggle("Show last refresh time per feed", isOn: $settingsStore.showLastRefresh)
                Toggle("Monitor app performance (CPU and memory)", isOn: $settingsStore.monitorPerformance)
            }
            Section("Performance") {
                HStack {
                    Text("Initial items per feed")
                    Stepper(
                        "",
                        value: $settingsStore.initialFeedItemsLimit,
                        in: RefreshSettings.minimumInitialFeedItemsLimit...RefreshSettings.maximumInitialFeedItemsLimit,
                        step: 50
                    )
                    .labelsHidden()
                    Text("\(settingsStore.initialFeedItemsLimit)")
                        .monospacedDigit()
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

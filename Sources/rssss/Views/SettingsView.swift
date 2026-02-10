import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: RefreshSettingsStore

    var body: some View {
        Form {
            Section("Feed Refresh") {
                Stepper(value: $settingsStore.refreshIntervalMinutes, in: RefreshSettings.minimumRefreshIntervalMinutes...RefreshSettings.maximumRefreshIntervalMinutes) {
                    HStack {
                        Text("Refresh every")
                        Text("\(settingsStore.refreshIntervalMinutes) min")
                            .monospacedDigit()
                    }
                }
                Text("Choose how often feeds are refreshed automatically in the foreground and in the background.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Display") {
                Toggle("Show Last Refresh in Feed Header", isOn: $settingsStore.showLastRefresh)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

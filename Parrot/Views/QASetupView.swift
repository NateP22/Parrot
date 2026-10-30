import SwiftUI
import SwiftData

/// Real isolated Settings; this explicit diagnostic never claims meeting readiness.
struct QASetupView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var modelContext
    @State private var meetingModeScheduled = QASetupLaunch.meetingModeNextTime
    var body: some View {
        VStack(spacing: 0) {
            Text("Setup only: keys and profiles. Models and recording are off. Quit and reopen normally for meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
            if meetingModeScheduled {
                Text("Next launch: meeting mode. Speech models will prepare when you reopen.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Use meeting mode next time") {
                    meetingModeScheduled = QASetupLaunch.scheduleMeetingMode()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Divider()
            SettingsView(isEmbedded: true, initialSection: .apiKeys,
                         visibleSections: [.apiKeys, .profiles])
        }
        .task { recordingManager.prepareForQASetup(modelContext: modelContext) }
    }
}

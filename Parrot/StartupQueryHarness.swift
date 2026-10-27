import AppKit
import SwiftUI
import SwiftData

/// Non-capture diagnostic. Uses only an in-memory model container and synthetic
/// rows: no RecordingManager, services, preferences, credentials or audio.
@MainActor
enum StartupQueryHarness {
    static func run() {
        do {
            let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self,
                                 CallProfile.self, SpeakerProfile.self])
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            ])
            let context = container.mainContext
            context.autosaveEnabled = false
            let observation = QueryStartupObservation()
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let host = NSHostingController(rootView: QueryStartupProbe(observation: observation)
                .modelContainer(container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = host
            emit("host-created", rows: observation.rows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                emit("timeout", rows: observation.rows)
                exit(2)
            }
            Task { @MainActor in
                do {
                    @MainActor func settle(_ expected: Int, stage: String, details: Bool = false,
                                           title: String? = nil, processing: UUID? = nil) async throws {
                        for _ in 0..<30 {
                            host.view.needsLayout = true
                            host.view.layoutSubtreeIfNeeded()
                            host.view.displayIfNeeded()
                            try await Task.sleep(for: .milliseconds(20))
                            if let rendered = observation.rendered,
                               rendered.ids.count == expected, rendered.details == details,
                               title.map({ rendered.titles.contains($0) }) ?? true,
                               processing.map({ id in
                                   zip(rendered.ids, rendered.statuses).contains {
                                       $0.0 == id && $0.1 == MeetingStatus.processing.rawValue
                                   }
                               }) ?? true {
                                emit(stage, rows: observation.rows)
                                return
                            }
                        }
                        throw ProbeError.rowCount(stage: stage, expected: expected,
                                                  observed: observation.rows)
                    }
                    try await settle(0, stage: "empty-query-rendered")
                    for index in 1...5 {
                        let meeting = Meeting(title: "Synthetic startup probe \(index)")
                        emit("before-insert-\(index)", rows: observation.rows)
                        context.insert(meeting)
                        // Deliberately yield with the insert still unsaved, as
                        // recording startup yields while capture initializes.
                        try await settle(index, stage: "unsaved-insert-\(index)")
                        meeting.title += " saved"
                        try context.save()
                        try await settle(index, stage: "saved-insert-\(index)", title: meeting.title)
                        observation.details = true
                        meeting.status = .processing
                        try context.save()
                        try await settle(index, stage: "detail-transition-\(index)", details: true,
                                         processing: meeting.id)
                        observation.details = false
                        try await settle(index, stage: "list-transition-\(index)")
                    }
                    for meeting in try context.fetch(FetchDescriptor<Meeting>()) {
                        context.delete(meeting)
                    }
                    try context.save()
                    try await settle(0, stage: "deleted-synthetic-rows")
                    window.contentViewController = nil
                    emit("PASS", rows: observation.rows)
                    exit(0)
                } catch {
                    emit("FAIL", rows: observation.rows, error: String(describing: error))
                    exit(1)
                }
            }
            app.run()
        } catch {
            emit("container-failed", rows: -1, error: String(describing: error))
            exit(1)
        }
    }

    private static func emit(_ stage: String, rows: Int, error: String? = nil) {
        var payload: [String: Any] = ["stage": stage, "rows": rows,
                                      "audio_capture": false, "persistent_store": false]
        if let error { payload["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    private enum ProbeError: Error {
        case rowCount(stage: String, expected: Int, observed: Int)
    }
}

@MainActor
@Observable
private final class QueryStartupObservation {
    var rendered: QueryStartupRender?
    var rows: Int { rendered?.ids.count ?? -1 }
    var details = false
}

private struct QueryStartupRender: Equatable {
    var ids: [UUID]
    var titles: [String]
    var statuses: [String]
    var details: Bool
}

@MainActor
private struct QueryStartupProbe: View {
    let observation: QueryStartupObservation
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]

    var body: some View {
        VStack {
            Text("Synthetic startup probe")
            Text("Profiles: \(profiles.count)")
            if observation.details {
                ForEach(meetings) { meeting in
                    Text("\(meeting.title): \(meeting.status.rawValue)")
                }
            } else {
                List(meetings) { meeting in Text(meeting.title) }
            }
        }
        .onChange(of: rendered, initial: true) { _, value in
            observation.rendered = value
        }
    }

    private var rendered: QueryStartupRender {
        QueryStartupRender(ids: meetings.map(\.id), titles: meetings.map(\.title),
                           statuses: meetings.map { $0.status.rawValue },
                           details: observation.details)
    }
}

import AppKit
import SwiftUI

/// Resolves the actual Copilot view's own window, without selecting a settings
/// window or whichever window happens to be key after an asynchronous lookup.
struct QAAnswerWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> QAAnswerWindowView { QAAnswerWindowView() }
    func updateNSView(_ nsView: QAAnswerWindowView, context: Context) {}
}
final class QAAnswerWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NativeAnswerFrameRecorder.shared.attach(window: window)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct QAFrameCaptureStatus: View {
    @ObservedObject private var recorder = NativeAnswerFrameRecorder.shared
    var body: some View {
        Text(recorder.status)
            .font(Theme.Typography.sans(9,.medium))
            .foregroundStyle(Theme.Colors.ink3)
            .frame(maxWidth:.infinity,alignment:.leading)
            .padding(.horizontal,Theme.Metrics.pad)
    }
}
struct QAAnswerIdentityBadge: View {
    let context: AnswerTraceContext?
    let insightID: UUID
    var body: some View {
        if NativeAnswerFrameRecorder.isEnabled, let context {
            Text("Q " + context.questionID.uuidString + "\nI " + insightID.uuidString)
                .font(Theme.Typography.sans(9,.medium))
                .foregroundStyle(Theme.Colors.ink3)
                .fixedSize(horizontal:false,vertical:true)
        }
    }
}

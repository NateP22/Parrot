#!/usr/bin/env python3
"""Exercise the actual reopen decision with inert UI boundaries; no native PASS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Parrot/ParrotApp.swift").read_text()
start = source.index("    func applicationShouldHandleReopen(")
end = source.index("\n    func applicationShouldTerminate(", start)
method = source[start:end]
prefix = r'''
import Foundation
@MainActor final class NSApplication {
    var activations = 0
    func activate() { activations += 1 }
}
@MainActor let NSApp = NSApplication()
@MainActor enum ParrotApp {
    static let mainWindowID = "main"
    static var mainWindow: Bool? = nil
}
struct OpenWindowAction {
    let open: (String) -> Void
    func callAsFunction(id: String) { open(id) }
}
@MainActor final class ReopenDelegate {
    var openMainWindow: OpenWindowAction?
    static var dockRequests = 0
    static func showInDock() { dockRequests += 1 }
'''
suffix = r'''
}
@main enum Checks {
    @MainActor static func main() {
        var failures = 0
        var checks = 0
        func check(_ name: String, _ result: Bool) {
            checks += 1
            print((result ? "PASS " : "FAIL ") + name)
            if !result { failures += 1 }
        }
        // A missing registration must not consume the event with a no-op.
        // This was the setup-only scene after its only window was closed.
        for hasOtherWindow in [false, true] {
            ParrotApp.mainWindow = nil
            let delegate = ReopenDelegate()
            let beforeActivation = NSApp.activations
            let beforeDock = ReopenDelegate.dockRequests
            check("missing opener permits default reopen; other window=\(hasOtherWindow)",
                  delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: hasOtherWindow))
            check("missing opener still activates the app", NSApp.activations == beforeActivation + 1)
            check("missing opener still restores Dock presence", ReopenDelegate.dockRequests == beforeDock + 1)
        }
        // Existing normal behavior still targets one exact main-window id.
        for hasOtherWindow in [false, true] {
            ParrotApp.mainWindow = nil
            let delegate = ReopenDelegate()
            var opened: [String] = []
            delegate.openMainWindow = OpenWindowAction { opened.append($0) }
            let beforeActivation = NSApp.activations
            let beforeDock = ReopenDelegate.dockRequests
            let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: hasOtherWindow)
            check("registered opener consumes reopen; other window=\(hasOtherWindow)", !handled)
            check("registered opener opens main exactly once", opened == ["main"])
            check("registered opener still activates the app", NSApp.activations == beforeActivation + 1)
            check("registered opener still restores Dock presence", ReopenDelegate.dockRequests == beforeDock + 1)
        }
        ParrotApp.mainWindow = true
        let delegate = ReopenDelegate()
        var opened: [String] = []
        delegate.openMainWindow = OpenWindowAction { opened.append($0) }
        let beforeActivation = NSApp.activations
        let beforeDock = ReopenDelegate.dockRequests
        check("existing main window permits normal bring-forward",
              delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        check("existing main window creates no duplicate", opened.isEmpty)
        check("existing main window keeps ordinary activation handling", NSApp.activations == beforeActivation)
        check("existing main window keeps ordinary Dock handling", ReopenDelegate.dockRequests == beforeDock)
        print("REOPEN CHECKS: \(checks) checks, \(failures) failures; component-only")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="parrot-reopen-component-") as directory:
    temp = Path(directory)
    harness = temp / "ReopenChecks.swift"
    harness.write_text(prefix + method + suffix)
    binary = temp / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(temp / "module-cache"), str(harness),
                    "-o", str(binary)], check=True, timeout=60)
    raise SystemExit(subprocess.run([str(binary)], timeout=10).returncode)

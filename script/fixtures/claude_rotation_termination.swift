import AppKit

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var source: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        try! TokenRotationShutdownGuard.begin()
        source = TerminationSignalHandler.install { NSApp.terminate(nil) }
        kill(getpid(), SIGTERM)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TokenRotationShutdownGuard.beginTermination()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            TokenRotationShutdownGuard.end()
        }
        Task { @MainActor in
            await TokenRotationShutdownGuard.waitForIdle(warnAfter: .seconds(2)) { exit(2) }
            print("rotation saved")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
private enum Fixture {
    @MainActor static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { _exit(3) }
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

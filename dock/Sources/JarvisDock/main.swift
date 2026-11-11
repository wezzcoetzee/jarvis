import AppKit

// The macOS Dock guard's way back in, after Jarvis ended without restoring it.
if CommandLine.arguments.dropFirst().first == SystemDock.restoreFlag {
    SystemDock.restore()
    exit(0)
}

MainActor.assumeIsolated {
    Screenshots.requireFixtures()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

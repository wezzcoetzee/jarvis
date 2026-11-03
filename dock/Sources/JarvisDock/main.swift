import AppKit

MainActor.assumeIsolated {
    Screenshots.requireFixtures()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

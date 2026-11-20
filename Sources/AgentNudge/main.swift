import Cocoa

if CommandLine.arguments.contains("--self-test") {
    let code = MainActor.assumeIsolated {
        SelfTest.run()
    }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

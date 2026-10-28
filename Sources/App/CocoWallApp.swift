import SwiftUI

@main
struct CocoWallApp: App {
    init() {
        // Install the Rust core's log sink first so early pairing /
        // tunnel lines are captured too.
        CoreBridge.installLogging()
    }

    var body: some Scene {
        WindowGroup {
            // Native validation build: ContentView is the root again.
            // The web UI shell trial lives on in WebShellView.swift and
            // Sources/App/WebContent, unused as root for now.
            ContentView()
        }
    }
}

import SwiftUI

@main
struct CocoWallApp: App {
    var body: some Scene {
        WindowGroup {
            // Trial build: web UI shell (see WebShellView). The native
            // ContentView remains available for the native track.
            WebShellView()
        }
    }
}

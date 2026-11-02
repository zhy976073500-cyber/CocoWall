//
//  TendiesPreviewApp.swift
//  TendiesPreview (Phase 0 probe)
//
//  Entry point. The view model lives here so that .tendies files sent
//  to the app ("打开方式" / share sheet — document type declared in
//  Info.plist) reach the same instance the UI is showing.
//

import SwiftUI

@main
struct TendiesPreviewApp: App {
    @StateObject private var vm = PreviewViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .onOpenURL { url in
                    vm.importFrom(url: url)
                }
        }
    }
}

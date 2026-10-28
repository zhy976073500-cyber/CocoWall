import SwiftUI
import UIKit
import WebKit

/// Trial shell (2026-10-28, Sage: "打包成 IPA 试一下"): the app's UI is
/// the accepted web build (Lens design system), bundled as a single
/// self-contained index.html and shown full-screen in a WKWebView.
/// Native SwiftUI screens stay compiled but are not the entry point in
/// this trial build.
///
/// Two native bridges matter:
/// - Outbound: `localdevvpn://…` and App Store links from the page are
///   handed to UIApplication (a web view cannot open another app's
///   scheme by navigating to it).
/// - Inbound: LocalDevVPN calls back via `cocowall://` (registered in
///   Info.plist CFBundleURLTypes), which simply foregrounds the app.
struct WebShellView: View {
    var body: some View {
        WebContentView()
            .ignoresSafeArea()
    }
}

private struct WebContentView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "localdevvpn" || scheme == "cocowall" || url.host == "apps.apple.com" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // Links that would open a new window load in place instead.
            if navigationAction.targetFrame == nil, scheme == "http" || scheme == "https" {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

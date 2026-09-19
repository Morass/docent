import AppKit
import SwiftUI
import DocentKit
import WebKit

/// Self-capture, for the picture in the README.
///
/// The app draws its own window into a bitmap — no screen recording and no window-server
/// capture, so it needs no permission dialog on anybody's desk.
///
///     DOCENT_SCREENSHOT=/tmp/shot.png DOCENT_DOCSETS=/tmp/fixture \
///         build/Docent.app/Contents/MacOS/Docent
///
/// Exits when it is done; `make screenshot` wraps it.
@MainActor
enum Screenshot {
    static var isCapturing: Bool { ProcessInfo.processInfo.environment["DOCENT_SCREENSHOT"] != nil }

    static func scheduleIfRequested(browser: Browser) {
        guard let path = ProcessInfo.processInfo.environment["DOCENT_SCREENSHOT"] else { return }
        let query = ProcessInfo.processInfo.environment["DOCENT_SCREENSHOT_QUERY"] ?? "Print"
        // With a docset named and no query, the window shows that docset's front page —
        // which is the picture worth taking of a project Docent indexed.
        let docset = ProcessInfo.processInfo.environment["DOCENT_SCREENSHOT_DOCSET"]

        // Two hops through the run loop: one to let SwiftUI build the window, one to let
        // the web view finish drawing the page it was given.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let docset {
                browser.docsetFilter = docset
                browser.query = ProcessInfo.processInfo.environment["DOCENT_SCREENSHOT_QUERY"] ?? ""
            } else {
                browser.query = query
            }
            browser.searchAndWait()
            resizeWindow()
            // Wait for the page to actually have something on it. A fixed delay produced a
            // blank page in the README whenever the machine was busy.
            waitForPage {
                snapshotWebView {
                    capture(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Polls the web view until it has drawn something, then gives up after a while so a
    /// genuinely empty page still produces a picture rather than hanging the harness.
    private static func waitForPage(attempt: Int = 0, then done: @escaping () -> Void) {
        guard let window = mainWindow(),
              let root = window.contentView?.superview ?? window.contentView,
              let webView = findWebView(in: root), attempt < 60 else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
        }
        webView.evaluateJavaScript("document.readyState === 'complete' && document.body.innerText.length > 40") { value, _ in
            if (value as? Bool) == true {
                // One more beat for images and the highlighter.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    waitForPage(attempt: attempt + 1, then: done)
                }
            }
        }
    }

    private static func resizeWindow() {
        guard let window = mainWindow() else { return }
        window.setFrame(NSRect(x: 0, y: 0, width: 1340, height: 820), display: true)
        window.center()
    }

    private static func capture(to url: URL) {
        guard let window = mainWindow(),
              let root = window.contentView?.superview ?? window.contentView
        else { return note("no window") }

        let scale = window.backingScaleFactor
        let size = root.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return note("no bitmap") }

        rep.size = size
        // The layer tree, not the view tree: SwiftUI draws into layers, and `cacheDisplay`
        // walks views, which comes back with an empty sidebar.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        if let layer = root.layer {
            layer.render(in: context.cgContext)
        } else {
            root.cacheDisplay(in: root.bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()

        // A WKWebView draws in another process, so the window's layer tree has a hole where
        // the page should be. Ask the web view for its own snapshot and paste it in.
        if let image = webSnapshot, let webView = findWebView(in: root) {
            let frame = webView.convert(webView.bounds, to: root)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let data = rep.representation(using: .png, properties: [:]) else { return note("no png") }
        try? data.write(to: url)
        note("wrote \(url.path)")
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("screenshot: \(message)\n".utf8))
    }

    private static var webSnapshot: NSImage?

    private static func snapshotWebView(then done: @escaping () -> Void) {
        guard let window = mainWindow(),
              let root = window.contentView?.superview ?? window.contentView,
              let webView = findWebView(in: root) else { return done() }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, error in
            if let error { note("web snapshot failed: \(error)") }
            if image == nil { note("web snapshot came back empty") }
            webSnapshot = image
            if let image, let debug = ProcessInfo.processInfo.environment["DOCENT_SCREENSHOT_WEB"] {
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: debug))
                    note("wrote web snapshot to \(debug)")
                }
            }
            done()
        }
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
    }
}

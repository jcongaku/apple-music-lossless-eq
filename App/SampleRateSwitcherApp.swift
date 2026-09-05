import SwiftUI
import AppKit

// Menu bar mark: the brand wave — a parametric-EQ response curve with two
// band-handle nodes — rendered as a template image so it adapts to the menu
// bar appearance. Same curve as the app icon and the in-panel logo.
private enum MenuBarMark {
    static func response(_ t: Double) -> Double {
        sin(t * 2 * .pi)   // one sine cycle — matches the app icon
    }

    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let cgContext = NSGraphicsContext.current?.cgContext else { return false }

            let x0 = rect.width * 0.10
            let x1 = rect.width * 0.90
            let midY = rect.height * 0.50
            let amp = rect.height * 0.30

            func point(_ t: Double) -> NSPoint {
                NSPoint(x: x0 + (x1 - x0) * CGFloat(t),
                        y: midY + amp * CGFloat(response(t)))   // y-up (unflipped): a crest lifts up
            }

            let wave = NSBezierPath()
            let steps = 64
            for i in 0...steps {
                let p = point(Double(i) / Double(steps))
                if i == 0 { wave.move(to: p) } else { wave.line(to: p) }
            }
            wave.lineWidth = 1.9
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            NSColor.black.setStroke()
            wave.stroke()

            // Band handles: punch a hole through the curve, then ring it.
            let r: CGFloat = 2.0
            for t in [0.25, 0.75] {
                let c = point(t)
                let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                cgContext.setBlendMode(.destinationOut)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: box).fill()
                cgContext.setBlendMode(.normal)
                let ring = NSBezierPath(ovalIn: box)
                ring.lineWidth = 0.9
                NSColor.black.setStroke()
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// `MenuBarExtra(.window)` builds its content lazily on first open, so a
/// `.task` there would not run until the user clicks the menu bar. The launch
/// update check hangs off the application lifecycle instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateChecker.shared.checkAtLaunch()
    }
}

@main
struct SampleRateSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SampleRateModel()
    @StateObject private var eq = EQModel()
    @StateObject private var updates = UpdateChecker.shared

    var body: some Scene {
        MenuBarExtra {
            GlassPanelView(model: model, eq: eq, updates: updates)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: MenuBarMark.image)
                Text(model.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

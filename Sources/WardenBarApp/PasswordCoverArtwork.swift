import AppKit
import WardenBarDesktop

enum PasswordCoverState: CaseIterable {
    case locked, unlocked, lockFailed

    init(phase: VaultPhase) {
        switch phase {
        case .unlocked: self = .unlocked
        case .lockFailed: self = .lockFailed
        default: self = .locked
        }
    }
}

@MainActor
enum PasswordCoverArtwork {
    // Resolve installed app resources first; Bundle.module also supports swift run and tests.
    private static let resources = Bundle.main.url(forResource: "WardenBar_WardenBarApp", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module

    static let lockedHero = resources.url(forResource: "LockedHero", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))
    static let header = image(size: NSSize(width: 28, height: 20), brand: true)
    private static let closed = image(state: .locked)
    private static let open = image(state: .unlocked)
    private static let warning = image(state: .lockFailed)

    static func menuBar(_ state: PasswordCoverState) -> NSImage {
        switch state {
        case .locked: return closed
        case .unlocked: return open
        case .lockFailed: return warning
        }
    }

    private static func color(_ hex: UInt32) -> CGColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1).cgColor
    }

    private static func rounded(_ path: CGMutablePath, _ rect: CGRect, radius: CGFloat) {
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }

    private static func cover(start: CGFloat, end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start, y: 5))
        path.addLine(to: CGPoint(x: end - 5, y: 5))
        path.addCurve(to: CGPoint(x: end, y: 10), control1: CGPoint(x: end - 2.24, y: 5), control2: CGPoint(x: end, y: 7.24))
        path.addCurve(to: CGPoint(x: end - 5, y: 15), control1: CGPoint(x: end, y: 12.76), control2: CGPoint(x: end - 2.24, y: 15))
        path.addLine(to: CGPoint(x: start, y: 15))
        path.closeSubpath()
        return path
    }

    private static func image(size: NSSize = NSSize(width: 20, height: 18),
                              state: PasswordCoverState = .locked, brand: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            if brand {
                context.scaleBy(x: size.width / 28, y: size.height / 20)
                context.saveGState()
                context.addPath(CGPath(roundedRect: CGRect(x: 2, y: 5, width: 24, height: 10), cornerWidth: 5, cornerHeight: 5, transform: nil))
                context.clip()
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [color(0x8AD65D), color(0x3C8E2F)] as CFArray, locations: [0, 1])!
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 5), end: CGPoint(x: 0, y: 15), options: [])
                context.restoreGState()
                context.setFillColor(color(0xC4D5E9))
                context.addPath(cover(start: 18, end: 26)); context.fillPath()
                context.setFillColor(NSColor.white.cgColor)
                for center in [6.0, 10.0, 14.0] {
                    context.fillEllipse(in: CGRect(x: center - 1.2, y: 8.8, width: 2.4, height: 2.4))
                }
                context.setFillColor(color(0x60B83E))
                let grip = CGPath(roundedRect: CGRect(x: 20.5, y: 7, width: 3, height: 1), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil)
                context.addPath(grip); context.fillPath()
            } else {
                // Draw directly in the 20 × 18 pt menu canvas to keep the dots circular.
                let path = CGMutablePath()
                if state == .unlocked {
                    rounded(path, CGRect(x: 1, y: 4.5, width: 11.5, height: 9), radius: 4.5)
                    path.move(to: CGPoint(x: 14, y: 4.5))
                    path.addLine(to: CGPoint(x: 15, y: 4.5))
                    path.addCurve(to: CGPoint(x: 19.5, y: 9), control1: CGPoint(x: 17.485281375, y: 4.5), control2: CGPoint(x: 19.5, y: 6.514718625))
                    path.addCurve(to: CGPoint(x: 15, y: 13.5), control1: CGPoint(x: 19.5, y: 11.485281375), control2: CGPoint(x: 17.485281375, y: 13.5))
                    path.addLine(to: CGPoint(x: 14, y: 13.5))
                    path.closeSubpath()
                } else {
                    rounded(path, CGRect(x: 1, y: 4.5, width: 18, height: 9), radius: 4.5)
                    rounded(path, CGRect(x: 13, y: 5.5, width: 0.8, height: 7), radius: 0.4)
                }
                for center in [4.3, 7.4, 10.5] {
                    path.addEllipse(in: CGRect(x: center - 1.05, y: 7.95, width: 2.1, height: 2.1))
                }
                if state == .lockFailed {
                    rounded(path, CGRect(x: 15.55, y: 6.3, width: 1.1, height: 3.2), radius: 0.55)
                    path.addEllipse(in: CGRect(x: 15.4, y: 10.7, width: 1.4, height: 1.4))
                } else {
                    rounded(path, CGRect(x: state == .unlocked ? 14.8 : 14.9, y: 6.3, width: 2.6, height: 0.95), radius: 0.475)
                }
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(path); context.drawPath(using: .eoFill)
            }
            return true
        }
        image.isTemplate = !brand
        return image
    }
}

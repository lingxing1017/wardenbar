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

    private static func image(size: NSSize = NSSize(width: 24, height: 18),
                              state: PasswordCoverState = .locked, brand: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: size.width / 28, y: size.height / 20)
            if brand {
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
                let path = CGMutablePath()
                if state == .unlocked {
                    rounded(path, CGRect(x: 2, y: 5, width: 15, height: 10), radius: 5)
                    path.addPath(cover(start: 21, end: 27))
                } else {
                    rounded(path, CGRect(x: 2, y: 5, width: 24, height: 10), radius: 5)
                    rounded(path, CGRect(x: 18, y: 6, width: 1, height: 8), radius: 0.5)
                }
                for center in [6.0, 10.0, 14.0] {
                    path.addEllipse(in: CGRect(x: center - 1.2, y: 8.8, width: 2.4, height: 2.4))
                }
                if state == .lockFailed {
                    rounded(path, CGRect(x: 21.3, y: 7, width: 1.3, height: 3.5), radius: 0.65)
                    path.addEllipse(in: CGRect(x: 21.15, y: 11.2, width: 1.6, height: 1.6))
                } else {
                    rounded(path, CGRect(x: state == .unlocked ? 21.5 : 20.5, y: 7, width: 3, height: 1), radius: 0.5)
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

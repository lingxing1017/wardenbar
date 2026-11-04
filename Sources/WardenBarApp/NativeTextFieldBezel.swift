import AppKit
import SwiftUI

/// Draws native input chrome around a composite control without adding a second input.
@MainActor
struct NativeTextFieldBezel: NSViewRepresentable {
    let isFocused: Bool

    func makeNSView(context: Context) -> BezelView { BezelView() }

    func updateNSView(_ view: BezelView, context: Context) {
        view.cell.isEnabled = context.environment.isEnabled
        view.showsFocus = isFocused && context.environment.isEnabled
        view.needsDisplay = true
    }

    @MainActor
    final class BezelView: NSView {
        let cell: NSTextFieldCell = {
            let cell = NSTextFieldCell(textCell: "")
            cell.isBezeled = true
            cell.bezelStyle = .roundedBezel
            cell.isEditable = true
            // Like SwiftUI's rounded fields, let AppKit draw the bezel without
            // filling it with the opaque system text background color.
            cell.drawsBackground = false
            return cell
        }()
        var showsFocus = false

        override func draw(_ dirtyRect: NSRect) {
            cell.draw(withFrame: bounds, in: self)
            if showsFocus {
                NSGraphicsContext.saveGraphicsState()
                NSFocusRingPlacement.only.set()
                cell.drawFocusRingMask(withFrame: bounds, in: self)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

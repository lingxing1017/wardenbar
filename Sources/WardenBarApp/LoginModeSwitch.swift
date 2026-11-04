import AppKit
import SwiftUI

/// An explicitly neutral, full-width native segmented control, independent of accent color.
@MainActor
struct LoginModeSwitch: NSViewRepresentable {
    @Binding var selection: AccountLoginMode

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> FullWidthLoginSegments {
        let view = FullWidthLoginSegments(frame: .zero)
        view.segmentCount = AccountLoginMode.allCases.count
        for (index, mode) in AccountLoginMode.allCases.enumerated() {
            view.setLabel(mode.rawValue, forSegment: index)
        }
        view.trackingMode = .selectOne
        view.segmentStyle = .rounded
        view.segmentDistribution = .fillEqually
        view.selectedSegmentBezelColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedWhite: dark ? 0.40 : 0.80, alpha: 1)
        }
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.target = context.coordinator
        view.action = #selector(Coordinator.changed(_:))
        view.setAccessibilityLabel("登录方式")
        return view
    }

    func updateNSView(_ view: FullWidthLoginSegments, context: Context) {
        context.coordinator.selection = $selection
        view.selectedSegment = AccountLoginMode.allCases.firstIndex(of: selection) ?? 0
        view.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var selection: Binding<AccountLoginMode>
        init(selection: Binding<AccountLoginMode>) { self.selection = selection }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard sender.isEnabled, AccountLoginMode.allCases.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = AccountLoginMode.allCases[sender.selectedSegment]
        }
    }
}

@MainActor
final class FullWidthLoginSegments: NSSegmentedControl {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
}

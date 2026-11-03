import SwiftUI

struct NativeToolbarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let controls = content.padding(.horizontal, 8).padding(.vertical, 5)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            controls.glassEffect(.regular, in: Capsule())
        } else {
            fallback(controls)
        }
        #else
        fallback(controls)
        #endif
    }

    @ViewBuilder
    private func fallback<V: View>(_ controls: V) -> some View {
        if reduceTransparency {
            controls.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        } else {
            controls.background(.regularMaterial, in: Capsule())
        }
    }
}

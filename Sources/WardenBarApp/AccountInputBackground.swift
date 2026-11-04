import SwiftUI

/// One semantic surface for both composite and ordinary account inputs.
struct AccountInputBackground: View {
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 3)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

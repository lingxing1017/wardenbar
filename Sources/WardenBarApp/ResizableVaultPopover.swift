import AppKit
import SwiftUI
import WardenBarDesktop

@MainActor
struct ResizableVaultPopover: View {
    @ObservedObject var store: VaultStore
    let dataDirectory: URL
    let configurationIssue: String?
    @Binding var savedWidth: Double
    @State private var liveWidth: Double?
    @State private var dragStart: (mouseX: Double, width: Double)?

    private var width: Double { PopoverWidth.clamp(liveWidth ?? savedWidth) }

    var body: some View {
        VaultPopoverView(store: store, dataDirectory: dataDirectory, configurationIssue: configurationIssue)
            .frame(width: CGFloat(width), height: 520)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 20).contentShape(Rectangle())
                    .help("左右拖动调整宽度")
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            // Window origin shifts as MenuBarExtra stays anchored to its status item.
                            // Screen coordinates keep those shifts out of the drag calculation.
                            let mouseX = Double(NSEvent.mouseLocation.x)
                            if dragStart == nil { dragStart = (mouseX, width) }
                            if let start = dragStart {
                                liveWidth = PopoverWidth.resized(start: start.width, translation: mouseX - start.mouseX)
                            }
                            store.userDidInteract()
                        }
                        .onEnded { _ in finishResize() })
                    .accessibilityLabel("调整窗口宽度")
                    .accessibilityValue("\(Int(width)) 点")
                    .accessibilityHint("向左缩窄，向右加宽")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: savedWidth = PopoverWidth.resized(start: width, translation: 16)
                        case .decrement: savedWidth = PopoverWidth.resized(start: width, translation: -16)
                        @unknown default: break
                        }
                        store.userDidInteract()
                    }
                    .padding(3)
            }
            .onDisappear { finishResize(); NSCursor.arrow.set() }
    }

    private func finishResize() {
        if let liveWidth { savedWidth = PopoverWidth.clamp(liveWidth) }
        liveWidth = nil
        dragStart = nil
    }
}

import SwiftUI

/// Keep the navigator's preferred width independent of visibility and window
/// resizing. Narrow windows temporarily limit it to preserve usable SQL controls.
struct WorkspaceSplitView<Sidebar: View, Detail: View>: View {
    @Binding var sidebarVisible: Bool
    @AppStorage("workspace.sidebarWidth") private var preferredWidth = 260.0
    @State private var dragStart: CGFloat?
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        GeometryReader { geometry in
            let maximum = min(380, max(210, geometry.size.width - 660))
            let width = min(maximum, max(210, preferredWidth.isFinite ? preferredWidth : 260))
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar().frame(width: width)
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .overlay {
                            Color.clear.frame(width: 9)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { value in
                                        if dragStart == nil { dragStart = width }
                                        preferredWidth = min(maximum, max(210, (dragStart ?? width) + value.translation.width))
                                    }
                                    .onEnded { _ in dragStart = nil })
                                .onHover { hovering in
                                    if hovering { NSCursor.resizeLeftRight.push() }
                                    else { NSCursor.pop() }
                                }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("Sidebar Width")
                        .accessibilityValue("\(Int(width))")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: preferredWidth = min(maximum, width + 10)
                            case .decrement: preferredWidth = max(210, width - 10)
                            @unknown default: break
                            }
                        }
                }
                detail().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

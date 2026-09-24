import SwiftUI

/// Keep results useful at every window size; persist a proportion rather than
/// restoring an absolute editor height from a previously taller window.
struct QueryWorkspaceView: View {
    @AppStorage("workspace.queryEditorFraction") private var editorFraction = 0.35
    @State private var dragStart: CGFloat?
    @State private var resultsExpanded = false

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.height - 1)
            let minimum = min(180.0, available * 0.4)
            let maximum = max(minimum, available - 200)
            let fraction = editorFraction.isFinite ? editorFraction : 0.35
            let height = min(maximum, max(minimum, available * fraction))
            VStack(spacing: 0) {
                EditorView()
                    .frame(height: resultsExpanded ? 0 : height)
                    .clipped()
                    .allowsHitTesting(!resultsExpanded)
                    .accessibilityHidden(resultsExpanded)
                if !resultsExpanded {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                        .overlay {
                            Color.clear.frame(height: 9).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { value in
                                        if dragStart == nil { dragStart = height }
                                        editorFraction = min(maximum, max(minimum, (dragStart ?? height) + value.translation.height)) / max(1, available)
                                    }
                                    .onEnded { _ in dragStart = nil })
                                .simultaneousGesture(TapGesture(count: 2).onEnded { editorFraction = 0.35 })
                                .onHover { hovering in
                                    if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                                }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("SQL Editor Height")
                        .accessibilityValue("\(Int(height))")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: editorFraction = min(maximum, height + 20) / max(1, available)
                            case .decrement: editorFraction = max(minimum, height - 20) / max(1, available)
                            @unknown default: break
                            }
                        }
                }
                ResultGrid(resultsExpanded: $resultsExpanded)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

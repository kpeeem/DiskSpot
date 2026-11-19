import SwiftUI

/// Two panes with a draggable divider. Unlike HSplitView it holds no NSSplitView,
/// which cannot sit inside the safe-area inset an inspector applies.
struct SplitPane<Leading: View, Trailing: View>: View {
    let minLeading: CGFloat
    let minTrailing: CGFloat
    let storageKey: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @AppStorage private var leadingWidth: Double
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    init(minLeading: CGFloat, idealLeading: CGFloat, minTrailing: CGFloat, storageKey: String,
         @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.minLeading = minLeading
        self.minTrailing = minTrailing
        self.storageKey = storageKey
        self.leading = leading
        self.trailing = trailing
        _leadingWidth = AppStorage(wrappedValue: Double(idealLeading), storageKey)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = clamp(CGFloat(leadingWidth), total: proxy.size.width)
            HStack(spacing: 0) {
                leading()
                    .frame(width: width)
                divider(total: proxy.size.width)
                trailing()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? clamp(CGFloat(leadingWidth), total: total)
                                dragStart = start
                                leadingWidth = Double(clamp(start + value.translation.width, total: total))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .zIndex(1)
    }

    private func clamp(_ value: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(minLeading, total - minTrailing - 1)
        return min(max(value, minLeading), upper)
    }
}

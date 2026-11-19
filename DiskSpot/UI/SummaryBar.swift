import SwiftUI

/// Capacity bar in the style of System Settings → Storage.
struct SummaryBar: View {
    @Environment(AppModel.self) private var model

    private struct Segment: Identifiable {
        let id: String
        let value: Int64
        let color: Color
        var free = false
    }

    var body: some View {
        let segments = makeSegments()
        let total = max(1, segments.reduce(Int64(0)) { $0 + $1.value })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        let width = proxy.size.width * CGFloat(Double(segment.value) / Double(total))
                        if width >= 1 {
                            Rectangle()
                                .fill(segment.free ? Color.secondary.opacity(0.12) : segment.color)
                                .frame(width: width)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)
            .accessibilityLabel(segments.map { "\($0.id): \(Format.bytes($0.value))" }.joined(separator: ", "))

            FlowLayout(spacing: 16, lineSpacing: 4) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(segment.free ? Color.secondary.opacity(0.25) : segment.color)
                            .frame(width: 8, height: 8)
                        Text(segment.id)
                            .foregroundStyle(.secondary)
                        Text(Format.bytes(segment.value))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
            }
            .font(.callout)
        }
    }

    private func makeSegments() -> [Segment] {
        let breakdown = model.breakdown
        var segments = [
            Segment(id: "По данным Spotlight", value: breakdown.spotlight, color: .blue),
            Segment(id: "Посчитано точно", value: breakdown.exact, color: .green),
        ]
        if breakdown.system > 0 {
            segments.append(Segment(id: "Системные тома", value: breakdown.system, color: Color(nsColor: FileKind.system.color)))
        }
        if let space = model.space {
            segments.append(Segment(id: "Не видно", value: breakdown.unseen, color: Color(nsColor: .quaternaryLabelColor)))
            segments.append(Segment(id: "Свободно", value: space.available, color: .clear, free: true))
        }
        return segments
    }
}

/// Lays items out in rows, wrapping when the next item does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

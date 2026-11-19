import CoreGraphics

struct TreemapCell {
    let rect: CGRect
    unowned let node: Node
    let depth: Int
    let isLeaf: Bool
    let header: CGRect?
}

enum TreemapLayout {
    static let headerHeight: CGFloat = 16

    static func build(root: Node, in bounds: CGRect) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        cells.reserveCapacity(4096)
        place(root, rect: bounds, depth: 0, into: &cells)
        return cells
    }

    private static func place(_ node: Node, rect: CGRect, depth: Int, into cells: inout [TreemapCell]) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let children = node.children.filter { $0.size > 0 }
        guard !children.isEmpty, rect.width >= 8, rect.height >= 8 else {
            cells.append(TreemapCell(rect: rect, node: node, depth: depth, isLeaf: true, header: nil))
            return
        }

        let padding: CGFloat = depth == 0 ? 0 : 1
        var inner = rect.insetBy(dx: padding, dy: padding)
        var header: CGRect?
        if depth > 0, rect.width >= 80, rect.height >= 48 {
            header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
            inner = CGRect(
                x: rect.minX + padding,
                y: rect.minY + headerHeight,
                width: rect.width - padding * 2,
                height: rect.height - headerHeight - padding
            )
        }
        cells.append(TreemapCell(rect: rect, node: node, depth: depth, isLeaf: false, header: header))
        guard inner.width >= 2, inner.height >= 2 else { return }

        let rects = squarify(children.map { Double($0.size) }, in: inner)
        for (child, childRect) in zip(children, rects) {
            place(child, rect: childRect, depth: depth + 1, into: &cells)
        }
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk). `values` must be sorted in descending order.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            var end = start
            var rowSum = 0.0
            var bestWorst = Double.infinity
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                let sumSquared = candidateSum * candidateSum
                let sideSquared = side * side
                let largest = areas[start]
                let smallest = areas[end]
                let worst = max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
                if worst > bestWorst { break }
                bestWorst = worst
                rowSum = candidateSum
                end += 1
            }
            if end == start {
                rowSum = areas[start]
                end = start + 1
            }

            let thickness = CGFloat(rowSum / side)
            if remaining.width >= remaining.height {
                var y = remaining.minY
                for index in start..<end {
                    let height = CGFloat(areas[index]) / thickness
                    result[index] = CGRect(x: remaining.minX, y: y, width: thickness, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                var x = remaining.minX
                for index in start..<end {
                    let width = CGFloat(areas[index]) / thickness
                    result[index] = CGRect(x: x, y: remaining.minY, width: width, height: thickness)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
            }
            start = end
        }
        return result
    }
}

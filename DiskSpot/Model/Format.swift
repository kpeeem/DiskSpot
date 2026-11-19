import Foundation

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        let share = Double(part) / Double(total)
        if share > 0 && share < 0.001 { return "<0,1 %" }
        return share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
    }

    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.1f с", seconds) : "\(Int(seconds.rounded())) с"
    }
}

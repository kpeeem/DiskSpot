#if DEBUG
import AppKit

/// DISKSPOT_SNAPSHOT=/path/prefix writes window snapshots and scan stats while the scan progresses.
/// DISKSPOT_EXACT=<path>|all additionally runs an exact scan once the initial scan is done.
/// DISKSPOT_ZOOM=<path> zooms into that folder when idle and snapshots the animation.
/// DISKSPOT_SELECT=<path> selects that item once the initial scan is done.
@MainActor
enum DebugSnapshots {
    static func startIfRequested(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        if let probe = environment["DISKSPOT_PROBE"] {
            DispatchQueue.global().async {
                let started = Date()
                let node = ExactScanner(context: ScanContext()).scan(path: probe)
                let children = node?.children.map { "\($0.name)=\(Format.bytes($0.size))" } ?? []
                log("probe \(probe) \(Format.bytes(node?.size ?? -1)) in \(Int(Date().timeIntervalSince(started)))s: \(children)")
            }
        }
        guard let prefix = environment["DISKSPOT_SNAPSHOT"] else { return }
        let exactTarget = environment["DISKSPOT_EXACT"]
        let zoomTarget = environment["DISKSPOT_ZOOM"]
        let selectTarget = environment["DISKSPOT_SELECT"]
        let started = Date()
        var index = 0
        var exactTriggered = false
        var zoomTriggered = false
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(started)
                let b = model.breakdown
                log(String(format: "t=%.0fs busy=%d spotlight=%@ exact=%@ system=%@ unseen=%@ | %@", elapsed, model.isBusy ? 1 : 0,
                           Format.bytes(b.spotlight), Format.bytes(b.exact), Format.bytes(b.system), Format.bytes(b.unseen), model.jobStatus))
                if elapsed.rounded() == 3 {
                    index += 1
                    write(to: "\(prefix)-\(index).png")
                }
                guard !model.isBusy, let root = model.root else { return }
                if let selectTarget, model.selection == nil, let node = root.descendant(at: selectTarget, create: false) {
                    model.select(node)
                    return
                }
                index += 1
                write(to: "\(prefix)-\(index).png")
                if let zoomTarget, !zoomTriggered, let node = root.descendant(at: zoomTarget, create: false) {
                    zoomTriggered = true
                    model.zoom(to: node)
                    let frame = index + 1
                    index += 2
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { write(to: "\(prefix)-\(frame).png") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { write(to: "\(prefix)-\(frame + 1).png") }
                    return
                }
                if let exactTarget, !exactTriggered {
                    exactTriggered = true
                    if exactTarget == "all" {
                        model.scanEverythingExactly()
                    } else if let node = root.descendant(at: exactTarget, create: false) {
                        model.select(node)
                        model.scanExactly(node)
                    }
                    log("exact scan requested: \(exactTarget)")
                } else {
                    timer.invalidate()
                    dumpOutlineColumns()
                    log("done")
                }
            }
        }
    }

    /// The window as the window server composites it. Capturing one's own window needs no
    /// Screen Recording permission; the API is gone from the SDK headers, so it is looked up at runtime.
    /// Rendering the layer tree or `cacheDisplay` instead gives misleading pictures of SwiftUI content.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        return capture(.null, optionIncludingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }

    static func write(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let image = windowServerImage(of: window) else {
            log("snapshot failed \(path)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        let animating = window.contentView.flatMap(findCanvas)?.isZoomAnimating ?? false
        log("snapshot \(path) zoomAnimating=\(animating)")
    }

    static func dumpOutlineColumns() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView else { return }
        func find(_ view: NSView) -> DiskOutlineView? {
            if let outline = view as? DiskOutlineView { return outline }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let outline = find(content), let scroll = outline.enclosingScrollView else { return }
        let columns = outline.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))" }.joined(separator: " ")
        log("outline: scroll=\(Int(scroll.frame.width)) clip=\(Int(scroll.contentView.bounds.width)) table=\(Int(outline.frame.width)) spacing=\(outline.intercellSpacing) scroller=\(scroll.verticalScroller?.frame.width ?? 0) style=\(NSScroller.preferredScrollerStyle.rawValue) columns: \(columns)")
    }

    private static func findCanvas(in view: NSView) -> TreemapCanvas? {
        if let canvas = view as? TreemapCanvas { return canvas }
        for child in view.subviews {
            if let found = findCanvas(in: child) { return found }
        }
        return nil
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }
}
#endif

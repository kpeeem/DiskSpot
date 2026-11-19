import AppKit
import Quartz

/// Shared Quick Look source. Views in the responder chain hand the panel over to it
/// through `acceptsPreviewPanelControl`, as the panel looks for its controller there.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var url: URL?

    func show(_ url: URL?, onlyIfVisible: Bool) {
        self.url = url
        let open = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        if open {
            QLPreviewPanel.shared().reloadData()
        } else if !onlyIfVisible, url != nil {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    func toggle(_ url: URL?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            show(url, onlyIfVisible: false)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}

extension NSView {
    func attachQuickLook(_ panel: QLPreviewPanel) {
        panel.dataSource = QuickLook.shared
        panel.delegate = QuickLook.shared
    }

    func detachQuickLook(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

import SwiftUI
import AppKit

struct StickyContentView: View {
    let stickyId: String
    let initialHTML: String
    let engine: SyncEngine

    var body: some View {
        StickyTextEditor(initialHTML: initialHTML) { newAttributed in
            let html = HTMLNormalizer.html(from: newAttributed)
            try? engine.updateContent(stickyId: stickyId, html: html)
        }
        .background(Color.clear)
        .padding(8)
    }
}

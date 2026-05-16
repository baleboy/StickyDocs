import SwiftUI
import AppKit

struct StickyContentView: View {
    let stickyId: String
    let initialHTML: String
    let colorName: String
    let engine: SyncEngine
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.5))
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(.black.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 16)

            StickyTextEditor(initialHTML: initialHTML) { newAttributed in
                let html = HTMLNormalizer.html(from: newAttributed)
                try? engine.updateContent(stickyId: stickyId, html: html)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(Color(StickyColor.background(for: colorName)))
        .onHover { hovering = $0 }
    }
}

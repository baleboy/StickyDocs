import SwiftUI
import AppKit

// PROTOTYPE — throwaway visual mock of an Xcode-style "All Stickies" launcher.
// Uses static sample data and isn't wired into AppController. Delete or
// replace once the design is settled.

struct LauncherItem: Identifiable {
    let id = UUID()
    let title: String
    let preview: String
    let color: String
    let modified: Date
    var statusColor: Color? = nil
}

struct LauncherPrototypeView: View {
    var items: [LauncherItem]
    var account: String? = "bale@balenet.com"
    var lastSync = "Synced 2 min ago"

    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 470)
            rightPane
                .frame(maxWidth: .infinity)
        }
        .frame(width: 800, height: 480)
        .onAppear { selection = items.first?.id }
    }

    // MARK: Left pane

    private var leftPane: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                Text("StickyDocs")
                    .font(.system(size: 36, weight: .bold))
                    .padding(.top, 10)
                Text("Version 1.2.0")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                statusLine
                    .padding(.top, 8)

                Spacer()

                VStack(spacing: 10) {
                    if account != nil {
                        LauncherActionButton(title: "New Sticky", systemImage: "plus.square", shortcut: "⇧⌘N")
                        LauncherActionButton(title: "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        LauncherActionButton(title: "Open Stickies Folder in Drive", systemImage: "folder")
                    } else {
                        LauncherActionButton(title: "Sign In with Google…", systemImage: "person.crop.circle")
                        LauncherActionButton(title: "New Sticky", systemImage: "plus.square", shortcut: "⇧⌘N")
                    }
                }
                .padding(.horizontal, 56)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)

            CloseButton()
                .padding(14)
        }
        .background(.background)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let account {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("\(account) · \(lastSync)")
            } else {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                Text("Not signed in")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Right pane

    private var rightPane: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Text("No stickies yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Press ⇧⌘N to create one")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            LauncherRow(item: item, isSelected: item.id == selection)
                                .onTapGesture { selection = item.id }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color.primary.opacity(0.05))
        .background(.background)
    }
}

private struct LauncherRow: View {
    let item: LauncherItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StickyTile(color: item.color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let status = item.statusColor {
                        Circle()
                            .fill(isSelected ? .white : status.opacity(0.8))
                            .frame(width: 6, height: 6)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(item.preview)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .monospacedDigit()
                        .layoutPriority(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }
}

// A tiny sticky note: the sticky's color, a folded corner, and faint "text" lines.
private struct StickyTile: View {
    let color: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(StickyColor.background(for: color)))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach([18.0, 14, 16], id: \.self) { w in
                    Capsule().fill(.black.opacity(0.18)).frame(width: w, height: 2)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 5)
        }
        .frame(width: 28, height: 30)
    }
}

private struct LauncherActionButton: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    @State private var hovering = false

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct CloseButton: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.primary.opacity(0.1)))
    }
}

// MARK: - Sample data & previews

extension LauncherItem {
    static let samples: [LauncherItem] = {
        let now = Date()
        return [
            LauncherItem(title: "Groceries", preview: "milk, eggs, coffee beans, lemons",
                         color: "yellow", modified: now.addingTimeInterval(-120)),
            LauncherItem(title: "Release checklist", preview: "tag, notarize, staple, appcast",
                         color: "blue", modified: now.addingTimeInterval(-3_600), statusColor: .orange),
            LauncherItem(title: "Ideas", preview: "hyperlink detection, markdown lists, headings",
                         color: "green", modified: now.addingTimeInterval(-86_400 * 2)),
            LauncherItem(title: "Phone numbers", preview: "plumber 040 123 4567, dentist…",
                         color: "pink", modified: now.addingTimeInterval(-86_400 * 9)),
            LauncherItem(title: "Trip to Rome", preview: "flights booked, hotel near Trastevere",
                         color: "purple", modified: now.addingTimeInterval(-86_400 * 20)),
            LauncherItem(title: "Wi-Fi password", preview: "guest network: ask Francesco",
                         color: "gray", modified: now.addingTimeInterval(-86_400 * 45), statusColor: .red),
            LauncherItem(title: "Book list", preview: "Piranesi, The Dispossessed, Middlemarch",
                         color: "yellow", modified: now.addingTimeInterval(-86_400 * 60)),
        ]
    }()
}

#Preview("Light") {
    LauncherPrototypeView(items: LauncherItem.samples)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    LauncherPrototypeView(items: LauncherItem.samples)
        .preferredColorScheme(.dark)
}

#Preview("Signed out, empty") {
    LauncherPrototypeView(items: [], account: nil)
        .preferredColorScheme(.dark)
}

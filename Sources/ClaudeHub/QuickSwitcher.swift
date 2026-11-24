import SwiftUI

/// ⌘P: type to filter the open tabs by title or folder, ↑↓ to pick,
/// Return to jump, Esc to dismiss. Most recently used tabs come first.
struct QuickSwitcherView: View {
    @ObservedObject var tabs: TabsModel
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [TerminalTab] {
        let recent = tabs.recentTabIDs
        let ordered = tabs.tabs.sorted { a, b in
            (recent.firstIndex(of: a.id) ?? .max) < (recent.firstIndex(of: b.id) ?? .max)
        }
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ordered }
        return ordered.filter { tab in
            let haystack = (tab.title + " " + TabsModel.folderName(tab.cwd) + " " + tab.cwd).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let list = matches
        VStack(spacing: 0) {
            TextField("Search open tabs", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { open(list) }
                .onChange(of: query) { _, _ in selection = 0 }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, tab in
                            row(tab, selected: index == selection)
                                .id(tab.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = index
                                    open(list)
                                }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, value in
                    if list.indices.contains(value) { proxy.scrollTo(list[value].id) }
                }
            }
            if list.isEmpty {
                Text("No open tab matches")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(width: 520, height: 380)
        .onAppear { fieldFocused = true }
        .onKeyPress(.downArrow) { move(1, in: list); return .handled }
        .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ tab: TerminalTab, selected: Bool) -> some View {
        HStack(spacing: 8) {
            ActivityDot(activity: TerminalManager.shared.activity(of: tab.id), size: 6)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title).lineLimit(1)
                Text(TabsModel.folderName(tab.cwd))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let number = tabs.number(of: tab.id) {
                Text("#\(number)").font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            }
            if tab.id == tabs.activeTabID {
                Text("current").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func move(_ step: Int, in list: [TerminalTab]) {
        guard !list.isEmpty else { return }
        selection = min(max(selection + step, 0), list.count - 1)
    }

    private func open(_ list: [TerminalTab]) {
        guard list.indices.contains(selection) else { return }
        tabs.show(list[selection].id)
        dismiss()
    }
}

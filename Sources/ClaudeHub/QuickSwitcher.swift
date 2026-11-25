import SwiftUI

/// ⌘P: type to filter by title or folder, ↑↓ to pick, Return to go, Esc to
/// dismiss. Open tabs come first, most recently used first; then every other
/// session in the sidebar, newest first, which opens in a tab when picked.
struct QuickSwitcherView: View {
    @ObservedObject var tabs: TabsModel
    /// The sidebar's sessions (hidden ones left out).
    let sessions: [ClaudeSession]
    /// Every git worktree of the sidebar's repositories; picking one starts
    /// a new session in it.
    var worktrees: [Worktree] = []
    /// Starts a new session in a folder (and lets the sidebar know).
    var onNewSession: (String) -> Void = { _ in }
    let dismiss: () -> Void

    private enum Item: Identifiable {
        case tab(TerminalTab)
        case worktree(Worktree)
        case session(ClaudeSession)

        var id: String {
            switch self {
            case .tab(let tab): return "t:" + tab.id
            case .worktree(let worktree): return "w:" + worktree.path
            case .session(let session): return "s:" + session.id
            }
        }

        var title: String {
            switch self {
            case .tab(let tab): return tab.title
            case .worktree(let worktree): return "New session in " + worktree.label
            case .session(let session): return session.title
            }
        }

        var cwd: String {
            switch self {
            case .tab(let tab): return tab.cwd
            case .worktree(let worktree): return worktree.path
            case .session(let session): return session.cwd
            }
        }
    }

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [Item] {
        let recent = tabs.recentTabIDs
        let ordered = tabs.tabs.sorted { a, b in
            (recent.firstIndex(of: a.id) ?? .max) < (recent.firstIndex(of: b.id) ?? .max)
        }
        // A session with a tab is listed once, as the tab.
        let open = Set(tabs.tabs.compactMap(\.sessionID))
        let rest = sessions
            .filter { !open.contains($0.id) }
            .sorted { $0.lastActivity > $1.lastActivity }
        let items = ordered.map(Item.tab) + worktrees.map(Item.worktree) + rest.map(Item.session)
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = (item.title + " " + item.cwd).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let list = matches
        VStack(spacing: 0) {
            TextField("Search tabs and sessions", text: $query)
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
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .id(item.id)
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
                Text("Nothing matches")
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

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch item {
            case .tab(let tab):
                ActivityDot(activity: TerminalManager.shared.activity(of: tab.id), size: 6)
                    .frame(width: 14)
            case .worktree:
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .frame(width: 14)
            case .session(let session):
                Image(systemName: session.isCursor ? "cursorarrow.rays" : "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(SidebarTree.abbreviate(item.cwd))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            switch item {
            case .tab(let tab):
                if let number = tabs.number(of: tab.id) {
                    Text("#\(number)").font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                }
                if tab.id == tabs.activeTabID {
                    Text("current").font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                }
            case .worktree(let worktree):
                Text(worktree.isMain ? "main checkout" : "worktree").font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            case .session(let session):
                Text(session.lastActivity, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func move(_ step: Int, in list: [Item]) {
        guard !list.isEmpty else { return }
        selection = min(max(selection + step, 0), list.count - 1)
    }

    private func open(_ list: [Item]) {
        guard list.indices.contains(selection) else { return }
        switch list[selection] {
        case .tab(let tab): tabs.show(tab.id)
        case .worktree(let worktree): onNewSession(worktree.path)
        case .session(let session): tabs.openSession(session)
        }
        dismiss()
    }
}

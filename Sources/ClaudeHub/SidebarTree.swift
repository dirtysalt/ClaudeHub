import Foundation

/// One line of the sidebar tree, already flattened in drawing order.
///
/// The sidebar stays a flat list of leaves (see ContentView.sidebar for why it
/// is not a SwiftUI outline); nesting is drawn with `depth`.
struct SidebarRow: Identifiable {
    enum Kind {
        /// A directory with no sessions of its own that groups projects below it.
        case folder(path: String, label: String, sessions: [ClaudeSession])
        /// A directory Claude sessions ran in. `sessions` covers its whole subtree.
        case project(ClaudeProject, label: String, sessions: [ClaudeSession])
        case session(ClaudeSession)
    }

    let id: String
    let depth: Int
    let kind: Kind
}

enum SidebarTree {
    private final class Node {
        let name: String
        let path: String
        var children: [String: Node] = [:]
        var project: ClaudeProject?
        /// Position of the earliest project below, so the tree keeps the
        /// sidebar's existing order (recency, pins).
        var rank = Int.max

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        var sortedChildren: [Node] { children.values.sorted { $0.rank < $1.rank } }

        var allSessions: [ClaudeSession] {
            (project?.sessions ?? []) + sortedChildren.flatMap(\.allSessions)
        }
    }

    /// `projects` in display order; `isCollapsed(path)` says which nodes are folded.
    static func rows(for projects: [ClaudeProject],
                     isCollapsed: (String) -> Bool) -> [SidebarRow] {
        let root = Node(name: "", path: "")
        for (index, project) in projects.enumerated() {
            var node = root
            node.rank = min(node.rank, index)
            for component in project.path.split(separator: "/") {
                let name = String(component)
                let child = node.children[name] ?? Node(name: name, path: node.path + "/" + name)
                node.children[name] = child
                child.rank = min(child.rank, index)
                node = child
            }
            node.project = project
        }

        // Skip the directories every project shares ("/", "Users", …).
        var top = root
        while top.project == nil, top.children.count == 1, let only = top.children.values.first {
            top = only
        }
        guard top !== root || !root.children.isEmpty else { return [] }

        var rows: [SidebarRow] = []
        if top === root {
            // Nothing in common: every first-level directory is a top row.
            for child in root.sortedChildren {
                let (node, _) = compress(child, label: child.name)
                emit(node, label: abbreviate(node.path), depth: 0, into: &rows, isCollapsed: isCollapsed)
            }
        } else {
            emit(top, label: abbreviate(top.path), depth: 0, into: &rows, isCollapsed: isCollapsed)
        }
        return rows
    }

    /// A directory with no sessions and a single subdirectory is one row:
    /// `a/b/c` rather than three levels with nothing in them.
    private static func compress(_ node: Node, label: String) -> (Node, String) {
        var node = node
        var label = label
        while node.project == nil, node.children.count == 1, let only = node.children.values.first {
            node = only
            label += "/" + only.name
        }
        return (node, label)
    }

    private static func emit(_ node: Node, label: String, depth: Int,
                             into rows: inout [SidebarRow],
                             isCollapsed: (String) -> Bool) {
        let sessions = node.allSessions
        if let project = node.project {
            rows.append(SidebarRow(id: "p:" + node.path, depth: depth,
                                   kind: .project(project, label: label, sessions: sessions)))
        } else {
            rows.append(SidebarRow(id: "f:" + node.path, depth: depth,
                                   kind: .folder(path: node.path, label: label, sessions: sessions)))
        }
        guard !isCollapsed(node.path) else { return }
        for session in node.project?.sessions ?? [] {
            rows.append(SidebarRow(id: "s:" + session.id, depth: depth + 1, kind: .session(session)))
        }
        for child in node.sortedChildren {
            let (child, childLabel) = compress(child, label: child.name)
            emit(child, label: childLabel, depth: depth + 1, into: &rows, isCollapsed: isCollapsed)
        }
    }

    /// ~/repo instead of /Users/…/repo.
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

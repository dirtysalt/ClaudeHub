import AppKit
import Combine
import Foundation

/// One changed file, as `git status` marks it.
struct GitFile: Identifiable, Equatable {
    /// "M" modified, "A" added, "D" deleted, "?" untracked, "U" unmerged.
    let mark: String
    let path: String

    var id: String { "\(mark) \(path)" }
}

/// What one repository has lying around.
struct RepoStatus: Identifiable, Equatable {
    let root: String
    let branch: String
    /// Nil when the branch tracks nothing — it exists only on this machine.
    let upstream: String?
    let ahead: Int
    let behind: Int
    let files: [GitFile]
    /// When the longest-untouched change was last written. Twelve files from
    /// this afternoon and twelve from three weeks ago are not the same
    /// situation, and the count alone cannot tell them apart.
    let oldestChange: Date?

    var id: String { root }
    var name: String { (root as NSString).lastPathComponent }
    var changed: Int { files.filter { $0.mark != "?" }.count }
    var untracked: Int { files.filter { $0.mark == "?" }.count }
    var isDirty: Bool { !files.isEmpty }

    /// The count for the project header: everything that is not committed.
    var pending: Int { files.count }

    /// Where this branch stands against the remote, in the fewest words that
    /// are still true.
    var syncLabel: String {
        guard upstream != nil else { return "not pushed anywhere" }
        switch (ahead, behind) {
        case (0, 0): return "in sync"
        case (let a, 0): return "\(a) ahead"
        case (0, let b): return "\(b) behind"
        case (let a, let b): return "\(a) ahead, \(b) behind"
        }
    }

    var isUnpushed: Bool { upstream == nil }

    /// "6 d", "3 hr", "20 min" — short enough for a sidebar row.
    var age: String? {
        guard let oldestChange else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(oldestChange)))
        if seconds >= 86_400 { return "\(seconds / 86_400) d" }
        if seconds >= 3_600 { return "\(seconds / 3_600) hr" }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "just now"
    }
}

/// Reads `git status` for the projects ClaudeHub already knows about.
///
/// The question this answers is not "what changed in this file" — that is an
/// editor's job, and a good one is already open. It is "where did I leave work
/// lying around", across every project in the sidebar, which is the same
/// question the session list answers and nothing else on screen does.
/// One checkout of a repository, from `git worktree list`.
struct Worktree: Identifiable, Equatable {
    let path: String
    /// Nil for a detached HEAD.
    let branch: String?
    /// The repository's own checkout rather than an added worktree.
    let isMain: Bool

    var id: String { path }
    var label: String { branch ?? (path as NSString).lastPathComponent }
}

final class GitStore: ObservableObject {
    @Published private(set) var repos: [RepoStatus] = []
    /// Every checkout of the sidebar's repositories, keyed by repository
    /// root — so a worktree made a moment ago, which has no sessions and so
    /// no place in the sidebar yet, is one ⌘P away from its first one.
    @Published private(set) var worktreesByRoot: [String: [Worktree]] = [:]

    /// All known worktrees, each once, added worktrees before main checkouts.
    var allWorktrees: [Worktree] {
        var seen = Set<String>()
        return worktreesByRoot.values.flatMap { $0 }
            .filter { seen.insert($0.path).inserted }
            .sorted { ($0.isMain ? 1 : 0, $0.label) < ($1.isMain ? 1 : 0, $1.label) }
    }

    /// The worktrees of the repositories a project folder covers.
    func worktrees(forProjectAt path: String) -> [Worktree] {
        var seen = Set<String>()
        return repos(forProjectAt: path)
            .flatMap { worktreesByRoot[$0.root] ?? [] }
            .filter { seen.insert($0.path).inserted }
    }

    private var roots: [String] = []
    /// Project folder → the repositories in it, so the filesystem is walked
    /// once per folder and never on the main thread.
    private var rootCache: [String: [String]] = [:]
    /// The same thing already answered: every project header in the sidebar
    /// asks for its repositories while the list is being laid out, so the
    /// answer is worked out when a scan changes something, not per project per
    /// pass.
    private var byProject: [String: [RepoStatus]] = [:]
    private var timer: Timer?
    private var scanning = false
    private let queue = DispatchQueue(label: "be.optimize.claudehub.git", qos: .utility)

    private let gitPath = GitStore.binary

    /// The repositories worth watching, from the folders the sidebar lists.
    var dirtyRepos: [RepoStatus] { repos.filter(\.isDirty) }

    /// The repositories belonging to one project folder. A folder in the
    /// sidebar is often a container — `fytolog` holds five repos, `PERSOONLIJK`
    /// holds this one — so this is a list, not a single answer.
    func repos(forProjectAt path: String) -> [RepoStatus] {
        byProject[path] ?? []
    }

    /// Walks `repos` rather than the cache, so each project keeps the order
    /// the scan put its repositories in — the busiest first.
    private func indexByProject() {
        var owners: [String: [String]] = [:]
        for (path, roots) in rootCache {
            for root in roots { owners[root, default: []].append(path) }
        }
        var index: [String: [RepoStatus]] = [:]
        for repo in repos {
            for path in owners[repo.root] ?? [] { index[path, default: []].append(repo) }
        }
        byProject = index
    }

    /// Refreshed on a slow timer, and only while the window is in front: a
    /// status you are not looking at is 27 processes nobody asked for.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard NSApplication.shared.isActive else { return }
            self?.scan()
        }
    }

    /// Called with the sidebar's project folders whenever they are rescanned.
    func track(projects paths: [String]) {
        let unknown = paths.filter { rootCache[$0] == nil }
        guard !unknown.isEmpty else { return scan() }

        queue.async {
            var found: [String: [String]] = [:]
            for path in unknown { found[path] = Self.repositories(in: path) }
            DispatchQueue.main.async {
                for (path, roots) in found { self.rootCache[path] = roots }
                self.indexByProject()
                let unique = Array(Set(self.rootCache.values.flatMap { $0 })).sorted()
                guard unique != self.roots else { return }
                self.roots = unique
                self.scan()
            }
        }
    }

    func scan() {
        guard !scanning, !roots.isEmpty else { return }
        scanning = true
        let roots = self.roots
        let git = gitPath

        queue.async {
            let statuses = roots.compactMap { Self.read(root: $0, git: git) }
            var worktrees: [String: [Worktree]] = [:]
            for root in roots { worktrees[root] = Self.worktrees(of: root, git: git) }
            DispatchQueue.main.async {
                if worktrees != self.worktreesByRoot { self.worktreesByRoot = worktrees }
                self.scanning = false
                let sorted = statuses.sorted { ($0.pending, $1.name) > ($1.pending, $0.name) }
                guard sorted != self.repos else { return }
                self.repos = sorted
                self.indexByProject()
            }
        }
    }

    // MARK: - Reading

    /// The repositories a project folder covers.
    ///
    /// A folder you run Claude in is not necessarily a repository. It is just
    /// as often the folder above several of them — one client, five repos —
    /// and it can also sit inside one. So this looks at the folder itself,
    /// then up for the repository containing it, and failing both, a couple of
    /// levels down for the repositories it contains.
    static func repositories(in path: String, maxDepth: Int = 2) -> [String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
            return [path]
        }
        if let enclosing = enclosingRepository(of: path) { return [enclosing] }

        var found: [String] = []
        var frontier = [(path: path, depth: 0)]
        while let next = frontier.popLast() {
            guard next.depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(atPath: next.path) else { continue }
            for child in children where !Self.skipped.contains(child) && !child.hasPrefix(".") {
                let full = (next.path as NSString).appendingPathComponent(child)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue
                else { continue }
                if fm.fileExists(atPath: (full as NSString).appendingPathComponent(".git")) {
                    found.append(full)          // repositories do not nest usefully
                } else {
                    frontier.append((full, next.depth + 1))
                }
            }
        }
        return found
    }

    /// Folders that are never a project of yours, and are expensive to walk.
    private static let skipped: Set<String> = [
        "node_modules", "vendor", "Library", "venv", ".venv", "dist", "build", "target",
    ]

    private static func enclosingRepository(of path: String) -> String? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fm = FileManager.default
        while url.path != "/" && url.path != NSHomeDirectory() {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// `git worktree list --porcelain`: blocks of `worktree <path>`,
    /// `branch refs/heads/<name>` (or `detached`), separated by blank lines.
    /// The first block is the main checkout. Folders that are gone are left out.
    static func worktrees(of root: String, git: String = binary) -> [Worktree] {
        guard let text = run(["worktree", "list", "--porcelain"], in: root, git: git) else { return [] }
        var result: [Worktree] = []
        for block in text.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst("branch ".count))
                        .replacingOccurrences(of: "refs/heads/", with: "")
                }
            }
            guard let path, FileManager.default.fileExists(atPath: path) else { continue }
            result.append(Worktree(path: path, branch: branch, isMain: result.isEmpty))
        }
        return result
    }

    private static func read(root: String, git: String) -> RepoStatus? {
        guard let text = run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"],
                             in: root, git: git) else { return nil }
        return parse(text, root: root)
    }

    /// Runs git in a repository and hands back what it said. Shared with the
    /// diff view, so there is one place that knows how to call git.
    static func run(_ arguments: [String], in root: String, git: String = binary) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        // Read before waiting: a large diff fills the pipe and a waiting git
        // would sit there for ever with nobody draining it.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Whichever git this machine has.
    static let binary: String = {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }()

    /// `git status --porcelain=v2 --branch`, which states the branch, its
    /// upstream and how far apart they are before listing the files.
    static func parse(_ text: String, root: String) -> RepoStatus {
        var branch = "detached"
        var upstream: String?
        var ahead = 0
        var behind = 0
        var files: [GitFile] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // "+2 -1"
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                behind = parts.count > 1 ? Int(parts[1].dropFirst()) ?? 0 : 0
            } else if line.hasPrefix("? ") {
                files.append(GitFile(mark: "?", path: String(line.dropFirst(2))))
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>", and a rename
                // adds "<tab><original>" to the end of the path.
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard fields.count == 9 else { continue }
                let code = fields[1]
                let path = fields[8].split(separator: "\t").first.map(String.init) ?? String(fields[8])
                files.append(GitFile(mark: mark(for: code), path: path))
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                if let path = fields.last { files.append(GitFile(mark: "U", path: String(path))) }
            }
        }

        return RepoStatus(root: root,
                          branch: branch,
                          upstream: upstream,
                          ahead: ahead,
                          behind: behind,
                          files: files,
                          oldestChange: oldest(of: files, in: root))
    }

    /// The earliest write among the changed files. A deleted file has no date
    /// to read, so it simply does not vote.
    private static func oldest(of files: [GitFile], in root: String) -> Date? {
        let fm = FileManager.default
        return files.compactMap { file -> Date? in
            let path = (root as NSString).appendingPathComponent(file.path)
            return (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }.min()
    }

    /// The staged column first, then the unstaged one: what the file is, in one
    /// letter, the way git itself abbreviates it.
    private static func mark(for code: Substring) -> String {
        for character in code where character != "." {
            return String(character)
        }
        return "M"
    }
}

import Darwin
import Foundation

/// What a Claude session still has running after its own turn has ended: the
/// agents it sent off in the background, and the shell commands it left going
/// — a build, a deploy it is watching, a loop that wakes it when something is
/// ready.
///
/// None of it shows on screen as "esc to interrupt". The prompt is back and the
/// session looks idle, yet all of it lives inside the session's process, so
/// restarting that process — which is what moving a conversation to another
/// account does — ends every one of them. The session then wakes up on the new
/// account being told its work "didn't finish before the previous session
/// ended", and the agent that was meant to pick it up never hears back.
struct BackgroundWork: Equatable {
    var agents = 0
    var shells = 0

    var isEmpty: Bool { agents == 0 && shells == 0 }

    /// "2 background agents and 1 shell command"
    var summary: String {
        var parts: [String] = []
        if agents > 0 { parts.append(agents == 1 ? "1 background agent" : "\(agents) background agents") }
        if shells > 0 { parts.append(shells == 1 ? "1 shell command" : "\(shells) shell commands") }
        return parts.joined(separator: " and ")
    }
}

/// The shell commands a session is running, counted from the process table.
///
/// Claude Code runs every Bash and Monitor command in a shell of its own,
/// started as a direct child of the `claude` process, and that shell lives
/// exactly as long as the command does. So the count needs no bookkeeping that
/// could go stale: a command stopped from the task list, or one that died, is
/// simply not there any more.
enum SessionShells {
    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "ksh", "tcsh", "csh"]

    static func count(under pid: pid_t) -> Int {
        guard pid > 0 else { return 0 }
        return children(of: pid).filter { child in
            guard let path = executable(of: child) else { return false }
            return shells.contains((path as NSString).lastPathComponent)
        }.count
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func executable(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }
}

/// Follows one session's transcript for the agents it sends off in the
/// background, and for the notices that say they are done.
///
/// An agent runs inside the `claude` process, so unlike a shell command it
/// leaves nothing in the process table. Claude Code does write both ends of it
/// down: the Agent call's result says `"status":"async_launched"` with the
/// agent's id, and when the agent stops a `<task-notification>` naming that id
/// is queued for the session. Only what is written after the process started
/// is read — an agent from before then went with the process that ran it,
/// whatever the transcript says.
final class AgentLedger {
    private let sessionID: String
    private var transcript: URL?
    private var offset: UInt64 = 0
    /// The end of the last read, when it stopped partway through a line.
    private var carry = Data()
    private var lookedFor: Date?
    /// Agents started and not reported done, with when this ledger saw them
    /// start.
    private var running: [String: Date] = [:]

    /// An agent stopped from the task list may leave no notice behind. One
    /// whose own transcript has been quiet this long, with no command running
    /// that it could be waiting on, is taken to be gone.
    private static let quietLimit: TimeInterval = 20 * 60

    private static let blob = Data("{\"type\":\"api-request-blob\"".utf8)
    private static let notice = Data("<task-notification>".utf8)
    private static let launched = Data("\"async_launched\"".utf8)
    private static let resumed = Data("\"resumedAgentId\"".utf8)
    private static let stopped = Data("\"task_type\"".utf8)
    private static let taskID = try! NSRegularExpression(pattern: "<task-id>([^<]+)</task-id>")

    /// Call before the session's process starts, so nothing it writes is
    /// skipped.
    init(sessionID: String) {
        self.sessionID = sessionID
        // A transcript that is already there belongs to an earlier process:
        // read on from where it ends. One that appears later is all this one's.
        transcript = TerminalManager.transcriptURL(for: sessionID)
        offset = transcript.flatMap(Self.size) ?? 0
    }

    /// The agents still out. Reads what the session wrote since the last call.
    func agentsRunning(shellsRunning: Bool, now: Date = Date()) -> Int {
        update()
        for (id, started) in running where !shellsRunning {
            let lastSign = [started, writtenAt(agent: id)].compactMap { $0 }.max() ?? started
            if now.timeIntervalSince(lastSign) > Self.quietLimit { running[id] = nil }
        }
        return running.count
    }

    private func update() {
        if transcript == nil {
            // A new session has no file until its first message; look again
            // now and then rather than on every beat.
            if let last = lookedFor, Date().timeIntervalSince(last) < 5 { return }
            lookedFor = Date()
            transcript = TerminalManager.transcriptURL(for: sessionID)
        }
        guard let url = transcript, let size = Self.size(url) else { return }
        if size < offset {
            // Rewritten under us: whatever it says now is not news.
            offset = size
            carry = Data()
            return
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
        offset += UInt64(chunk.count)

        var data = carry
        data.append(chunk)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        carry = Data(lines.removeLast())
        for line in lines where !line.isEmpty { read(line) }
    }

    private func read(_ line: Data) {
        // A copy of a request sent earlier, old notices and all.
        if line.starts(with: Self.blob) { return }
        if line.range(of: Self.notice) != nil { return noteFinished(line) }
        guard line.range(of: Self.launched) != nil
            || line.range(of: Self.resumed) != nil
            || line.range(of: Self.stopped) != nil,
              let entry = Self.json(line),
              entry["type"] as? String == "user",
              let result = entry["toolUseResult"] as? [String: Any] else { return }

        if result["status"] as? String == "async_launched", let id = result["agentId"] as? String {
            running[id] = Date()
        } else if let id = result["resumedAgentId"] as? String {
            // Sent another message after it finished: it is working again.
            running[id] = Date()
        } else if result["task_type"] != nil, let id = result["task_id"] as? String {
            // TaskStop.
            running[id] = nil
        }
    }

    /// A notice that an agent stopped — or a command, or a monitor's event,
    /// which name ids this ledger does not hold and so change nothing.
    private func noteFinished(_ line: Data) {
        guard let entry = Self.json(line) else { return }
        let type = entry["type"] as? String
        let origin = (entry["origin"] as? [String: Any])?["kind"] as? String
        // The queued notice itself, not a command output or a file that
        // happens to quote one.
        guard type == "queue-operation" || type == "attachment"
                || (type == "user" && origin == "task-notification"),
              let text = String(data: line, encoding: .utf8),
              text.contains("<status>") else { return }
        let range = NSRange(text.startIndex..., in: text)
        for match in Self.taskID.matches(in: text, range: range) {
            guard let id = Range(match.range(at: 1), in: text) else { continue }
            running[String(text[id])] = nil
        }
    }

    /// When the agent last wrote to its own transcript, which it does as it
    /// works.
    private func writtenAt(agent id: String) -> Date? {
        guard let transcript else { return nil }
        let file = transcript.deletingPathExtension()
            .appendingPathComponent("subagents")
            .appendingPathComponent("agent-\(id).jsonl")
        return (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func size(_ url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value
    }

    private static func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}

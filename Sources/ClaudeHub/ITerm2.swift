import AppKit

/// "Open in iTerm2": bring forward the iTerm2 session already running this
/// conversation, or start one in a new tab.
///
/// This drives iTerm2 with AppleScript, so macOS asks once for permission to
/// control iTerm2. Refusing it turns into an error message, not silence.
enum ITerm2 {
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
    }

    static var isInstalled: Bool { appURL != nil }

    /// Runs off the main thread; `done` gets an error message, or nil, on main.
    static func open(_ session: ClaudeSession, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tty = liveTTY(of: session.id)
            let command = "cd \(ClaudeSession.shellQuote(session.cwd)) && claude --resume \(ClaudeSession.shellQuote(session.id))"
            let error = run(script(focusing: tty, orRunning: command))
            DispatchQueue.main.async { done(error) }
        }
    }

    // MARK: - Finding the running conversation

    /// The terminal device of a live `claude` process on this conversation,
    /// like "/dev/ttys003". Claude Code writes `~/.claude/sessions/<pid>.json`
    /// for each running CLI, naming the conversation it is in — which also
    /// catches one that got there through `/resume` rather than `--resume`.
    static func liveTTY(of sessionID: String) -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  info["sessionId"] as? String == sessionID,
                  let pid = (info["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0,
                  let tty = tty(of: pid) else { continue }
            return tty
        }
        return nil
    }

    private static func tty(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let name = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name != "??" else { return nil }
        return "/dev/" + name
    }

    // MARK: - AppleScript

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func script(focusing tty: String?, orRunning command: String) -> String {
        let find = tty.map { tty in
            """
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(quote(tty)) then
                                select w
                                select t
                                select s
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            """
        } ?? ""
        return """
        tell application id "com.googlecode.iterm2"
        \(find)
            activate
            if (count of windows) is 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window to write text \(quote(command))
        end tell
        """
    }

    private static func run(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if message.contains("-1743") {
            return "ClaudeHub is not allowed to control iTerm2. Turn it on in System Settings → Privacy & Security → Automation."
        }
        return message.isEmpty ? "iTerm2 did not respond." : message
    }
}

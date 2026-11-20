import Cocoa
import Foundation

final class TargetDiscoveryService {
    static let knownAgentCLIProcesses: Set<String> = [
        "claude", "agy", "codex", "gemini", "aider", "goose", "opencode", "amp"
    ]

    static let knownAIConsumerAppKeywords: [String] = [
        "claude", "antigravity", "cursor", "visual studio code", "code", "windsurf",
        "chatgpt", "ghostty", "iterm", "warp", "zed"
    ]

    private static let queue = DispatchQueue(label: "com.tanishkyadav.agent-nudge.discovery", qos: .userInitiated)

    private struct TerminalTabInfo: Decodable {
        let windowId: Int
        let tabIndex: Int
        let tty: String
        let title: String
        let busy: Bool
    }

    private struct ProcessEntry {
        let shortTty: String
        let pid: Int
        let detectedAgentName: String?
    }

    static func discoverTargets(completion: @escaping ([AgentTarget]) -> Void) {
        queue.async {
            let targets = discoverTargetsSync()
            DispatchQueue.main.async {
                completion(targets)
            }
        }
    }

    static func discoverTargetsSync() -> [AgentTarget] {
        var agentTerminalTargets: [AgentTarget] = []
        var otherTerminalTargets: [AgentTarget] = []

        if isTerminalRunning() {
            let tabs = fetchTerminalTabs()
            if !tabs.isEmpty {
                let shortTtys = tabs.map { normalizeShortTty($0.tty) }.filter { !$0.isEmpty }
                let processes = fetchProcessesByTTY(shortTtys: shortTtys)
                var agentPIDs: [Int] = []
                var bestAgentByShortTty: [String: ProcessEntry] = [:]

                for tab in tabs {
                    let shortTty = normalizeShortTty(tab.tty)
                    if let entries = processes[shortTty] {
                        if let match = entries.last(where: { $0.detectedAgentName != nil }) {
                            bestAgentByShortTty[shortTty] = match
                            agentPIDs.append(match.pid)
                        }
                    }
                }

                let cwdMap = agentPIDs.isEmpty ? [:] : fetchWorkingDirectories(pids: agentPIDs)

                for tab in tabs {
                    let shortTty = normalizeShortTty(tab.tty)
                    let cleanTitle = sanitizeTitle(tab.title, fallback: "Terminal")

                    if let agentEntry = bestAgentByShortTty[shortTty],
                       let agentName = agentEntry.detectedAgentName {
                        let cwdName = cwdMap[agentEntry.pid].map { URL(fileURLWithPath: $0).lastPathComponent }
                        let displayName: String
                        if let cwdName = cwdName, !cwdName.isEmpty, cwdName != "/" {
                            displayName = "\(agentName) · \(cwdName)"
                        } else {
                            displayName = agentName
                        }
                        let subtitle = "\(cleanTitle) (\(shortTty))"
                        agentTerminalTargets.append(
                            AgentTarget(
                                id: "tty:\(tab.tty)",
                                kind: .terminalTab,
                                displayName: displayName,
                                subtitle: subtitle,
                                isDetectedAgent: true,
                                tty: tab.tty,
                                windowId: tab.windowId,
                                bundleIdentifier: "com.apple.Terminal",
                                appName: "Terminal"
                            )
                        )
                    } else {
                        otherTerminalTargets.append(
                            AgentTarget(
                                id: "tty:\(tab.tty)",
                                kind: .terminalTab,
                                displayName: "Terminal · \(cleanTitle)",
                                subtitle: shortTty,
                                isDetectedAgent: false,
                                tty: tab.tty,
                                windowId: tab.windowId,
                                bundleIdentifier: "com.apple.Terminal",
                                appName: "Terminal"
                            )
                        )
                    }
                }
            }
        }

        let appTargets = discoverRunningGUIApps()

        var combined: [AgentTarget] = []
        combined.append(contentsOf: agentTerminalTargets)
        combined.append(contentsOf: otherTerminalTargets)
        combined.append(contentsOf: appTargets)
        combined.append(AgentTarget.frontmostWindow)
        return combined
    }

    static func isTerminalRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Terminal"
        }
    }

    private static func discoverRunningGUIApps() -> [AgentTarget] {
        let selfBundleID = Bundle.main.bundleIdentifier
        var aiApps: [AgentTarget] = []
        var otherApps: [AgentTarget] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleID = app.bundleIdentifier else { continue }
            if bundleID == selfBundleID || bundleID == "com.apple.Terminal" { continue }

            let name = app.localizedName ?? bundleID
            let lower = name.lowercased()
            let isLikelyAI = knownAIConsumerAppKeywords.contains { lower.contains($0) }

            let target = AgentTarget(
                id: "app:\(bundleID)",
                kind: .macApp,
                displayName: name,
                subtitle: bundleID,
                isDetectedAgent: isLikelyAI,
                tty: nil,
                windowId: nil,
                bundleIdentifier: bundleID,
                appName: name
            )

            if isLikelyAI {
                aiApps.append(target)
            } else {
                otherApps.append(target)
            }
        }

        aiApps.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        otherApps.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return aiApps + otherApps
    }

    private static func fetchTerminalTabs() -> [TerminalTabInfo] {
        let script = """
        const term = Application("Terminal");
        const out = [];
        if (term.running()) {
          const wins = term.windows();
          for (let i = 0; i < wins.length; i++) {
            const w = wins[i];
            const wid = w.id();
            const wName = w.name();
            const tabs = w.tabs();
            for (let j = 0; j < tabs.length; j++) {
              const t = tabs[j];
              out.push({
                windowId: wid,
                tabIndex: j + 1,
                tty: t.tty(),
                title: t.customTitle() || wName || "Terminal",
                busy: t.busy()
              });
            }
          }
        }
        JSON.stringify(out);
        """

        guard let output = runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", script],
            timeout: 3.0
        ) else {
            return []
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TerminalTabInfo].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func fetchProcessesByTTY(shortTtys: [String]) -> [String: [ProcessEntry]] {
        let uniqueTtys = Array(Set(shortTtys))
        guard !uniqueTtys.isEmpty else { return [:] }
        let ttyArg = uniqueTtys.joined(separator: ",")

        guard let output = runProcess(
            executable: "/bin/ps",
            arguments: ["-t", ttyArg, "-o", "tty=,pid=,args="],
            timeout: 3.0
        ) else {
            return [:]
        }

        let wrapperRuntimes: Set<String> = ["node", "bun", "deno", "python", "python3", "env", "npx"]
        var map: [String: [ProcessEntry]] = [:]

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3 else { continue }

            let shortTty = normalizeShortTty(String(parts[0]))
            if shortTty == "??" || shortTty == "?" || shortTty.isEmpty { continue }
            guard let pid = Int(parts[1]) else { continue }

            let argTokens = parts[2].split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let firstToken = argTokens.first else { continue }
            let firstBase = URL(fileURLWithPath: firstToken).lastPathComponent.lowercased()

            var matchedAgent: String?
            if knownAgentCLIProcesses.contains(firstBase) {
                matchedAgent = firstBase
            } else if wrapperRuntimes.contains(firstBase) && argTokens.count >= 2 {
                let secondBase = URL(fileURLWithPath: argTokens[1]).lastPathComponent.lowercased()
                if knownAgentCLIProcesses.contains(secondBase) {
                    matchedAgent = secondBase
                }
            }

            let entry = ProcessEntry(
                shortTty: shortTty,
                pid: pid,
                detectedAgentName: matchedAgent
            )
            map[shortTty, default: []].append(entry)
        }
        return map
    }

    private static func fetchWorkingDirectories(pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = runProcess(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", pidList, "-d", "cwd", "-Fn"],
            timeout: 3.0
        ) else {
            return [:]
        }

        var result: [Int: String] = [:]
        var currentPid: Int?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("p") {
                currentPid = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    private static func normalizeShortTty(_ tty: String) -> String {
        if tty.hasPrefix("/dev/") {
            return String(tty.dropFirst(5))
        }
        return tty
    }

    private static func sanitizeTitle(_ raw: String, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return fallback
        }
        if cleaned.count > 42 {
            let idx = cleaned.index(cleaned.startIndex, offsetBy: 42)
            return String(cleaned[..<idx]) + "…"
        }
        return cleaned
    }

    private final class PipeDataBox: @unchecked Sendable {
        var data = Data()
    }

    @discardableResult
    static func runProcess(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout & stderr concurrently so processes emitting >64KB never deadlock the pipe buffer
        let outGroup = DispatchGroup()
        let stdoutBox = PipeDataBox()
        let stderrBox = PipeDataBox()

        outGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }

        outGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            _ = outGroup.wait(timeout: .now() + 0.5)
            return nil
        }

        _ = outGroup.wait(timeout: .now() + 1.0)
        guard process.terminationStatus == 0 else { return nil }
        return String(data: stdoutBox.data, encoding: .utf8)
    }
}

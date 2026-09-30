import Foundation

// Owns one official stdio app-server. It does not inspect unrelated CLI sessions.
@MainActor
final class CodexAdapter {
    static let shared = CodexAdapter()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var approvals: [String: Any] = [:]
    private var proposals: [String: String] = [:]
    private var threadID: String?
    private var turnID: String?
    private var initialPrompt = ""
    private var workspace = ""

    func start(binary: String, cwd: String, prompt: String) {
        #if APPSTORE
        fail("Codex child processes are unavailable in the App Store sandbox.")
        #else
        guard process == nil else { fail("Stop the current Codex session first."); return }
        guard binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary),
              cwd.hasPrefix("/"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("Choose an absolute Codex executable, project folder and prompt in Settings."); return
        }
        workspace = cwd; initialPrompt = prompt
        let proc = Process(); let stdin = Pipe(); let stdout = Pipe()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["app-server"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in
                if data.isEmpty { self?.stop() } else { self?.receive(data) }
            }
        }
        do {
            try proc.run(); process = proc
            request("initialize", ["clientInfo": ["name": "coucou", "title": "Coucou", "version": "0.1.1"]]) { [weak self] result in
                guard let self else { return }
                guard case .success = result else { self.fail("Codex initialization failed. Check installation and authentication."); self.stop(); return }
                self.send(["method": "initialized", "params": [:]])
                self.request("thread/start", ["cwd": self.workspace, "sandbox": "readOnly", "approvalPolicy": "untrusted"]) { [weak self] result in
                    guard let self else { return }
                    guard case .success(let value) = result, let thread = value["thread"] as? [String: Any], let id = thread["id"] as? String else {
                        self.fail("Codex thread failed. Sign in using codex login in your terminal."); self.stop(); return
                    }
                    self.threadID = id
                    self.emit(.sessionStarted, "Codex: \(id)")
                    self.request("turn/start", ["threadId": id, "input": [["type": "text", "text": self.initialPrompt]]]) { [weak self] result in
                        if case .failure = result { self?.fail("Codex turn failed. Check installation and authentication.") }
                    }
                }
            }
        } catch { stop(); fail("Codex could not start. Check the executable and project folder.") }
        #endif
    }

    func stop() {
        approvals.removeAll(); callbacks.removeAll(); proposals.removeAll()
        process?.terminate(); process = nil; input = nil; buffer = Data()
        if threadID != nil { emit(.sessionEnded, "Codex stopped") }
        threadID = nil; turnID = nil
        let state = AppState.shared
        if state.pendingApproval?.provider == "codex" { state.pendingApproval = nil; state.isPinned = false }
    }

    func decide(_ decision: String, requestID: String) {
        guard let id = approvals.removeValue(forKey: requestID), AppState.shared.pendingApproval?.requestID == requestID else { return }
        send(["id": id, "result": ["decision": decision == "allow" ? "accept" : "decline"]])
        AppState.shared.pendingApproval = nil; AppState.shared.isPinned = false
        emit(.statusChanged, "Codex working")
        AppState.shared.view = .overview
    }

    private func request(_ method: String, _ params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        sequence += 1; callbacks[sequence] = completion
        send(["id": sequence, "method": method, "params": params])
        let id = sequence
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if let callback = self?.callbacks.removeValue(forKey: id) { callback(.failure(OpenAIError.message("Codex timeout."))) }
        }
    }

    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let input else { return }
        do { try input.write(contentsOf: data + Data([10])) } catch { fail("Codex connection closed.") }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 4_000_000 else { stop(); fail("Codex event exceeded the size limit."); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if message["method"] == nil, let id = message["id"] as? Int, let callback = callbacks.removeValue(forKey: id) {
                if message["error"] != nil { callback(.failure(OpenAIError.message("Codex request failed."))) }
                else { callback(.success(message["result"] as? [String: Any] ?? [:])) }
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let p = message["params"] as? [String: Any] ?? [:]
        if let incoming = p["threadId"] as? String, let threadID, incoming != threadID { return }
        if method == "turn/started" { turnID = (p["turn"] as? [String: Any])?["id"] as? String; emit(.statusChanged, "Codex working") }
        if method == "turn/completed" {
            let turn = p["turn"] as? [String: Any] ?? [:]
            emit(turn["status"] as? String == "failed" ? .agentFailed : .agentCompleted, "Codex turn \(turn["status"] as? String ?? "ended")")
            approvals.removeAll(); turnID = nil
            if AppState.shared.pendingApproval?.provider == "codex" { AppState.shared.pendingApproval = nil; AppState.shared.isPinned = false }
        }
        if method == "item/started" || method == "item/completed" {
            let item = p["item"] as? [String: Any] ?? [:]
            let completed = method == "item/completed"
            let type = item["type"] as? String ?? "tool"
            if type == "commandExecution" { emit(completed ? .commandCompleted : .commandStarted, item["command"] as? String ?? "Command") }
            else if type == "fileChange" {
                let changes = item["changes"] as? [[String: Any]] ?? []
                let preview = changes.map { "\($0["path"] as? String ?? "File")\n\($0["diff"] as? String ?? "")" }.joined(separator: "\n")
                if let id = item["id"] as? String { proposals[id] = String(preview.prefix(20000)) }
                emit(completed ? .fileModified : .toolStarted, changes.compactMap { $0["path"] as? String }.joined(separator: ", "))
            } else if type == "agentMessage", completed { emit(.toolCompleted, String((item["text"] as? String ?? "Codex response").prefix(300))) }
            else { emit(completed ? .toolCompleted : .toolStarted, type) }
        }
        if method == "serverRequest/resolved", let id = p["requestId"] {
            let key = String(describing: id); approvals.removeValue(forKey: key)
            if AppState.shared.pendingApproval?.requestID == key { AppState.shared.pendingApproval = nil; AppState.shared.isPinned = false }
        }
        guard let id = message["id"] else { return }
        let key = String(describing: id)
        guard ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) else {
            // Unknown server requests never gain consent or invoke local tools.
            send(["id": id, "error": ["code": -32601, "message": "Unsupported client request"]]); return
        }
        let state = AppState.shared
        guard p["threadId"] as? String == threadID, p["turnId"] as? String == turnID, state.pendingApproval == nil, state.isPresent else {
            send(["id": id, "result": ["decision": "decline"]]); return
        }
        let network = p["networkApprovalContext"] as? [String: Any]
        let preview = network.map { "Network access: \($0["protocol"] as? String ?? "")://\($0["host"] as? String ?? "")" }
            ?? p["command"] as? String ?? proposals[p["itemId"] as? String ?? ""] ?? p["reason"] as? String ?? "Codex file change"
        approvals[key] = id
        state.pendingApproval = ApprovalInfo(sessionId: threadID ?? "", tool: "Codex", command: preview, provider: "codex", requestID: key)
        state.isPinned = true; state.focusId = "integration_codex"; state.view = .approval
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval)
        emit(.permissionRequested, preview)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(110))
            if self?.approvals[key] != nil { self?.decide("deny", requestID: key) }
        }
    }

    private func fail(_ message: String) { emit(.agentFailed, message); AppState.shared.noteMessage = message; AppState.shared.view = .note }
    private func emit(_ kind: AgentEventKind, _ detail: String) {
        let state = AppState.shared
        state.lastAgentEvent = AgentEvent(provider: "codex", session: threadID ?? "", kind: kind, detail: detail)
        if !state.tasks.contains(where: { $0.id == "integration_codex" }) {
            state.tasks.append(AgentTask(id: "integration_codex", name: "Codex", color: "#10A37F", state: .idle, steps: [], source: .codex, isIntegration: true))
        }
        let status: BotState = kind == .agentFailed ? .error : kind == .agentCompleted ? .finished : kind == .permissionRequested ? .approval : kind == .sessionEnded ? .idle : .working
        state.updateTask(id: "integration_codex", state: status)
        if state.mode == .hidden && state.isPresent { NotificationCenter.default.post(name: .hookReveal, object: nil) }
        if let index = state.tasks.firstIndex(where: { $0.id == "integration_codex" }) {
            state.tasks[index].steps.append("Codex · \(kind.rawValue): \(String(detail.prefix(300)))")
            state.tasks[index].steps = Array(state.tasks[index].steps.suffix(20))
        }
    }
}

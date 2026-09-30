import Foundation
import AppKit
import ApplicationServices

@MainActor protocol ComputerExecutor {
    func execute(_ action: [String: Any]) async throws
    func screenshot() async throws -> String
}

enum ComputerUse {
    static let supported = ["screenshot", "wait", "move", "click", "double_click", "scroll", "type", "keypress", "drag"]
    static func parse(_ call: [String: Any]) throws -> [[String: Any]] {
        guard call["type"] as? String == "computer_call", let actions = call["actions"] as? [[String: Any]], !actions.isEmpty, actions.count <= 20 else { throw OpenAIError.message("Invalid computer call.") }
        for action in actions {
            guard let type = action["type"] as? String, supported.contains(type), SecretRedaction.text(String(describing: action)) == String(describing: action) else { throw OpenAIError.message("Unsupported or sensitive computer action.") }
            if type == "type" { guard let text = action["text"] as? String, !text.isEmpty, text.count <= 2000 else { throw OpenAIError.message("Computer text exceeds the limit.") } }
            if type == "keypress" { guard let keys = action["keys"] as? [String], keys.count <= 4, keys.allSatisfy({ ["ENTER", "TAB", "ESC", "ESCAPE", "BACKSPACE", "ARROWUP", "ARROWDOWN", "ARROWLEFT", "ARROWRIGHT"].contains($0.uppercased()) }) else { throw OpenAIError.message("Credential/clipboard shortcuts and unknown keys are blocked.") } }
        }
        return actions
    }
    @MainActor static func handle(_ call: [String: Any], executor: any ComputerExecutor, approvals: ActionApprovalCenter = .shared) async throws -> [String: Any] {
        let actions = try parse(call)
        guard let id = call["call_id"] as? String, OpenAIService.safeID(id) else { throw OpenAIError.message("Invalid computer call identifier.") }
        let checks = call["pending_safety_checks"] as? [[String: Any]] ?? []
        if !checks.isEmpty {
            let request = ActionRequest(id: id + "-safety", provider: "openai", integration: "computer", operation: "safety_checks", parameters: ["checks": checks], risk: .critical)
            guard await approvals.authorize(request) else { throw OpenAIError.message("Computer safety check denied.") }
        }
        for (index, action) in actions.enumerated() {
            let type = action["type"] as! String
            if type == "screenshot" { continue }
            let request = ActionRequest(id: id + "-" + String(index), provider: "openai", integration: "computer", operation: type, parameters: action, risk: ActionRiskEvaluator.risk(integration: "computer", operation: type))
            guard await approvals.authorize(request), approvals.claimExecution(request.id) else { throw OpenAIError.message("Computer action denied or expired; run stopped.") }
            try Task.checkCancellation()
            do { try await executor.execute(action); approvals.record(request, outcome: "success") }
            catch { approvals.record(request, outcome: "failure"); throw error }
        }
        let capture = ActionRequest(id: id + "-capture", provider: "openai", integration: "computer", operation: "screenshot", parameters: ["effect": "Transmit the primary display screenshot to OpenAI. Check that no credentials or sensitive windows are visible."], risk: .critical)
        guard await approvals.authorize(capture), approvals.claimExecution(capture.id) else { throw OpenAIError.message("Screenshot transmission denied; run stopped.") }
        let image: String
        do { image = try await executor.screenshot(); approvals.record(capture, outcome: "success") }
        catch { approvals.record(capture, outcome: "failure"); throw error }
        var result: [String: Any] = ["type": "computer_call_output", "call_id": id, "output": ["type": "computer_screenshot", "image_url": "data:image/png;base64," + image, "detail": "original"]]
        if !checks.isEmpty { result["acknowledged_safety_checks"] = checks }
        return result
    }
}

struct MacComputerExecutor: ComputerExecutor {
    let target: String
    @MainActor private func focus() async throws {
        #if APPSTORE
        throw OpenAIError.message("Desktop Computer Use is unavailable in the App Store sandbox.")
        #else
        guard ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac"].contains(target), AXIsProcessTrusted(), let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == target }) else { throw OpenAIError.message("Open the configured browser and grant Accessibility permission in System Settings.") }
        app.activate(options: .activateAllWindows)
        try await Task.sleep(for: .milliseconds(350))
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target else { throw OpenAIError.message("Computer target is not focused; action blocked.") }
        let system = AXUIElementCreateSystemWide(); var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused {
            let element = unsafeBitCast(focused, to: AXUIElement.self); var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == "AXSecureTextField" { throw OpenAIError.message("Password fields cannot be controlled.") }
        }
        #endif
    }
    @MainActor func execute(_ action: [String: Any]) async throws {
        let type = action["type"] as! String
        if type == "wait" { try await Task.sleep(for: .milliseconds(500)); return }
        if type == "screenshot" { return } // Capture occurs once after the batch and explicit transmission approval.
        try await focus()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        func point(_ a: [String: Any]) throws -> CGPoint {
            guard let x = a["x"] as? Double, let y = a["y"] as? Double, x >= 0, y >= 0, x < Double(CGDisplayPixelsWide(CGMainDisplayID())), y < Double(CGDisplayPixelsHigh(CGMainDisplayID())) else { throw OpenAIError.message("Computer coordinates outside primary display.") }
            return CGPoint(x: x * bounds.width / Double(CGDisplayPixelsWide(CGMainDisplayID())), y: y * bounds.height / Double(CGDisplayPixelsHigh(CGMainDisplayID())))
        }
        if ["move", "click", "double_click"].contains(type) {
            let p = try point(action)
            if type == "move" { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
            else {
                guard ["left", "right"].contains(action["button"] as? String ?? "left") else { throw OpenAIError.message("Unsupported mouse button.") }
                let right = action["button"] as? String == "right"
                for _ in 0..<(type == "double_click" ? 2 : 1) {
                    CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: p, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
                    CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: p, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
                }
            }
        } else if type == "type" {
            let units = Array((action["text"] as? String ?? "").utf16)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { throw OpenAIError.message("Keyboard unavailable.") }
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!) }
            event.post(tap: .cghidEventTap)
        } else if type == "keypress" {
            let codes: [String: CGKeyCode] = ["ENTER":36,"TAB":48,"ESC":53,"ESCAPE":53,"BACKSPACE":51,"ARROWUP":126,"ARROWDOWN":125,"ARROWLEFT":123,"ARROWRIGHT":124]
            for key in action["keys"] as? [String] ?? [] { guard let code = codes[key.uppercased()] else { throw OpenAIError.message("Unsupported key.") }; CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap) }
        } else if type == "scroll" {
            let x = max(-2000, min(2000, action["scroll_x"] as? Int ?? 0)), y = max(-2000, min(2000, action["scroll_y"] as? Int ?? 0))
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-y), wheel2: Int32(-x), wheel3: 0)?.post(tap: .cghidEventTap)
        } else if type == "drag" {
            guard let path = action["path"] as? [[String: Any]], (2...50).contains(path.count) else { throw OpenAIError.message("Invalid drag path.") }
            let points = try path.map(point)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: points[0], mouseButton: .left)?.post(tap: .cghidEventTap)
            for p in points.dropFirst() { CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: points.last!, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else { throw OpenAIError.message("Unsupported computer action.") }
    }
    @MainActor func screenshot() async throws -> String {
        #if APPSTORE
        throw OpenAIError.message("Screen capture unavailable in the App Store sandbox.")
        #else
        guard CGPreflightScreenCaptureAccess() else { throw OpenAIError.message("Grant Screen Recording permission in System Settings.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); process.arguments = ["-x", "-D", "1", "-t", "png", url.path]
        process.standardError = FileHandle.nullDevice; try process.run()
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate(); throw OpenAIError.message("Screen capture timed out.") }
        guard process.terminationStatus == 0, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else { throw OpenAIError.message("Screen capture failed or exceeds 20 MB.") }
        return try Data(contentsOf: url).base64EncodedString()
        #endif
    }
}

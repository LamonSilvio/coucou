import XCTest
@testable import Coucou

@MainActor
final class ProviderTests: XCTestCase {
    func testProviderSelection() {
        XCTAssertEqual(AIProviderID.resolve(.auto, anthropic: true, openai: true), .anthropic)
        XCTAssertEqual(AIProviderID.resolve(.auto, anthropic: false, openai: true), .openai)
        XCTAssertEqual(AIProviderID.resolve(.openai, anthropic: true, openai: false), .openai)
    }
    func testClaudeAdapter() {
        XCTAssertEqual(ClaudeCodeAdapter.event("PreToolUse", session: "s", tool: "Read")?.kind, .fileRead)
        XCTAssertEqual(ClaudeCodeAdapter.event("PreToolUse", session: "s", tool: "Edit")?.kind, .fileModified)
        XCTAssertEqual(ClaudeCodeAdapter.event("PermissionRequest", session: "s")?.kind, .permissionRequested)
        XCTAssertNil(ClaudeCodeAdapter.event("fakeApproval", session: "s"))
    }
    func testPermissionPolicy() {
        XCTAssertTrue(ToolPermission(level: .safe).permits(explicitConfirmation: false))
        XCTAssertFalse(ToolPermission(level: .confirm).permits(explicitConfirmation: false))
        XCTAssertFalse(ToolPermission(level: .critical).permits(explicitConfirmation: false))
        XCTAssertTrue(ToolPermission(level: .critical).permits(explicitConfirmation: true))
    }
    func testFileInput() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(try OpenAIService.fileBlock(url, name: "note.txt", vision: false)["type"] as? String, "input_text")
        try Data(repeating: 0, count: 200001).write(to: url)
        XCTAssertThrowsError(try OpenAIService.fileBlock(url, name: "note.txt", vision: false))
    }
    func testPDFRequiresVision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("%PDF-1.4".utf8).write(to: url)
        XCTAssertThrowsError(try OpenAIService.fileBlock(url, name: "file.pdf", vision: false))
        XCTAssertEqual(try OpenAIService.fileBlock(url, name: "file.pdf", vision: true)["type"] as? String,"input_file")
    }
    func testSafeErrors() {
        XCTAssertTrue(OpenAIError.http(401).localizedDescription.contains("authentication"))
        XCTAssertTrue(OpenAIError.http(429).localizedDescription.contains("quota"))
    }
    func testSecureStorageRoundTrip() {
        let account = "coucou-test-" + UUID().uuidString
        defer { Keychain.delete(key: account) }
        Keychain.save(key: account, value: "unit-test-value")
        XCTAssertEqual(Keychain.load(key: account), "unit-test-value")
        Keychain.delete(key: account)
        XCTAssertNil(Keychain.load(key: account))
    }
    func testMultiTurnAndRollback() async throws {
        let suite = "coucou-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var bodies: [[String: Any]] = []
        let service = OpenAIService(settings: defaults, keyProvider: { "unit-test-credential" }, transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            bodies.append(body)
            let payload = bodies.count == 3 ? "{}" : "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}]}"
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let state = AppState.shared
        await service.chat(query: "first", context: nil, state: state)
        XCTAssertEqual(service.history.count, 2)
        await service.chat(query: "second", context: nil, state: state)
        XCTAssertEqual(service.history.count, 4)
        XCTAssertEqual((bodies[1]["input"] as? [[String:Any]])?.count, 3)
        XCTAssertEqual(bodies[0]["store"] as? Bool, false)
        await service.chat(query: "failure", context: nil, state: state)
        XCTAssertEqual(service.history.count, 4)
        service.clearConversation()
        XCTAssertTrue(service.history.isEmpty)
    }
    func testModelCapabilityRejectedBeforeNetwork() async {
        let suite = "coucou-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown-model", forKey: "openaiModel")
        defaults.set(true, forKey: "openaiWebSearch")
        var called = false
        let service = OpenAIService(settings: defaults, keyProvider: { "unit-test-credential" }, transport: { request in
            called = true
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await service.chat(query: "test", context: nil, state: AppState.shared)
        XCTAssertFalse(called)
        XCTAssertTrue(service.history.isEmpty)
    }

}

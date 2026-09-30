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
}

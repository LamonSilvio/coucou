import XCTest
@testable import Coucou

@MainActor
final class CodexTransportTests: XCTestCase {
    func testOfficialThreadPolicyAndStaleTurn() {
        XCTAssertEqual(CodexProtocol.threadParameters(cwd: "/tmp")["approvalPolicy"] as? String, "unlessTrusted")
        XCTAssertFalse(CodexProtocol.acceptsEvent(thread: "thread", turn: "current", params: ["threadId":"thread", "turn":["id":"old"]]))
        XCTAssertTrue(CodexProtocol.acceptsEvent(thread: "thread", turn: "current", params: ["threadId":"thread", "turnId":"current"]))
    }

    func testNativeProcessHandshakeQueueDecisionsAndEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-codex-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("fake-codex")
        // This process never calls a network/API or executes model-supplied commands.
        let script = #"""
#!/usr/bin/env python3
import json, sys, time
assert sys.argv[1:] == ['app-server']
def read():
    return json.loads(sys.stdin.readline())
def send(value):
    raw = json.dumps(value) + '\n'
    sys.stdout.write(raw[:8]); sys.stdout.flush()
    time.sleep(0.01)
    sys.stdout.write(raw[8:]); sys.stdout.flush()
init = read(); assert init['method'] == 'initialize'
send({'id':init['id'], 'result':{}})
assert read()['method'] == 'initialized'
thread = read(); assert thread['method'] == 'thread/start'
assert thread['params']['sandbox'] == 'readOnly'
assert thread['params']['approvalPolicy'] == 'unlessTrusted'
send({'id':thread['id'], 'result':{'thread':{'id':'test-thread'}}})
turn = read(); assert turn['method'] == 'turn/start'
send({'id':turn['id'], 'result':{'turn':{'id':'test-turn'}}})
# Approval before turn/started verifies that the turn/start result establishes scope.
params = {'threadId':'test-thread','turnId':'test-turn','command':'synthetic command'}
send({'method':'turn/completed','params':{'threadId':'test-thread','turn':{'id':'stale-turn','status':'completed'}}})
send({'id':'foreign','method':'item/commandExecution/requestApproval','params':dict(params,threadId='wrong-thread')})
send({'id':'unsupported','method':'unknown/client/request','params':params})
assert read()['result']['decision'] == 'decline'
assert read()['error']['code'] == -32601
for ident in ['allow-once','deny-once','allow-once']:
    send({'id':ident,'method':'item/commandExecution/requestApproval','params':params})
responses = [read(), read()]
assert {r['id']:r['result']['decision'] for r in responses} == {'allow-once':'accept','deny-once':'decline'}
send({'method':'item/started','params':{'threadId':'test-thread','turnId':'test-turn','item':{'type':'commandExecution','command':'synthetic command'}}})
send({'method':'item/completed','params':{'threadId':'test-thread','turnId':'test-turn','item':{'type':'commandExecution','command':'synthetic command'}}})
send({'method':'turn/completed','params':{'threadId':'test-thread','turn':{'id':'test-turn','status':'completed'}}})
with open('verified.json','w') as result:
    json.dump({'decisions':responses},result)
sys.stdin.readline()
"""#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var shown: [String] = [], events: [AgentEvent] = []
        var center: ActionApprovalCenter!
        center = ActionApprovalCenter(present: { action in
            if !shown.contains(action.id) {
                shown.append(action.id)
                Task { @MainActor in
                    center.resolve(action.id, allow: action.id.hasSuffix("allow-once"))
                    center.resolve(action.id, allow: true) // Stale/double click has no second wire effect.
                }
            }
        }, available: { true }, clear: { _ in AppState.shared.pendingApproval = nil }, audit: { _,_ in })
        let adapter = CodexAdapter(approvals: center, onEvent: { events.append($0) })
        defer { adapter.stop(); center.cancelAll(); try? FileManager.default.removeItem(at: directory) }
        adapter.start(binary: binary.path, cwd: directory.path, prompt: "Synthetic fixture only")
        let resultURL = directory.appendingPathComponent("verified.json")
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: resultURL.path), events.contains(where: { $0.kind == .agentCompleted }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Fake app-server did not verify the production transport")
        XCTAssertEqual(shown.count, 2)
        XCTAssertTrue(center.queue.isEmpty)
        XCTAssertEqual(events.filter { $0.kind == .agentCompleted }.count, 1)
        for kind in [AgentEventKind.sessionStarted, .commandStarted, .commandCompleted, .permissionRequested] {
            XCTAssertTrue(events.contains { $0.kind == kind })
        }
        adapter.stop()
        XCTAssertEqual(events.last?.kind, .sessionEnded)
    }
}

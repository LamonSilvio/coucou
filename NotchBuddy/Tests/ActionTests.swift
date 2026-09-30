import XCTest
import AppKit
@testable import Coucou

@MainActor
final class ActionTests: XCTestCase {
    func action(_ id: String = UUID().uuidString, _ integration: String = "github", _ operation: String = "create_issue") -> ActionRequest {
        ActionRequest(id: id, provider: "openai", integration: integration, operation: operation, parameters: ["title":"Test"], risk: ActionRiskEvaluator.risk(integration: integration, operation: operation))
    }
    func center(_ allow: Bool) -> ActionApprovalCenter {
        var center: ActionApprovalCenter!
        center = ActionApprovalCenter(present: { request in Task { @MainActor in center.resolve(request.id, allow: allow) } }, available: { true }, clear: { _ in }, audit: { _, _ in })
        return center
    }
    func png() -> String {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        bitmap.setColor(.red, atX: 0, y: 0)
        return bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }
    func testRiskEvaluator() {
        XCTAssertEqual(action("a","coucou","list_integrations").risk,.safe)
        XCTAssertEqual(action("a","github","create_issue").risk,.confirm)
        for integration in ["mcp","stripe","codex"] { XCTAssertEqual(action("a",integration,"anything").risk,.critical) }
        XCTAssertEqual(action("a","vercel","production_deploy").risk,.critical)
    }
    func testSafeRouting() async { let c=center(false); let allowed=await c.authorize(action("safe","coucou","list_integrations"));XCTAssertTrue(allowed);XCTAssertTrue(c.queue.isEmpty) }
    func testConfirmAllow() async { let c=center(true); let allowed=await c.authorize(action());XCTAssertTrue(allowed) }
    func testCriticalAllow() async { let c=center(true); let allowed=await c.authorize(action("critical","stripe","refund"));XCTAssertTrue(allowed) }
    func testDeny() async { let c=center(false);let a=action();let allowed=await c.authorize(a);XCTAssertFalse(allowed);XCTAssertFalse(c.claimExecution(a.id)) }
    func testTimeout() async { let c=ActionApprovalCenter(present:{_ in},available:{true},clear:{_ in},audit:{_,_ in});let allowed=await c.authorize(action(),timeout:.milliseconds(5));XCTAssertFalse(allowed);XCTAssertTrue(c.queue.isEmpty) }
    func testDoubleExecution() async {
        let c=center(true),a=action();var executions=0
        _ = await c.execute(a) { executions += 1;return "ok" }
        c.resolve(a.id,allow:true)
        _ = await c.execute(a) { executions += 1;return "bad" }
        XCTAssertEqual(executions,1)
    }
    func testCancelQueue() async {
        let c=ActionApprovalCenter(present:{_ in},available:{true},clear:{_ in},audit:{_,_ in})
        let task=Task { await c.authorize(action()) }; await Task.yield();c.cancelAll()
        let allowed=await task.value;XCTAssertFalse(allowed)
    }
    func testRiskCannotBeDowngraded() async {
        let c=center(true),a=ActionRequest(id:"forged",provider:"openai",integration:"stripe",operation:"refund",parameters:[:],risk:.safe)
        let allowed=await c.authorize(a);XCTAssertFalse(allowed)
    }
    func testSecretRedaction() { let text=SecretRedaction.text(#"{"api_key":"private","password":"private","title":"safe"}"#);XCTAssertFalse(text.contains("private"));XCTAssertTrue(text.contains("safe")) }
    func testComputerParsing() throws { XCTAssertEqual(try ComputerUse.parse(["type":"computer_call","actions":[["type":"keypress","keys":["ENTER"]]]]).count,1) }
    func testComputerRejectsScriptsAndShortcuts() { for a in [["type":"exec","code":"bad"],["type":"keypress","keys":["CTRL","V"]]] as [[String:Any]] { XCTAssertThrowsError(try ComputerUse.parse(["type":"computer_call","actions":[a]])) } }
    func testComputerMockExecution() async throws {
        let fake=FakeComputer(image:png())
        let result=try await ComputerUse.handle(["type":"computer_call","call_id":"computer_mock","actions":[["type":"click","x":1,"y":2]],"pending_safety_checks":[["id":"check","message":"Confirm action"]]],executor:fake,approvals:center(true))
        XCTAssertEqual(fake.executions,1);XCTAssertEqual(fake.captures,1);XCTAssertEqual(result["type"] as? String,"computer_call_output");XCTAssertNotNil(result["acknowledged_safety_checks"])
    }
    func testComputerDenialDoesNotExecute() async {
        let fake=FakeComputer(image:png())
        do { _ = try await ComputerUse.handle(["type":"computer_call","call_id":"computer_denied","actions":[["type":"click","x":1,"y":2]]],executor:fake,approvals:center(false));XCTFail("Denied action executed") } catch {}
        XCTAssertEqual(fake.executions,0);XCTAssertEqual(fake.captures,0)
    }
    func testMCPDiscovery() { XCTAssertTrue(RemoteMCP.discovery([["type":"mcp_list_tools","server_label":"example","tools":[["name":"search"]]]]).contains("example: search")) }
    func testMCPRequestAndAuthentication() throws {
        let server=RemoteMCPServer(name:"example",endpoint:"https://example.com/mcp",enabled:true,tools:["search"])
        let tool=try server.tool(token:"fake-test-token");XCTAssertEqual(tool["require_approval"] as? String,"always");XCTAssertEqual(tool["authorization"] as? String,"fake-test-token")
        XCTAssertFalse(RemoteMCPServer(name:"x",endpoint:"https://host/mcp?token=secret",enabled:true,tools:["search"]).valid())
    }
    func testMCPApprovalCallMock() async {
        let server=RemoteMCPServer(name:"example",endpoint:"https://example.com/mcp",enabled:true,tools:["search"])
        let item:[String:Any]=["id":"approval_mock","server_label":"example","name":"search","arguments":"{}"]
        let result=await RemoteMCP.approval(item,servers:[server],approvals:center(true));XCTAssertEqual(result["approve"] as? Bool,true)
    }
    func testMCPUnknownToolDenied() async { let result=await RemoteMCP.approval(["id":"unknown","name":"shell","server_label":"evil","arguments":"{}"],servers:[],approvals:center(true));XCTAssertEqual(result["approve"] as? Bool,false) }
    func testImageGenerationRequest() throws { let t=try ImageWorkflow.tool(model:"",size:"1024x1024",transparent:true,action:"generate");XCTAssertEqual(t["action"] as? String,"generate");XCTAssertEqual(t["background"] as? String,"transparent") }
    func testImageEditingRequest() throws { XCTAssertEqual(ImageWorkflow.intent("rimuovi lo sfondo"),"edit");XCTAssertNil(ImageWorkflow.intent("cosa c'è in questa immagine?"));let t=try ImageWorkflow.tool(model:"",size:"auto",transparent:false,action:"edit");XCTAssertEqual(t["action"] as? String,"edit") }
    func testImageResponseAndPreview() throws { let image=png();XCTAssertEqual(try ImageWorkflow.parse([["type":"image_generation_call","status":"completed","result":image]]),[image]);XCTAssertNotNil(NSImage(data:Data(base64Encoded:image)!)) }
    func testMalformedImageRejected() { XCTAssertThrowsError(try ImageWorkflow.parse([["type":"image_generation_call","status":"completed","result":"aGVsbG8="]])) }
    func testImageSaveFlow() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png");defer{try? FileManager.default.removeItem(at:url)}
        XCTAssertFalse(ImageWorkflow.save(png(),chooseURL:{nil}));XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        XCTAssertTrue(ImageWorkflow.save(png(),chooseURL:{url}));XCTAssertNotNil(NSImage(contentsOf:url))
    }
    func writeMock(_ integration:String,_ operation:String,_ parameters:[String:Any],_ allow:Bool=true) async throws {
        let state=AppState.shared,previous=state.activeIntegrations;state.activeIntegrations.insert("integration_"+integration);defer{state.activeIntegrations=previous}
        let suite="write-test-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set("https://workflow.example/webhook/configured",forKey:"n8nWebhook")
        let raw=String(data:try JSONSerialization.data(withJSONObject:parameters),encoding:.utf8)!
        let args=String(data:try JSONSerialization.data(withJSONObject:["integration":integration,"operation":operation,"parameters":raw]),encoding:.utf8)!
        var calls=0,keysRead=0
        let result=await ExternalActions.execute(arguments:args,id:UUID().uuidString,settings:defaults,state:state,approvals:center(allow),keyProvider:{_ in keysRead += 1;return "test-integration-credential"},transport:{request in
            calls += 1;XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-integration-credential")
            return(Data(#"{"id":"mock_created"}"#.utf8),HTTPURLResponse(url:request.url!,statusCode:201,httpVersion:nil,headerFields:nil)!)
        })
        XCTAssertEqual(calls,allow ? 1:0);XCTAssertEqual(keysRead,allow ? 1:0);XCTAssertTrue(result.contains(allow ? "success":"error"))
    }
    func testGitHubWriteMock() async throws { try await writeMock("github","create_issue",["owner":"owner","repo":"repo","title":"title","body":"body"]) }
    func testNotionWriteMock() async throws { try await writeMock("notion","create_page",["parent":["page_id":"parent"],"properties":[:]]) }
    func testN8NExecutionMock() async throws { try await writeMock("n8n","run_workflow",["workflow":"configured","input":[:],"effect":"Test workflow"]) }
    func testVercelApprovalMock() async throws { try await writeMock("vercel","production_deploy",["name":"project","gitSource":["type":"github","repoId":1,"ref":"main"]],false) }
    func testResendSendApproval() async throws { try await writeMock("resend","send_email",["from":"from@example.com","to":["to@example.com"],"subject":"Test","text":"Preview"],false) }
    func testStripeCriticalAndMock() async throws { XCTAssertEqual(action("a","stripe","refund").risk,.critical);try await writeMock("stripe","refund",["payment_intent":"pi_fake","amount":100]) }
    func testCalComWriteMock() async throws { try await writeMock("calcom","create_booking",["start":"2027-01-01T10:00:00Z","eventTypeId":1,"attendee":["name":"Test","email":"test@example.com","timeZone":"UTC"]]) }
    func testExternalURLInjectionRejected() { XCTAssertThrowsError(try ExternalPlan.build(integration:"github",operation:"create_issue",parameters:["owner":"..","repo":"repo","title":"x","body":"x"],id:"test")) }
    func testCalComRescheduleMock() async throws { try await writeMock("calcom","reschedule_booking",["bookingUid":"booking_mock","start":"2027-01-01T11:00:00Z","reschedulingReason":"Test change"]) }
    func testCalComCancelCriticalMock() async throws { XCTAssertEqual(action("a","calcom","cancel_booking").risk,.critical);try await writeMock("calcom","cancel_booking",["bookingUid":"booking_mock","cancellationReason":"Test cancellation"],false) }
    func testNestedSecretAndDiscoveryOnly() throws {
        XCTAssertTrue(SecretRedaction.sensitive(["api-key":["value":"private"]]));XCTAssertFalse(SecretRedaction.sensitive(["keys":["ENTER"]]))
        let server=RemoteMCPServer(name:"discovery",endpoint:"https://example.com/mcp",enabled:true,tools:[])
        XCTAssertTrue(server.valid());XCTAssertNil(try server.tool(token:nil)["allowed_tools"])
    }
    func testMCPPlaintextTokenConfigurationRejected() {
        let suite="mcp-invalid-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(#"[{"name":"example","endpoint":"https://example.com/mcp","enabled":true,"tools":[],"authorization":"private"}]"#,forKey:"mcpServers")
        XCTAssertThrowsError(try RemoteMCP.servers(defaults))
    }
    func testLegacyClaudeAlwaysAndCodexDenyShareQueue() {
        var shown:[String]=[],decisions:[String]=[]
        let c=ActionApprovalCenter(present:{shown.append($0.id)},available:{true},clear:{_ in AppState.shared.pendingApproval=nil},audit:{_,_ in})
        let a=action("claude","claudeCode","Bash"),b=action("codex","codex","agent_action")
        c.enqueueLegacy(a,info:ApprovalInfo(sessionId:"s",tool:"Bash",command:"echo test",provider:"claudeCode",requestID:a.id)){decisions.append($0)}
        c.enqueueLegacy(b,info:ApprovalInfo(sessionId:"s",tool:"Codex",command:"diff",provider:"actions",requestID:b.id)){decisions.append($0)}
        c.resolve(b.id,allow:true);XCTAssertTrue(decisions.isEmpty)
        c.resolve(a.id,decision:"always");c.resolve(b.id,allow:false)
        XCTAssertEqual(decisions,["always","deny"]);XCTAssertTrue(c.queue.isEmpty);AppState.shared.pendingApproval=nil
    }
    func testMCPSecureStoreRoundTrip() {
        let name="mcp-token-"+UUID().uuidString.replacingOccurrences(of:"-",with:"")
        defer{KeychainStore.shared.remove(name)}
        XCTAssertTrue(KeychainStore.shared.set(name,value:"mock-mcp-credential"));XCTAssertEqual(KeychainStore.shared.get(name),"mock-mcp-credential")
    }
    func testMCPResponsesContinuationMock() async throws {
        let suite="mcp-chat-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(#"[{"name":"example","endpoint":"https://example.com/mcp","enabled":true,"tools":["search"]}]"#,forKey:"mcpServers")
        var bodies:[[String:Any]]=[]
        let service=OpenAIService(settings:defaults,keyProvider:{"test-credential"},approvals:center(true),transport:{request in
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any];bodies.append(body)
            if bodies.count==2 { XCTAssertEqual((body["input"] as? [[String:Any]])?.last?["approve"] as? Bool,true) }
            let output:[[String:Any]]=bodies.count==1 ? [["type":"mcp_list_tools","server_label":"example","tools":[["name":"search"]]],["type":"mcp_approval_request","id":"mcp_continuation","server_label":"example","name":"search","arguments":"{}"]] : [["type":"mcp_call","id":"mcp_call_result","server_label":"example","name":"search","output":"Untrusted result"],["type":"message","role":"assistant","content":[["type":"output_text","text":"Answer"]]]]
            return(try JSONSerialization.data(withJSONObject:["status":"completed","output":output]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        await service.chat(query:"List and use MCP search",context:nil,state:AppState.shared);XCTAssertEqual(bodies.count,2)
        XCTAssertEqual((bodies.first?["tools"] as? [[String:Any]])?.first?["require_approval"] as? String,"always");XCTAssertFalse(service.history.isEmpty)
        XCTAssertFalse(service.history.contains(where: { $0["type"] as? String == "mcp_approval_response" || $0["type"] as? String == "mcp_approval_request" }))
        await service.chat(query:"Follow up without another call",context:nil,state:AppState.shared)
        XCTAssertFalse((bodies.last?["input"] as? [[String:Any]] ?? []).contains(where: { $0["type"] as? String == "mcp_approval_response" }))
    }
    func testComputerResponsesContinuationMock() async throws {
        let suite="computer-chat-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set("gpt-6.1-sol",forKey:"openaiModel");defaults.set(true,forKey:"openaiComputer")
        let fake=FakeComputer(image:png());var bodies:[[String:Any]]=[]
        let service=OpenAIService(settings:defaults,keyProvider:{"test-credential"},approvals:center(true),computerExecutor:fake,transport:{request in
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any];bodies.append(body)
            if bodies.count==2 { XCTAssertEqual((body["input"] as? [[String:Any]])?.last?["type"] as? String,"computer_call_output") }
            let output:[[String:Any]]=bodies.count==1 ? [["type":"computer_call","call_id":"computer_chat_mock","actions":[["type":"click","x":1,"y":2]]]] : [["type":"message","role":"assistant","content":[["type":"output_text","text":"Done"]]]]
            return(try JSONSerialization.data(withJSONObject:["status":"completed","output":output]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        await service.chat(query:"Use configured browser",context:nil,state:AppState.shared);XCTAssertEqual(bodies.count,2);XCTAssertEqual(fake.executions,1);XCTAssertEqual(fake.captures,1)
    }
    func testSearchAndInterpreterRegressionMock() async throws {
        let suite="tools-regression-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(true,forKey:"openaiWebSearch");defaults.set(true,forKey:"openaiCodeInterpreter")
        let service=OpenAIService(settings:defaults,keyProvider:{"test-credential"},transport:{request in
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            XCTAssertEqual((body["tools"] as? [[String:Any]])?.count,2)
            let output:[[String:Any]]=[["type":"message","role":"assistant","content":[["type":"output_text","text":"Answer","annotations":[["type":"url_citation","url":"https://example.com","title":"Source"],["type":"container_file_citation","container_id":"cntr_mock","file_id":"file_mock","filename":"chart.png"]]]]]]
            return(try JSONSerialization.data(withJSONObject:["status":"completed","output":output]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        await service.chat(query:"Search and plot",context:nil,state:AppState.shared)
        XCTAssertEqual(AppState.shared.chatHistory.last?.sources.count,1);XCTAssertEqual(AppState.shared.chatHistory.last?.artifacts.count,1)
    }
    func testDroppedImageVisionAndEditRegression() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png");defer{try? FileManager.default.removeItem(at:url)}
        try Data(base64Encoded:png())!.write(to:url)
        XCTAssertEqual(try OpenAIService.fileBlock(url,name:"image.png",vision:true)["type"] as? String,"input_image")
        XCTAssertThrowsError(try OpenAIService.fileBlock(url,name:"image.png",vision:false))
    }
    func testImageChatMultiTurnMock() async throws {
        let suite="image-test-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(true,forKey:"openaiImages");let image=png();var bodies:[[String:Any]]=[]
        let service=OpenAIService(settings:defaults,keyProvider:{"test-credential"},transport:{request in
            bodies.append(try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any])
            let data=try JSONSerialization.data(withJSONObject:["status":"completed","output":[["type":"image_generation_call","id":"ig_test","status":"completed","result":image]]])
            return(data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        await service.chat(query:"generate an image",context:nil,state:AppState.shared)
        XCTAssertEqual(AppState.shared.chatHistory.last?.images,[image]);XCTAssertEqual(service.history.count,2)
        await service.chat(query:"edit this image",context:nil,state:AppState.shared)
        XCTAssertEqual((bodies.last?["input"] as? [[String:Any]])?.count,3);XCTAssertEqual((bodies.last?["tools"] as? [[String:Any]])?.first?["action"] as? String,"edit")
    }
}

@MainActor private final class FakeComputer: ComputerExecutor {
    var executions=0,captures=0;let image:String
    init(image:String){self.image=image}
    func execute(_ action:[String:Any]) async throws {executions += 1}
    func screenshot() async throws -> String {captures += 1;return image}
}

import AppKit
import WebKit
import XCTest
@testable import Quartz

/// These tests exercise the injected API in real page-world WebKit, including
/// document-start site scripts. They do not substitute a JavaScript DOM emulator.
@MainActor
final class QuartzWebMCPScriptTests: XCTestCase, WKNavigationDelegate {
    private var navigationFinished: XCTestExpectation?

    private struct Snapshot: Decodable {
        struct Tool: Decodable {
            let id: String
            let name: String
            let source: String
        }
        let documentID: String
        let mode: String
        let tools: [Tool]
    }

    private func makeWebView(prelude: String? = nil) -> (NSWindow, WKWebView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(QuartzStartPageSchemeHandler(), forURLScheme: QuartzStartPage.scheme)
        if let prelude {
            configuration.userContentController.addUserScript(WKUserScript(source: prelude, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: QuartzWebMCPScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView = webView
        webView.navigationDelegate = self
        return (window, webView)
    }

    private func load(_ html: String, in webView: WKWebView, url: String? = "https://webmcp.example/tests") async {
        let loaded = expectation(description: "Load WebMCP document at \(url ?? "about:blank")")
        navigationFinished = loaded
        webView.loadHTMLString("<!doctype html><meta charset=utf-8>" + html, baseURL: url.flatMap(URL.init(string:)))
        await fulfillment(of: [loaded], timeout: 15)
        navigationFinished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { navigationFinished?.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("WebMCP fixture failed to load: \(error)")
        navigationFinished?.fulfill()
    }

    private func run(_ script: String, in webView: WKWebView, arguments: [String: Any] = [:]) async throws -> String {
        let value = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        return try XCTUnwrap(value as? String)
    }

    private func snapshot(in webView: WKWebView) async throws -> Snapshot {
        let result = try await run("return JSON.stringify(await __quartzWebMCP.snapshot());", in: webView)
        return try JSONDecoder().decode(Snapshot.self, from: Data(result.utf8))
    }

    private let echo = #"""
    <script>
    window.documentStartAPI = document.modelContext === navigator.modelContext && document.modelContext instanceof EventTarget;
    window.echoSchema = {type:'object', properties:{message:{type:'string'}}, required:['message'], additionalProperties:false};
    window.registration = document.modelContext.registerTool({name:'echo', description:'Echo a message.', inputSchema: echoSchema,
        annotations:{readOnlyHint:true}, execute: async (input, {signal}) => ({message:input.message, aborted:signal.aborted})});
    </script><body>WebMCP fixture</body>
    """#

    func testDocumentStartRegistrationDiscoveryAndPageAndHostExecution() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(echo, in: webView)
        let state = try await run("await registration; return String(documentStartAPI);", in: webView)
        XCTAssertEqual(state, "true", "The API must exist before the first site script")
        let discovered = try await snapshot(in: webView)
        XCTAssertEqual(discovered.mode, "compatibility")
        XCTAssertEqual(discovered.tools.map(\.name), ["echo"])
        let record = try XCTUnwrap(discovered.tools.first)
        let message = "Snow 雪, quotes \" + <script>alert(1)</script>"
        let result = try await run(QuartzWebMCPScript.executeScript, in: webView,
                                   arguments: ["toolID": record.id, "documentID": discovered.documentID, "input": ["message": message]])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(object["message"] as? String, message)
        XCTAssertEqual(object["aborted"] as? Bool, false)
        let pageResult = try await run("const tools = await document.modelContext.getTools(); return await document.modelContext.executeTool(tools[0], {message:'page'});", in: webView)
        XCTAssertEqual(pageResult, #"{"message":"page","aborted":false}"#)
    }

    func testSchemaCloneValidationUnsupportedKeywordsAndDuplicateNames() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(echo, in: webView)
        let result = try await run(#"""
        await registration;
        echoSchema.properties.message.type = 'number';
        const c = document.modelContext, tool = (await c.getTools())[0], errors = [];
        for (const input of [{}, {message:123}, {message:'ok', extra:true}]) {
            try { await c.executeTool(tool, input); errors.push('accepted'); } catch (e) { errors.push(e.name); }
        }
        try { await c.registerTool({name:'echo',description:'Duplicate',execute:()=>1}); } catch (e) { errors.push(e.name); }
        try { await c.registerTool({name:'reference',description:'Unsupported schema',inputSchema:{$ref:'#/x'},execute:()=>1}); } catch (e) { errors.push(e.name); }
        try { await c.registerTool({name:'unsafe-origin',description:'Cross-origin',execute:()=>1},{exposedTo:['https://other.example']}); } catch (e) { errors.push(e.name); }
        try { await c.getTools({fromOrigins:['https://other.example']}); } catch (e) { errors.push(e.name); }
        try { await c.executeTool({name:'echo'}, {message:'forged'}); } catch (e) { errors.push(e.name); }
        errors.push(JSON.parse(await c.executeTool(tool,{message:'still a string'})).message);
        return JSON.stringify(errors);
        """#, in: webView)
        XCTAssertEqual(result, #"["TypeError","TypeError","TypeError","InvalidStateError","NotSupportedError","NotSupportedError","NotSupportedError","NotFoundError","still a string"]"#)
    }

    func testNestedSchemaConstraintsAndResultSerializationFailures() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load("<body>Schema checks</body>", in: webView)
        let result = try await run(#"""
        const c=document.modelContext;
        await c.registerTool({name:'nested',description:'Validate nested input',inputSchema:{type:'object',properties:{
            count:{type:'integer',minimum:1,maximum:5},kind:{enum:['one','two']},
            rows:{type:'array',minItems:1,uniqueItems:true,items:{type:'object',properties:{name:{type:'string',minLength:2}},required:['name'],additionalProperties:false}}
        },required:['count','kind','rows'],additionalProperties:false},execute:input=>input});
        const t=(await c.getTools())[0], input={count:2,kind:'one',rows:[{name:'ok'}]}, errors=[];
        for(const changed of [{...input,count:1.5},{...input,kind:'bad'},{...input,rows:[]},{...input,rows:[{name:'x'}]},{...input,rows:[{name:'ok'},{name:'ok'}]}]) {
            try { await c.executeTool(t,changed); errors.push('accepted'); } catch(e) { errors.push(e.name); }
        }
        await c.registerTool({name:'circular',description:'Return circular data',execute:()=>{const x={};x.x=x;return x;}});
        await c.registerTool({name:'big',description:'Return oversized data',execute:()=> 'x'.repeat(262145)});
        for(const tool of (await c.getTools()).slice(1)) {
            try { await c.executeTool(tool,{}); errors.push('accepted'); } catch(e) { errors.push(e.name); }
        }
        return JSON.stringify(errors);
        """#, in: webView)
        XCTAssertEqual(result, #"["TypeError","TypeError","TypeError","TypeError","TypeError","DataError","QuotaExceededError"]"#)
    }

    func testUnregisterReplacementAndNavigationInvalidateIDs() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(echo, in: webView)
        let first = try await snapshot(in: webView)
        let old = try XCTUnwrap(first.tools.first)
        let stale = try await run(#"""
        const c=document.modelContext, oldTool=(await c.getTools())[0];
        c.unregisterTool('echo');
        await c.registerTool({name:'echo',description:'Replacement',execute:()=> 'new'});
        const errors=[];
        try { await c.executeTool(oldTool,{message:'old'}); } catch(e) { errors.push(e.name); }
        try { await __quartzWebMCP.execute(oldID,{message:'old'},docID); } catch(e) { errors.push(e.name); }
        return JSON.stringify(errors);
        """#, in: webView, arguments: ["oldID": old.id, "docID": first.documentID])
        XCTAssertEqual(stale, #"["NotFoundError","NotFoundError"]"#)
        let replaced = try await snapshot(in: webView)
        XCTAssertNotEqual(replaced.tools.first?.id, old.id)
        await load(echo, in: webView, url: "https://webmcp.example/next")
        let next = try await snapshot(in: webView)
        XCTAssertNotEqual(next.documentID, first.documentID)
        let failed = try await run("try { await __quartzWebMCP.execute(toolID,{message:'stale'},oldDocumentID); return 'accepted'; } catch(e) { return e.name; }", in: webView,
                                   arguments: ["toolID": try XCTUnwrap(next.tools.first?.id), "oldDocumentID": first.documentID])
        XCTAssertEqual(failed, "NotFoundError")
    }

    func testRegistrationAbortNativeCancellationAndTimeoutReachCallback() async throws {
        let (window, webView) = makeWebView(prelude: "const originalTimer=window.setTimeout.bind(window); window.setTimeout=(fn,ms,...args)=>originalTimer(fn,ms===30000?80:ms,...args);")
        defer { window.close() }
        await load("<body>Cancellation</body>", in: webView)
        let result = try await run(#"""
        const c=document.modelContext, registrationAbort=new AbortController();
        let changes=0; c.ontoolchange=()=>changes++;
        await c.registerTool({name:'gone',description:'Abort registration',execute:()=>true},{signal:registrationAbort.signal});
        registrationAbort.abort();
        const removed=(await c.getTools()).length===0;
        await c.registerTool({name:'wait',description:'Wait for cancellation',execute:(input,{signal})=>new Promise(()=> {
            signal.addEventListener('abort',()=>{window.callbackAborted=true;},{once:true});
        })});
        const s=await __quartzWebMCP.snapshot();
        window.pending=__quartzWebMCP.execute(s.tools[0].id,{},s.documentID).then(()=> 'accepted',e=>e.name);
        await Promise.resolve();
        __quartzWebMCP.cancel(s.documentID);
        const canceled=await pending, observed=window.callbackAborted;
        window.callbackAborted=false;
        const tool=(await c.getTools())[0];
        let expired;
        try { await c.executeTool(tool,{}); } catch(e) { expired=e.name; }
        return JSON.stringify({removed,changes,canceled,observed,expired,timeoutObserved:window.callbackAborted});
        """#, in: webView)
        XCTAssertEqual(result, #"{"removed":true,"changes":3,"canceled":"AbortError","observed":true,"expired":"TimeoutError","timeoutObserved":true}"#)
    }

    func testDeclarativeAutosubmitFillsControlsAndReturnsSubmitResponse() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(#"""
        <form toolname="search" tooldescription="Search items" toolautosubmit>
          <label for="query">Search term</label><input id="query" name="query" required>
          <select name="category"><option value="all">Everything</option><option value="books">Books</option></select>
          <input name="available" type="checkbox"><button>Search</button>
        </form><script>
        document.querySelector('form').addEventListener('submit',e=>{
          e.preventDefault();
          e.respondWith(Promise.resolve({agent:e.agentInvoked,query:e.target.elements.query.value,
            category:e.target.elements.category.value,available:e.target.elements.available.checked}));
        });
        </script>
        """#, in: webView)
        let discovered = try await snapshot(in: webView)
        let tool = try XCTUnwrap(discovered.tools.first)
        XCTAssertEqual(tool.source, "declarative")
        let result = try await run(QuartzWebMCPScript.executeScript, in: webView,
                                   arguments: ["toolID": tool.id, "documentID": discovered.documentID,
                                               "input": ["query": "history", "category": "books", "available": true]])
        XCTAssertEqual(result, #"{"agent":true,"query":"history","category":"books","available":true}"#)
        let mutation = try await run("document.querySelector('form').setAttribute('tooldescription','Changed description'); return JSON.stringify(await __quartzWebMCP.snapshot());", in: webView)
        let changed = try JSONDecoder().decode(Snapshot.self, from: Data(mutation.utf8))
        XCTAssertNotEqual(changed.tools.first?.id, tool.id)
    }

    func testDeclarativeFormWithoutAutosubmitWaitsAndResetCancels() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(#"""
        <form toolname="manual" tooldescription="Confirm submission"><input name="query" required><button>Submit</button></form>
        <script>window.submissions=0;document.querySelector('form').addEventListener('submit',e=>{
          submissions++; e.preventDefault(); e.respondWith({submitted:true,agent:e.agentInvoked});
        });</script>
        """#, in: webView)
        let result = try await run(#"""
        const form=document.querySelector('form'),s=await __quartzWebMCP.snapshot();
        const pending=__quartzWebMCP.execute(s.tools[0].id,{query:'wait'},s.documentID);
        await Promise.resolve();
        const before=submissions, value=form.elements.query.value;
        form.requestSubmit(); const response=JSON.parse(await pending);
        const canceled=__quartzWebMCP.execute(s.tools[0].id,{query:'reset'},s.documentID).catch(e=>e.name);
        await Promise.resolve(); form.reset();
        return JSON.stringify({before,value,response,canceled:await canceled});
        """#, in: webView)
        XCTAssertEqual(result, #"{"before":0,"value":"wait","response":{"submitted":true,"agent":true},"canceled":"AbortError"}"#)
    }

    func testSecureOriginAndTopFrameBoundaryAndNativePreservation() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        for url in ["http://insecure.example/test", "quartz://home", "file:///tmp/webmcp.html"] {
            await load("<body>No API</body>", in: webView, url: url)
            let exposed = try await run("return String(typeof __quartzWebMCP);", in: webView)
            XCTAssertEqual(exposed, "undefined", "Do not install WebMCP at \(url)")
        }
        await load("<iframe srcdoc='<p>Child frame</p>'></iframe>", in: webView)
        let child = try await run("return String(typeof document.querySelector('iframe').contentWindow.__quartzWebMCP);", in: webView)
        XCTAssertEqual(child, "undefined")
        let (nativeWindow, nativeWebView) = makeWebView(prelude: "window.existingContext={sentinel:true};Object.defineProperty(document,'modelContext',{value:existingContext});")
        defer { nativeWindow.close() }
        await load("<body>Native API</body>", in: nativeWebView)
        let native = try await run("const s=await __quartzWebMCP.snapshot();return JSON.stringify({preserved:document.modelContext===existingContext,mode:s.mode,count:s.tools.length});", in: nativeWebView)
        XCTAssertEqual(native, #"{"preserved":true,"mode":"native-unavailable","count":0}"#)
    }

    func testNativeAdapterUsesNativeDescriptorsAndInvalidatesOnToolChange() async throws {
        let (window, webView) = makeWebView(prelude: #"""
        window.nativeContext=new EventTarget();
        nativeContext.getTools=async()=>[{name:'native',description:'Native tool',inputSchema:{type:'object'},origin:location.origin,window}];
        nativeContext.executeTool=async(tool,input,{signal})=>JSON.stringify({native:tool.window===window,input});
        Object.defineProperty(document,'modelContext',{value:nativeContext});
        """#)
        defer { window.close() }
        await load("<body>Native adapter</body>", in: webView)
        let result = try await run(#"""
        const first=await __quartzWebMCP.snapshot(), second=await __quartzWebMCP.snapshot();
        const value=JSON.parse(await __quartzWebMCP.execute(first.tools[0].id,{hello:'native'},first.documentID));
        nativeContext.dispatchEvent(new Event('toolchange'));
        let stale;
        try { await __quartzWebMCP.execute(first.tools[0].id,{},first.documentID); } catch(e) { stale=e.name; }
        const next=await __quartzWebMCP.snapshot();
        return JSON.stringify({mode:first.mode,stable:first.tools[0].id===second.tools[0].id,value,stale,replaced:first.tools[0].id!==next.tools[0].id});
        """#, in: webView)
        XCTAssertEqual(result, #"{"mode":"native","stable":true,"value":{"native":true,"input":{"hello":"native"}},"stale":"NotFoundError","replaced":true}"#)
    }

    func testPageCacheLifecycleCancelsThenReactivatesTheSameDocument() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(echo, in: webView)
        let result = try await run(#"""
        const before=await __quartzWebMCP.snapshot();
        dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));
        let hidden;
        try { await __quartzWebMCP.snapshot(); } catch(e) { hidden=e.name; }
        dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));
        const after=await __quartzWebMCP.snapshot();
        const value=JSON.parse(await __quartzWebMCP.execute(after.tools[0].id,{message:'restored'},after.documentID));
        return JSON.stringify({hidden,sameDocument:before.documentID===after.documentID,message:value.message});
        """#, in: webView)
        XCTAssertEqual(result, #"{"hidden":"InvalidStateError","sameDocument":true,"message":"restored"}"#)
    }

    func testLegacyContextReplacementAndCapturedJSONBuiltins() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(echo, in: webView)
        let result = try await run(#"""
        const c=navigator.modelContext;
        await c.provideContext({tools:[{name:'legacy',description:'Legacy context',execute:function(){"use strict";return {ok:true,privateThis:this===undefined};}}]});
        const tools=await c.getTools();
        JSON.stringify=()=>{throw new Error('page replacement');};JSON.parse=()=>{throw new Error('page replacement');};
        const result=await c.executeTool(tools[0],{});
        c.clearContext();
        return tools.length+':'+tools[0].name+':'+result+':'+(await c.getTools()).length;
        """#, in: webView)
        XCTAssertEqual(result, "1:legacy:{\"ok\":true,\"privateThis\":true}:0")
    }
}

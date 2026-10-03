import XCTest
@testable import Zera

final class ZeraAssistantTests: XCTestCase {

    private var fullCaps: ClaudeCLICapabilities {
        var c = ClaudeCLICapabilities()
        c.print = true; c.outputFormat = true; c.streamJSON = true; c.partialMessages = true; c.resume = true; c.sessionID = true
        c.tools = true; c.allowedTools = true; c.disallowedTools = true; c.permissionPrompts = true; c.maxTurns = true
        c.systemPrompt = true; c.strictMCP = true; c.noSessionPersistence = true; c.name = true; c.model = true; c.verbose = true
        return c
    }

    func testPromptsAreTheAgreedWording() {
        XCTAssertTrue(ZeraPrompts.summarize.contains("Summarize this file clearly and concisely"))
        XCTAssertTrue(ZeraPrompts.summarize.contains("action items"))
        XCTAssertTrue(ZeraPrompts.explain.hasPrefix("Explain this file in clear language"))
        XCTAssertTrue(ZeraPrompts.extract.contains("do not add interpretation"))
        XCTAssertEqual(ZeraPrompts.instruction(for: .ask("What are the action items?")), "What are the action items?")
        let inline = ZeraPrompts.inlinePrompt(action: .summarize, fileName: "notes.md", text: "hello", truncated: true)
        XCTAssertTrue(inline.contains("--- File: notes.md"))
        XCTAssertTrue(inline.contains("too large"))
        XCTAssertTrue(inline.hasSuffix("--- End of file ---"))
        XCTAssertTrue(ZeraPrompts.readPathPrompt(action: .extract, path: "/a/b.pdf", kind: .pdf).contains("Read the PDF at /a/b.pdf"))
    }

    @MainActor
    func testArgvForAFileReadByClaude() {
        let a = ZeraAssistant.shared
        let sid = UUID()
        let args = a.cliArguments(fullCaps, needsRead: true, resume: false, sessionID: sid, name: "Zera: spec.pdf")
        XCTAssertEqual(args.first, "--print")
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertTrue(args.contains("--verbose"))
        XCTAssertTrue(args.contains("--include-partial-messages"))
        XCTAssertTrue(args.contains("--session-id")); XCTAssertTrue(args.contains(sid.uuidString))
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertTrue(pair(args, "--tools") == "Read")
        XCTAssertTrue(pair(args, "--allowedTools") == "Read")
        XCTAssertTrue(pair(args, "--permission-prompts") == "none")
        XCTAssertTrue(pair(args, "--max-turns") == "8")
        XCTAssertTrue(pair(args, "--system-prompt") == ZeraPrompts.system)
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(pair(args, "--name") == "Zera: spec.pdf")
        XCTAssertFalse(args.contains("--no-session-persistence"), "file sessions persist so follow-ups can --resume")
        // Nothing dangerous is ever enabled.
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("bypassPermissions"))
    }

    @MainActor
    func testArgvForInlineTextDisablesTools() {
        let args = ZeraAssistant.shared.cliArguments(fullCaps, needsRead: false, resume: false, sessionID: UUID(), name: "Zera: a.md")
        XCTAssertEqual(pair(args, "--tools"), "")
        XCTAssertFalse(args.contains("--allowedTools"))
        XCTAssertEqual(pair(args, "--max-turns"), "2")
    }

    @MainActor
    func testArgvForFollowUpResumes() {
        let sid = UUID()
        let args = ZeraAssistant.shared.cliArguments(fullCaps, needsRead: true, resume: true, sessionID: sid, name: "Zera: spec.pdf")
        XCTAssertEqual(pair(args, "--resume"), sid.uuidString)
        XCTAssertFalse(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--system-prompt"), "the recorded prompt is reused on resume")
        XCTAssertFalse(args.contains("--name"))
    }

    @MainActor
    func testArgvDegradesForAnOldCLI() {
        var c = ClaudeCLICapabilities()
        c.print = true; c.outputFormat = true; c.resume = true
        let args = ZeraAssistant.shared.cliArguments(c, needsRead: false, resume: false, sessionID: UUID(), name: "x")
        XCTAssertEqual(args, ["--print", "--output-format", "json"])
    }

    @MainActor
    func testConnectionTestLeavesNoSession() {
        let args = ZeraAssistant.shared.cliArguments(fullCaps, needsRead: false, resume: false, sessionID: nil, name: nil)
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("--session-id"))
    }

    func testProbeErrorsMapToActions() {
        XCTAssertNil(ZeraAssistant.error(for: ClaudeCLIInfo(status: .connected)))
        XCTAssertEqual(ZeraAssistant.error(for: ClaudeCLIInfo(status: .notDetected))?.message, "Claude Code isn't installed on this Mac.")
        XCTAssertEqual(ZeraAssistant.error(for: ClaudeCLIInfo(status: .needsAuth))?.action, .openClaudeSettings)
        XCTAssertEqual(ZeraAssistant.error(for: ClaudeCLIInfo(status: .programmaticUnavailable("x")))?.action, .configureAPIKey)
        XCTAssertEqual(ZeraAssistant.error(fromFailure: "Claude couldn't be reached.", kind: .network).action, .retry)
        XCTAssertEqual(ZeraAssistant.error(fromFailure: "auth", kind: .authentication).action, .openClaudeSettings)
    }

    private func pair(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: Transcript

    func testTranscriptShowsQuestionsAndAnswersOnly() {
        let payload = FilePayload(url: URL(fileURLWithPath: "/tmp/spec.pdf"), kind: .pdf, mode: .readPath, byteCount: 10, pageCount: 2)
        let s = AnalysisSession(payload: payload)
        s.append(.request(.summarize))
        s.append(.answer("## Summary\nA spec."))
        s.append(.request(.ask("Action items?")))
        s.append(.failure("network"))
        let t = ResultCard.transcript(for: s, live: "- Ship it")
        XCTAssertFalse(t.contains("Summarize this file"), "the action lives in the header, not the body")
        XCTAssertTrue(t.contains("## Summary\nA spec."))
        XCTAssertTrue(t.contains("**You:** Action items?"))
        XCTAssertFalse(t.contains("network"), "errors are shown in the error row, not the transcript")
        XCTAssertTrue(t.hasSuffix("- Ship it"))
        XCTAssertEqual(ResultCard.transcript(for: nil, live: nil), "")
    }

    // MARK: Transcript builder

    func testBuilderStreamsThenPrefersFinalResult() {
        var b = ClaudeTranscriptBuilder()
        b.apply(.sessionStarted(id: "1", model: nil), fileName: "a.txt")
        XCTAssertEqual(b.status, "Reading a.txt…")
        b.apply(.textDelta("Hel"), fileName: "a.txt")
        b.apply(.textDelta("lo"), fileName: "a.txt")
        XCTAssertEqual(b.display, "Hello")
        XCTAssertNil(b.status)
        b.apply(.assistantMessage(text: "Hello", usedTools: false), fileName: "a.txt")
        XCTAssertEqual(b.display, "Hello")
        b.apply(.completed(result: "Hello!", sessionID: "1", costUSD: nil, turns: 1), fileName: "a.txt")
        XCTAssertEqual(b.display, "Hello!")
        XCTAssertTrue(b.isDone)
    }
}

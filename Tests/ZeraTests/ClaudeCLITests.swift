import XCTest
@testable import Zera

final class ClaudeCLITests: XCTestCase {

    /// Trimmed from `claude --help` of Claude Code 2.1.x.
    static let modernHelp = """
    Usage: claude [options] [command] [prompt]

    Options:
      --allowedTools, --allowed-tools <tools...>
          Comma or space-separated list of tool names to allow
      --disallowedTools, --disallowed-tools <tools...>
          Comma or space-separated list of tool names to deny
      --include-partial-messages            Include partial message chunks as they
                                            arrive (only works with --print and
                                            --output-format=stream-json)
      --max-turns <turns>                   Maximum number of agentic turns
      --model <model>                       Model for the current session.
      -n, --name <name>                     Set a display name for this session
      --no-session-persistence              Disable session persistence
      --output-format <format>              Output format (only works with --print):
                                            "text" (default), "json" (single
                                            result), or "stream-json" (realtime
                                            streaming) (choices: "text", "json",
                                            "stream-json")
      --permission-mode <mode>              Permission mode to use for the session
      --permission-prompts <target>         Who answers permission prompts with
                                            --print: "host" or "none"
      -p, --print                           Print response and exit (useful for
                                            pipes).
      -r, --resume [value]                  Resume a conversation by session ID
      --session-id <uuid>                   Use a specific session ID
      --strict-mcp-config                   Only use MCP servers from --mcp-config
      --system-prompt <prompt>              System prompt to use for the session
      --tools <tools...>                    Specify the list of available tools
      --verbose                             Override verbose mode setting from
                                            config
      -v, --version                         Output the version number

    Commands:
      auth                                  Manage authentication
      doctor                                Check the health of your Claude Code
                                            installation.
      mcp                                   Configure and manage MCP servers
    """

    /// What an old build might print: print mode, no streaming, no auth status.
    static let oldHelp = """
    Usage: claude [options] [command] [prompt]

    Options:
      -p, --print                Print response and exit
      --output-format <format>   Output format: "text" (default) or "json"
      -c, --continue             Continue the most recent conversation
      -r, --resume [sessionId]   Resume a conversation
      -v, --version              Output the version number

    Commands:
      config                     Manage configuration
      mcp                        Configure and manage MCP servers
    """

    func testModernHelpParsesEveryFlagZeraUses() {
        let c = ClaudeCLICapabilities.parse(help: Self.modernHelp)
        XCTAssertTrue(c.print); XCTAssertTrue(c.outputFormat); XCTAssertTrue(c.streamJSON)
        XCTAssertTrue(c.partialMessages); XCTAssertTrue(c.resume); XCTAssertTrue(c.sessionID)
        XCTAssertTrue(c.tools); XCTAssertTrue(c.allowedTools); XCTAssertTrue(c.disallowedTools)
        XCTAssertTrue(c.permissionPrompts); XCTAssertTrue(c.permissionMode); XCTAssertTrue(c.maxTurns)
        XCTAssertTrue(c.systemPrompt); XCTAssertTrue(c.strictMCP); XCTAssertTrue(c.noSessionPersistence)
        XCTAssertTrue(c.name); XCTAssertTrue(c.model); XCTAssertTrue(c.verbose); XCTAssertTrue(c.authStatus)
        XCTAssertTrue(c.programmaticOK); XCTAssertTrue(c.streamingOK)
    }

    func testOldHelpDegradesGracefully() {
        let c = ClaudeCLICapabilities.parse(help: Self.oldHelp)
        XCTAssertTrue(c.print); XCTAssertTrue(c.outputFormat); XCTAssertTrue(c.resume)
        XCTAssertFalse(c.streamJSON); XCTAssertFalse(c.partialMessages); XCTAssertFalse(c.tools)
        XCTAssertFalse(c.authStatus); XCTAssertFalse(c.sessionID)
        XCTAssertTrue(c.programmaticOK, "json output is enough to work, without streaming")
        XCTAssertFalse(c.streamingOK)
    }

    func testEmptyHelpMeansNotProgrammatic() {
        let c = ClaudeCLICapabilities.parse(help: "")
        XCTAssertFalse(c.programmaticOK)
        XCTAssertFalse(c.authStatus)
    }

    func testFlagMatchingIsNotFooledByPrefixes() {
        // "--toolsX" is not "--tools"; "--resume-later" is not "--resume".
        let c = ClaudeCLICapabilities.parse(help: "  --toolsX <x>  nothing\n  --resume-later  nothing\n")
        XCTAssertFalse(c.tools)
        XCTAssertFalse(c.resume)
    }

    func testStatusMapsToConnectionState() {
        XCTAssertEqual(ClaudeCLIStatus.connected.connection, .connected)
        XCTAssertEqual(ClaudeCLIStatus.needsAuth.connection, .needsAuth)
        XCTAssertEqual(ClaudeCLIStatus.notDetected.connection, .disconnected)
        XCTAssertEqual(ClaudeCLIStatus.programmaticUnavailable("x").connection, .error)
        XCTAssertEqual(ClaudeCLIStatus.checking.connection, .connecting)
    }

    func testCandidatePathsAreUniqueAndIncludeKnownInstallers() {
        let paths = ClaudeCLI.shared.candidatePaths().map { $0.path }
        XCTAssertEqual(Set(paths).count, paths.count, "no duplicates")
        XCTAssertTrue(paths.contains { $0.hasSuffix("/.local/bin/claude") })
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(paths.contains("/usr/local/bin/claude"))
    }

    func testShellEnvironmentNeverForwardsSessionMarkers() {
        let env = ShellEnvironment.shared.environment(extra: ["ZERA_ASSISTANT": "1"])
        XCTAssertEqual(env["ZERA_ASSISTANT"], "1")
        for k in ShellEnvironment.blockedKeys { XCTAssertNil(env[k], k) }
        XCTAssertNotNil(env["PATH"])
        XCTAssertNotNil(env["HOME"])
    }
}

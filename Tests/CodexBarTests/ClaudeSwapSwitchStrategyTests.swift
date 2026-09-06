import Foundation
import Testing
@testable import CodexBarCore

/// Strategy switches run fixed argument arrays and stay explicit user actions.
/// Executable tests use fake executables only: no real claude-swap install,
/// no credentials, no Keychain access.
struct ClaudeSwapSwitchStrategyTests {
    private func makeFakeExecutable(_ script: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-strategy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cswap")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func account(
        number: Int,
        isActive: Bool = false,
        canActivate: Bool = true,
        isHeldOutOfRotation: Bool = false) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(
                source: ClaudeSwapAccountProjection.sourceName,
                opaqueID: String(number)),
            provider: .claude,
            displayLabel: "Account \(number)",
            isActive: isActive,
            canActivate: canActivate,
            isHeldOutOfRotation: isHeldOutOfRotation,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
    }

    @Test
    func `each strategy maps to one fixed argument array`() {
        #expect(ClaudeSwapSwitchStrategy.rotate.arguments == ["--switch", "--json"])
        #expect(ClaudeSwapSwitchStrategy.best.arguments == ["--switch", "--strategy", "best", "--json"])
        #expect(ClaudeSwapSwitchStrategy.nextAvailable.arguments == [
            "--switch", "--strategy", "next-available", "--json",
        ])
    }

    @Test
    func `runs the strategy argv and reports the slot claude swap chose`() async throws {
        let path = try self.makeFakeExecutable("""
        [ "$1" = "--switch" ] || exit 2
        [ "$2" = "--strategy" ] || exit 2
        [ "$3" = "best" ] || exit 2
        [ "$4" = "--json" ] || exit 2
        echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":3},
               "strategy":"best","reason":"switched","message":"Switched","warnings":[]}'
        """)

        let result = try await ClaudeSwapAccountReader.switchAccount(executablePath: path, strategy: .best)
        #expect(result.switched)
        #expect(result.fromAccountNumber == 1)
        #expect(result.toAccountNumber == 3)
        #expect(result.reason == "switched")
    }

    @Test
    func `a strategy run that finds no target is surfaced rather than silently ignored`() async throws {
        let path = try self.makeFakeExecutable("""
        echo '{"schemaVersion":1,"switched":false,"from":{"number":1},"to":null,
               "strategy":"next-available","reason":"all-exhausted","message":"none","warnings":[]}'
        exit 3
        """)

        await #expect(throws: ClaudeSwapSwitchParserError.noViableTarget(reason: "all-exhausted")) {
            try await ClaudeSwapAccountReader.switchAccount(executablePath: path, strategy: .nextAvailable)
        }
    }

    @Test
    func `an already active no op is a successful outcome, not an error`() async throws {
        let path = try self.makeFakeExecutable("""
        echo '{"schemaVersion":1,"switched":false,"from":{"number":2},"to":{"number":2},
               "strategy":"best","reason":"already-active","message":"Already","warnings":[]}'
        """)

        let result = try await ClaudeSwapAccountReader.switchAccount(executablePath: path, strategy: .best)
        #expect(result.switched == false)
        #expect(result.toAccountNumber == 2)
        #expect(result.reason == "already-active")
    }

    @Test
    func `a slot switch still requires the slot it was asked for`() async throws {
        let path = try self.makeFakeExecutable("""
        echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":null,
               "reason":"switched","warnings":[]}'
        """)

        await #expect(throws: ClaudeSwapSwitchParserError.mismatchedTarget(expected: 2, actual: nil)) {
            try await ClaudeSwapAccountReader.switchAccount(executablePath: path, accountNumber: 2)
        }
    }

    @Test
    func `strategies are offered only when there is somewhere to go`() {
        #expect(ClaudeSwapSwitchMenuPlanner.availableStrategies(accounts: []).isEmpty)

        // A single active account has no target.
        #expect(ClaudeSwapSwitchMenuPlanner.availableStrategies(
            accounts: [self.account(number: 1, isActive: true)]).isEmpty)

        // A non-actionable slot (expired, no credentials) is not a target.
        #expect(ClaudeSwapSwitchMenuPlanner.availableStrategies(accounts: [
            self.account(number: 1, isActive: true),
            self.account(number: 2, canActivate: false),
        ]).isEmpty)

        // claude-swap never picks a disabled slot on the user's behalf.
        #expect(ClaudeSwapSwitchMenuPlanner.availableStrategies(accounts: [
            self.account(number: 1, isActive: true),
            self.account(number: 2, isHeldOutOfRotation: true),
        ]).isEmpty)

        #expect(ClaudeSwapSwitchMenuPlanner.availableStrategies(accounts: [
            self.account(number: 1, isActive: true),
            self.account(number: 2),
        ]) == ClaudeSwapSwitchStrategy.allCases)
    }
}

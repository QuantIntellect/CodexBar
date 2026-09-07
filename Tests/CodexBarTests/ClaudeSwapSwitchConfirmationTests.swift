import Foundation
import Testing
@testable import CodexBarCore

/// A completed switch used to be silent: the menu closes on click, and a target
/// whose usage reads the same before and after looks untouched. These cover the
/// confirmation that now reports what the switch actually did.
struct ClaudeSwapSwitchConfirmationTests {
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    private func identity(_ slot: Int) -> ProviderAccountIdentity {
        ProviderAccountIdentity(
            source: ClaudeSwapAccountProjection.sourceName,
            opaqueID: String(slot))
    }

    private func account(
        slot: Int,
        isActive: Bool = false,
        canActivate: Bool = true) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: self.identity(slot),
            provider: .claude,
            displayLabel: "Account \(slot)",
            isActive: isActive,
            canActivate: canActivate,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
    }

    private func outcome(
        slot: Int,
        kind: ClaudeSwapSwitchOutcome.Kind,
        ageSeconds: TimeInterval = 0) -> ClaudeSwapSwitchOutcome
    {
        ClaudeSwapSwitchOutcome(
            accountID: self.identity(slot),
            kind: kind,
            completedAt: self.now.addingTimeInterval(-ageSeconds))
    }

    private func action(
        for account: ProviderAccountUsageSnapshot,
        outcome: ClaudeSwapSwitchOutcome? = nil,
        switchingAccountID: ProviderAccountIdentity? = nil,
        hasSwitchInFlight: Bool = false) -> ClaudeSwapAccountAction
    {
        ClaudeSwapAccountActionPlanner.action(
            for: account,
            outcome: outcome,
            switchingAccountID: switchingAccountID,
            hasSwitchInFlight: hasSwitchInFlight,
            now: self.now)
    }

    @Test
    func `a completed switch confirms itself on the account it landed on`() {
        #expect(self.action(
            for: self.account(slot: 2, isActive: true),
            outcome: self.outcome(slot: 2, kind: .switched)) == .switchedConfirmation)
    }

    @Test
    func `a no op switch says the account was already active`() {
        #expect(self.action(
            for: self.account(slot: 2, isActive: true),
            outcome: self.outcome(slot: 2, kind: .alreadyActive)) == .alreadyActiveConfirmation)
    }

    @Test
    func `the confirmation only marks the account the switch landed on`() {
        #expect(self.action(
            for: self.account(slot: 3),
            outcome: self.outcome(slot: 2, kind: .switched)) == .offerSwitch)
    }

    @Test
    func `the confirmation expires back to the plain active label`() {
        let window = ClaudeSwapAccountActionPlanner.confirmationWindow
        let account = self.account(slot: 2, isActive: true)
        #expect(self.action(
            for: account,
            outcome: self.outcome(slot: 2, kind: .switched, ageSeconds: window - 1)) == .switchedConfirmation)
        #expect(self.action(
            for: account,
            outcome: self.outcome(slot: 2, kind: .switched, ageSeconds: window)) == .active)
    }

    /// A backwards clock jump must not hide a confirmation the user just earned.
    @Test
    func `a future dated confirmation still shows`() {
        #expect(self.action(
            for: self.account(slot: 2, isActive: true),
            outcome: self.outcome(slot: 2, kind: .switched, ageSeconds: -30)) == .switchedConfirmation)
    }

    @Test
    func `a switch still running outranks the previous confirmation`() {
        #expect(self.action(
            for: self.account(slot: 2),
            outcome: self.outcome(slot: 2, kind: .switched),
            switchingAccountID: self.identity(2),
            hasSwitchInFlight: true) == .switching)
    }

    @Test
    func `other accounts offer nothing while a switch is in flight`() {
        #expect(self.action(
            for: self.account(slot: 3),
            switchingAccountID: self.identity(2),
            hasSwitchInFlight: true) == .none)
    }

    @Test
    func `a non actionable account offers no switch`() {
        #expect(self.action(for: self.account(slot: 3, canActivate: false)) == .none)
        #expect(self.action(for: self.account(slot: 3)) == .offerSwitch)
        #expect(self.action(for: self.account(slot: 1, isActive: true)) == .active)
    }

    @Test
    func `an outcome is derived from the slot claude-swap reported`() throws {
        let switched = try #require(ClaudeSwapSwitchOutcome.from(
            result: ClaudeSwapAccountSwitchResult(
                switched: true,
                fromAccountNumber: 1,
                toAccountNumber: 3,
                reason: "switched"),
            completedAt: self.now))
        #expect(switched.accountID == self.identity(3))
        #expect(switched.kind == .switched)

        let noop = try #require(ClaudeSwapSwitchOutcome.from(
            result: ClaudeSwapAccountSwitchResult(
                switched: false,
                fromAccountNumber: 2,
                toAccountNumber: 2,
                reason: "already-active"),
            completedAt: self.now))
        #expect(noop.kind == .alreadyActive)

        // A strategy run that named no destination leaves nothing to confirm.
        #expect(ClaudeSwapSwitchOutcome.from(
            result: ClaudeSwapAccountSwitchResult(
                switched: false,
                fromAccountNumber: 1,
                toAccountNumber: nil,
                reason: "all-exhausted"),
            completedAt: self.now) == nil)
    }
}

import Foundation

/// What a completed claude-swap switch did, so the card that was acted on can
/// confirm it. Without this a switch is silent: the menu closes on click, and a
/// target whose usage happens to read the same before and after looks untouched.
public struct ClaudeSwapSwitchOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The active account actually moved to this slot.
        case switched
        /// claude-swap deliberately stayed put: the slot was already active, or
        /// it was already the best candidate. Nothing went wrong.
        case alreadyActive
    }

    public let accountID: ProviderAccountIdentity
    public let kind: Kind
    public let completedAt: Date

    public init(accountID: ProviderAccountIdentity, kind: Kind, completedAt: Date) {
        self.accountID = accountID
        self.kind = kind
        self.completedAt = completedAt
    }

    /// Builds an outcome from a classified switch result. Only a real move or a
    /// deliberate stay-put confirms on a card; a blocked attempt is reported as
    /// an error instead, so "nothing happened" is never dressed up as success.
    public static func from(
        result: ClaudeSwapAccountSwitchResult,
        completedAt: Date) -> ClaudeSwapSwitchOutcome?
    {
        switch ClaudeSwapSwitchResultClassifier.classify(result) {
        case let .switched(slot):
            ClaudeSwapSwitchOutcome(accountID: self.identity(slot), kind: .switched, completedAt: completedAt)
        case let .stayedPut(slot, _):
            ClaudeSwapSwitchOutcome(accountID: self.identity(slot), kind: .alreadyActive, completedAt: completedAt)
        case .blocked:
            nil
        }
    }

    private static func identity(_ slot: Int) -> ProviderAccountIdentity {
        ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: String(slot))
    }
}

/// What a `switched: false` result from claude-swap actually means.
///
/// claude-swap reports the *current* account as `to` for blocked attempts as
/// well as for benign no-ops, so a non-null destination alone does not mean the
/// request succeeded. Only `reason` separates "you are already there" from
/// "I could not move you", and the two must not read the same to the user.
public enum ClaudeSwapSwitchResultClassifier {
    public enum Classification: Equatable, Sendable {
        /// The active account moved to this slot.
        case switched(slot: Int)
        /// claude-swap deliberately stayed on this slot; nothing was wrong.
        case stayedPut(slot: Int, reason: String)
        /// claude-swap could not carry out the request.
        case blocked(reason: String)
    }

    /// Reasons where staying put is the correct answer rather than a failure.
    /// Everything else with `switched: false` is treated as blocked, so a reason
    /// added by a future claude-swap release surfaces instead of being confirmed
    /// as success.
    static let benignStayPutReasons: Set<String> = ["already-active", "already-best"]

    public static func classify(_ result: ClaudeSwapAccountSwitchResult) -> Classification {
        let reason = result.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let slot = result.toAccountNumber else {
            return .blocked(reason: reason)
        }
        if result.switched {
            return .switched(slot: slot)
        }
        guard self.benignStayPutReasons.contains(reason) else {
            return .blocked(reason: reason)
        }
        return .stayedPut(slot: slot, reason: reason)
    }

    /// A short explanation for a blocked attempt, so the user learns why the
    /// active account did not change. Unknown reasons are reported verbatim.
    public static func blockedExplanation(reason: String) -> String {
        switch reason {
        case "candidates-exhausted":
            "claude-swap found no account with quota left."
        case "usage-unavailable":
            "claude-swap could not read account usage, so it did not switch."
        case "no-valid-target":
            "claude-swap found no account it could switch to."
        case "only-one-account":
            "claude-swap manages only one account, so there is nothing to switch to."
        case "unmanaged-account":
            "The active Claude login is not managed by claude-swap."
        default:
            "claude-swap did not switch accounts (\(reason))."
        }
    }
}

/// The action label one claude-swap account card should offer or report.
///
/// Kept in Core, separate from AppKit, so menu behavior is covered by model
/// tests rather than live `NSMenu` construction. The app layer owns the strings.
public enum ClaudeSwapAccountAction: Equatable, Sendable {
    /// A switch onto this account just completed.
    case switchedConfirmation
    /// A switch resolved to this account, which was already the active one.
    case alreadyActiveConfirmation
    case active
    case switching
    case offerSwitch
    case none
}

public enum ClaudeSwapAccountActionPlanner {
    /// How long a completed switch keeps confirming itself on the card.
    ///
    /// Long enough to still be there when the user reopens the menu after the
    /// click that closed it, short enough not to look like a permanent state.
    public static let confirmationWindow: TimeInterval = 90

    public static func action(
        for account: ProviderAccountUsageSnapshot,
        outcome: ClaudeSwapSwitchOutcome?,
        switchingAccountID: ProviderAccountIdentity?,
        hasSwitchInFlight: Bool,
        now: Date) -> ClaudeSwapAccountAction
    {
        // A switch still running outranks a previous one's confirmation.
        if switchingAccountID == account.id {
            return .switching
        }
        if let outcome, self.confirmationIsVisible(outcome, for: account.id, now: now) {
            return outcome.kind == .switched ? .switchedConfirmation : .alreadyActiveConfirmation
        }
        if account.isActive {
            return .active
        }
        guard !hasSwitchInFlight, account.canActivate else { return .none }
        return .offerSwitch
    }

    static func confirmationIsVisible(
        _ outcome: ClaudeSwapSwitchOutcome,
        for accountID: ProviderAccountIdentity,
        now: Date) -> Bool
    {
        guard outcome.accountID == accountID else { return false }
        let age = now.timeIntervalSince(outcome.completedAt)
        // A negative age means the clock moved backwards; treat it as fresh
        // rather than hiding a confirmation the user just earned.
        return age < self.confirmationWindow
    }
}

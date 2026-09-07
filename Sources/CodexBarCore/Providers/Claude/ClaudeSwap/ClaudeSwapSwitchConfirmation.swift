import Foundation

/// What a completed claude-swap switch did, so the card that was acted on can
/// confirm it. Without this a switch is silent: the menu closes on click, and a
/// target whose usage happens to read the same before and after looks untouched.
public struct ClaudeSwapSwitchOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The active account actually moved to this slot.
        case switched
        /// claude-swap reported the requested slot was already the active one.
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

    /// Builds an outcome from a parsed switch result. Returns nil when
    /// claude-swap named no destination slot, which leaves nothing to confirm on.
    public static func from(
        result: ClaudeSwapAccountSwitchResult,
        completedAt: Date) -> ClaudeSwapSwitchOutcome?
    {
        guard let slot = result.toAccountNumber else { return nil }
        return ClaudeSwapSwitchOutcome(
            accountID: ProviderAccountIdentity(
                source: ClaudeSwapAccountProjection.sourceName,
                opaqueID: String(slot)),
            kind: result.switched ? .switched : .alreadyActive,
            completedAt: completedAt)
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

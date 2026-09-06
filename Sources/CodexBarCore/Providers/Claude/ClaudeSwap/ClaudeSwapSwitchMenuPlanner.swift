import Foundation

/// Decides which claude-swap-chosen switch actions the menu should offer.
///
/// Kept out of the AppKit layer so menu behavior is covered by model tests
/// rather than live `NSMenu` construction. Titles stay in the app layer, which
/// owns localization; this planner only decides availability.
public enum ClaudeSwapSwitchMenuPlanner {
    /// Strategies worth offering, in menu order.
    ///
    /// Empty when claude-swap has nowhere to go: a strategy switch would either
    /// be refused or land back on the active account. An account the user has
    /// held out of rotation with `cswap disable` stays an explicit switch
    /// target but is never a strategy target, matching claude-swap's own rule.
    public static func availableStrategies(
        accounts: [ProviderAccountUsageSnapshot]) -> [ClaudeSwapSwitchStrategy]
    {
        let hasStrategyTarget = accounts.contains { account in
            !account.isActive && account.canActivate && !account.isHeldOutOfRotation
        }
        guard hasStrategyTarget else { return [] }
        return ClaudeSwapSwitchStrategy.allCases
    }
}

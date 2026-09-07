import AppKit
import CodexBarCore

extension StatusItemController {
    func addClaudeSwapMenuCards(
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let accounts = self.store.claudeSwapAccountSnapshots
        let plan = self.compactAccountPlan(for: .claude, accounts: accounts)
        guard plan.usesCompactLayout else {
            self.addStackedClaudeSwapMenuCards(accounts: accounts, to: menu, captureMenu: captureMenu, context: context)
            return
        }
        self.addCompactAccountMenuRows(
            CompactAccountMenuRendering(
                plan: plan,
                accounts: accounts,
                idPrefix: "claudeSwap",
                cardModel: { [weak self] account in
                    self?.claudeSwapCardModel(for: account)
                },
                planAction: { [weak self] account in
                    self?.claudeSwapAccountSwitchAction(account, menu: captureMenu)
                }),
            to: menu,
            captureMenu: captureMenu,
            context: context)
        self.addClaudeSwapSwitchStrategyItems(to: menu)
    }

    /// Lets claude-swap pick the destination itself, mirroring the rotate /
    /// best / next-available actions its own menu bar offers. Each item is one
    /// explicit click running one fixed argument array; none of them starts
    /// claude-swap's background auto-switch loop.
    func addClaudeSwapSwitchStrategyItems(to menu: NSMenu) {
        let strategies = self.store.availableClaudeSwapStrategies()
        guard !strategies.isEmpty else { return }
        let submenu = NSMenu()
        let switchInFlight = self.store.claudeSwapTransientState.task != nil
        for strategy in strategies {
            let item = NSMenuItem(
                title: Self.claudeSwapStrategyTitle(strategy),
                action: #selector(self.switchClaudeSwapAccountWithStrategy(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = strategy.rawValue
            item.isEnabled = !switchInFlight
            submenu.addItem(item)
        }
        // Distinct from the per-card "Switch Account…" action, which names its own target.
        let parent = NSMenuItem(title: L("Switch Using claude-swap"), action: nil, keyEquivalent: "")
        parent.isEnabled = !switchInFlight
        parent.submenu = submenu
        menu.addItem(parent)
    }

    static func claudeSwapStrategyTitle(_ strategy: ClaudeSwapSwitchStrategy) -> String {
        switch strategy {
        case .rotate: L("Next Account")
        case .best: L("Account With Most Quota Left")
        case .nextAvailable: L("Next Account Not At Its Limit")
        }
    }

    @objc private func switchClaudeSwapAccountWithStrategy(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let strategy = ClaudeSwapSwitchStrategy(rawValue: rawValue)
        else { return }
        self.advanceMenuInteraction(for: sender.menu)
        self.store.switchClaudeSwapAccount(strategy: strategy)
    }

    private func addStackedClaudeSwapMenuCards(
        accounts: [ProviderAccountUsageSnapshot],
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let cardRows = accounts.compactMap { account ->
            (account: ProviderAccountUsageSnapshot, model: UsageMenuCardView.Model)? in
            guard let model = self.claudeSwapCardModel(for: account) else { return nil }
            return (account, model)
        }
        self.addStackedMenuCards(
            cardRows.map(\.model),
            to: menu,
            context: context,
            planAction: { [weak self] index in
                guard cardRows.indices.contains(index) else { return nil }
                return self?.claudeSwapAccountSwitchAction(cardRows[index].account, menu: captureMenu)
            })
        self.addClaudeSwapSwitchStrategyItems(to: menu)
    }

    private func claudeSwapCardModel(for account: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        self.menuCardModel(
            for: .claude,
            snapshotOverride: account.snapshot,
            errorOverride: ClaudeSwapAccountProjection.displayError(
                accountError: account.error,
                adapterError: self.store.claudeSwapLastError,
                switchError: self.store.claudeSwapTransientState.lastErrorAccountID == account.id
                    ? self.store.claudeSwapTransientState.lastError
                    : nil),
            forceOverrideCard: account.snapshot == nil,
            accountOverride: AccountInfo(
                email: account.displayLabel,
                plan: nil),
            planOverride: self.claudeSwapAccountActionLabel(account),
            sourceLabelOverride: ClaudeSwapAccountProjection.sourceLabel)
    }

    private func claudeSwapAccountActionLabel(_ account: ProviderAccountUsageSnapshot) -> String? {
        let transient = self.store.claudeSwapTransientState
        let action = ClaudeSwapAccountActionPlanner.action(
            for: account,
            outcome: transient.lastSwitchOutcome,
            switchingAccountID: transient.switchingAccountID,
            hasSwitchInFlight: transient.task != nil,
            now: Date())
        return switch action {
        case .switchedConfirmation: L("Switched")
        case .alreadyActiveConfirmation: L("Already Active")
        case .active: L("Active")
        case .switching: L("Loading…")
        case .offerSwitch: L("Switch Account...")
        case .none: nil
        }
    }

    private func claudeSwapAccountSwitchAction(
        _ account: ProviderAccountUsageSnapshot,
        menu: NSMenu)
        -> (() -> Void)?
    {
        guard self.store.claudeSwapTransientState.task == nil, account.canActivate else { return nil }
        let accountID = account.id
        return { [weak self, weak menu] in
            guard let self else { return }
            self.advanceMenuInteraction(for: menu)
            self.store.switchClaudeSwapAccount(accountID)
        }
    }
}

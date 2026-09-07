import CodexBarCore
import Foundation

/// External credential transactions must run to completion; configuration changes hide their state but do not
/// cancel the subprocess halfway through a claude-swap transaction.
struct ClaudeSwapTransientState {
    var lastError: String?
    var lastErrorAccountID: ProviderAccountIdentity?
    var switchingAccountID: ProviderAccountIdentity?
    /// Set instead of `switchingAccountID` while claude-swap picks the target itself.
    var switchingStrategy: ClaudeSwapSwitchStrategy?
    /// The last completed switch, so the card it landed on can confirm it.
    var lastSwitchOutcome: ClaudeSwapSwitchOutcome?
    /// A failed or blocked switch that belongs to no single account card.
    /// Strategy switches have no requested slot, so without this their errors
    /// would have nowhere to render and would vanish when the menu closes.
    var lastSectionError: String?
    var task: Task<Void, Never>?
    var versionProbedPath: String?
    var versionProbeGeneration: UInt64 = 0
}

extension UsageStore {
    /// True when the opt-in claude-swap adapter should run alongside the
    /// ambient Claude refresh. Listing is read-only; explicit account activation
    /// stays external-process-owned and never exposes credentials to CodexBar.
    func shouldFetchClaudeSwapAccounts() -> Bool {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            !self.settings.claudeSwapExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The active claude-swap account's usage snapshot when the adapter owns Claude
    /// account presentation (issue #2731: with two accounts the menu shows adapter
    /// cards while the bar rendered the ambient snapshot, which can have no usable
    /// windows). Returns nil — keep the ambient snapshot — when the adapter is below
    /// its presentation threshold or the active account reports no usable usage.
    ///
    /// A last-known measurement is deliberately not eligible here. Account cards
    /// state a snapshot's age, but the bar icon has no such affordance and
    /// `isStale` tracks provider errors rather than measurement age, so serving
    /// last-known numbers on the bar would present them as current.
    func claudeSwapMenuBarSnapshotOverride(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        guard instanceID == UsageProvider.claude.instanceID else { return nil }
        guard ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: .claude,
            accountCount: self.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        else { return nil }
        guard let active = self.claudeSwapAccountSnapshots.first(where: \.isActive),
              !active.usesLastKnownUsage
        else { return nil }
        return active.snapshot
    }

    func clearClaudeSwapAccountState() {
        let hadState = !self.claudeSwapAccountSnapshots.isEmpty ||
            self.claudeSwapLastRefreshAt != nil || self.claudeSwapLastError != nil ||
            self.claudeSwapTransientState.lastError != nil ||
            self.claudeSwapTransientState.lastErrorAccountID != nil ||
            self.claudeSwapTransientState.switchingAccountID != nil ||
            self.claudeSwapTransientState.switchingStrategy != nil ||
            self.claudeSwapTransientState.lastSwitchOutcome != nil ||
            self.claudeSwapTransientState.lastSectionError != nil ||
            self.claudeSwapTransientState.versionProbedPath != nil ||
            self.claudeSwapDetectedVersion != nil
        self.claudeSwapRefreshTask?.cancel()
        self.claudeSwapRefreshTask = nil
        self.claudeSwapAccountSnapshots = []
        self.claudeSwapLastRefreshAt = nil
        self.claudeSwapLastError = nil
        self.claudeSwapTransientState.lastError = nil
        self.claudeSwapTransientState.lastErrorAccountID = nil
        self.claudeSwapTransientState.switchingAccountID = nil
        self.claudeSwapTransientState.switchingStrategy = nil
        self.claudeSwapTransientState.lastSwitchOutcome = nil
        self.claudeSwapTransientState.lastSectionError = nil
        self.claudeSwapTransientState.versionProbedPath = nil
        self.claudeSwapTransientState.versionProbeGeneration &+= 1
        self.claudeSwapDetectedVersion = nil
        if hadState {
            self.claudeSwapRevision &+= 1
        }
    }

    /// Runs the optional adapter independently so it cannot delay the ambient Claude card.
    func scheduleClaudeSwapAccountRefresh(generation: UInt64? = nil) {
        self.claudeSwapRefreshTask?.cancel()
        guard self.shouldFetchClaudeSwapAccounts() else {
            self.clearClaudeSwapAccountState()
            return
        }

        self.claudeSwapRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshClaudeSwapAccounts(generation: generation)
        }
    }

    func refreshClaudeSwapAccounts(generation: UInt64? = nil) async {
        let executablePath = self.settings.claudeSwapExecutablePath
        await self.probeClaudeSwapVersionIfNeeded(executablePath: executablePath)

        do {
            let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: executablePath)
            let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: ClaudeSwapRetainedUsageStore.previousAccounts(
                    inMemory: self.claudeSwapAccountSnapshots))
            guard self.isCurrentClaudeSwapRefresh(executablePath: executablePath, generation: generation) else {
                return
            }
            ClaudeSwapRetainedUsageStore.save(snapshots)
            self.claudeSwapAccountSnapshots = snapshots
            self.claudeSwapLastRefreshAt = Date()
            self.claudeSwapLastError = nil
            self.claudeSwapRevision &+= 1
        } catch is CancellationError {
            return
        } catch {
            guard self.isCurrentClaudeSwapRefresh(executablePath: executablePath, generation: generation) else {
                return
            }
            // Retain the last successful snapshots as stale data; the settings
            // pane surfaces the adapter error and last refresh time.
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            if self.claudeSwapLastError != message {
                self.claudeSwapLastError = message
                self.claudeSwapRevision &+= 1
            }
        }
    }

    /// Activates one account through the configured claude-swap executable.
    /// The numeric slot comes from the already validated list payload; requests
    /// are serialized so two credential transactions can never overlap.
    func switchClaudeSwapAccount(_ accountID: ProviderAccountIdentity) {
        guard self.claudeSwapTransientState.task == nil,
              self.shouldFetchClaudeSwapAccounts(),
              accountID.source == ClaudeSwapAccountProjection.sourceName,
              let account = self.claudeSwapAccountSnapshots.first(where: { $0.id == accountID }),
              account.canActivate,
              let accountNumber = Int(accountID.opaqueID),
              accountNumber > 0
        else {
            return
        }

        let executablePath = self.settings.claudeSwapExecutablePath
        self.claudeSwapTransientState.switchingAccountID = accountID
        self.runClaudeSwapSwitch(executablePath: executablePath, attributingErrorTo: accountID) {
            try await ClaudeSwapAccountReader.switchAccount(
                executablePath: executablePath,
                accountNumber: accountNumber)
        }
    }

    /// Lets claude-swap choose the destination slot (rotate, most quota left, or
    /// next account that is not at its limit).
    ///
    /// Still one explicit user action per switch — this does not start
    /// claude-swap's background `auto` loop, and CodexBar still never touches
    /// credentials. Requests share the same serialization as slot switches.
    func switchClaudeSwapAccount(strategy: ClaudeSwapSwitchStrategy) {
        guard self.claudeSwapTransientState.task == nil,
              self.shouldFetchClaudeSwapAccounts(),
              self.availableClaudeSwapStrategies().contains(strategy)
        else {
            return
        }

        let executablePath = self.settings.claudeSwapExecutablePath
        self.claudeSwapTransientState.switchingStrategy = strategy
        self.runClaudeSwapSwitch(executablePath: executablePath, attributingErrorTo: nil) {
            try await ClaudeSwapAccountReader.switchAccount(
                executablePath: executablePath,
                strategy: strategy)
        }
    }

    /// Strategy switches only make sense when claude-swap has somewhere to go.
    func availableClaudeSwapStrategies() -> [ClaudeSwapSwitchStrategy] {
        guard self.shouldFetchClaudeSwapAccounts() else { return [] }
        return ClaudeSwapSwitchMenuPlanner.availableStrategies(accounts: self.claudeSwapAccountSnapshots)
    }

    /// Shared body for both switch entry points: serialize the transaction, run
    /// it to completion, then reconcile the ambient Claude snapshot with the
    /// adapter's active-row marker.
    private func runClaudeSwapSwitch(
        executablePath: String,
        attributingErrorTo accountID: ProviderAccountIdentity?,
        operation: @escaping @Sendable () async throws -> ClaudeSwapAccountSwitchResult)
    {
        self.claudeSwapTransientState.lastError = nil
        self.claudeSwapTransientState.lastErrorAccountID = nil
        // A new switch supersedes the previous one's confirmation and error.
        self.claudeSwapTransientState.lastSwitchOutcome = nil
        self.claudeSwapTransientState.lastSectionError = nil
        self.claudeSwapRevision &+= 1

        self.claudeSwapTransientState.task = Task { @MainActor [weak self] in
            var switchError: String?
            var outcome: ClaudeSwapSwitchOutcome?
            do {
                let result = try await operation()
                // A strategy switch only names its destination in the result, so
                // the confirmation target is derived here rather than up front.
                outcome = ClaudeSwapSwitchOutcome.from(result: result, completedAt: Date())
                // claude-swap reports the current account as the destination for
                // blocked attempts too, so a non-null target is not success.
                if case let .blocked(reason) = ClaudeSwapSwitchResultClassifier.classify(result) {
                    switchError = ClaudeSwapSwitchResultClassifier.blockedExplanation(reason: reason)
                }
            } catch {
                switchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }

            guard let self else { return }
            if self.isCurrentClaudeSwapConfiguration(executablePath: executablePath) {
                // Claude Code owns the ambient credential, so reconcile both
                // the provider snapshot and the adapter's active-row marker.
                await self.refreshProvider(.claude)
            }
            let configurationIsCurrent = self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
            self.claudeSwapTransientState.task = nil
            self.claudeSwapTransientState.switchingAccountID = nil
            self.claudeSwapTransientState.switchingStrategy = nil
            if configurationIsCurrent {
                self.claudeSwapTransientState.lastSwitchOutcome = outcome
                // An error with no owning account card (any strategy switch, and
                // any blocked outcome) is reported on the section instead, so it
                // cannot silently disappear.
                if let switchError, let accountID {
                    self.claudeSwapTransientState.lastError = switchError
                    self.claudeSwapTransientState.lastErrorAccountID = accountID
                    self.claudeSwapTransientState.lastSectionError = nil
                } else {
                    self.claudeSwapTransientState.lastError = nil
                    self.claudeSwapTransientState.lastErrorAccountID = nil
                    self.claudeSwapTransientState.lastSectionError = switchError
                }
            }
            self.claudeSwapRevision &+= 1
        }
    }

    private func probeClaudeSwapVersionIfNeeded(executablePath: String) async {
        guard self.claudeSwapTransientState.versionProbedPath != executablePath else { return }
        self.claudeSwapTransientState.versionProbeGeneration &+= 1
        let generation = self.claudeSwapTransientState.versionProbeGeneration
        guard let version = await ClaudeSwapAccountReader.readVersion(executablePath: executablePath),
              !Task.isCancelled,
              self.claudeSwapTransientState.versionProbeGeneration == generation,
              self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
        else { return }
        self.claudeSwapTransientState.versionProbedPath = executablePath
        self.claudeSwapDetectedVersion = version
    }

    private func isCurrentClaudeSwapRefresh(executablePath: String, generation: UInt64?) -> Bool {
        self.isCurrentProviderRefreshGeneration(.claude, generation: generation) &&
            self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
    }

    private func isCurrentClaudeSwapConfiguration(executablePath: String) -> Bool {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            self.settings.claudeSwapExecutablePath == executablePath
    }
}

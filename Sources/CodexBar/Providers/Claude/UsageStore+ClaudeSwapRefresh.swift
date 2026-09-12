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
            self.claudeSwapTransientState.versionProbedPath != nil ||
            self.claudeSwapDetectedVersion != nil
        self.claudeSwapRefreshTask?.cancel()
        self.claudeSwapRefreshTask = nil
        self.claudeSwapAccountSnapshots = []
        self.claudeSwapLastRefreshAt = nil
        self.claudeSwapLastError = nil
        self.claudeSwapTransientState = ClaudeSwapTransientState(
            task: self.claudeSwapTransientState.task,
            versionProbeGeneration: self.claudeSwapTransientState.versionProbeGeneration &+ 1)
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

    /// Explicit switch where claude-swap chooses the destination slot. Still one
    /// user click and one bounded transaction; only the target selection moves to
    /// the source. claude-swap's background `auto` loop is never started.
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

    func availableClaudeSwapStrategies() -> [ClaudeSwapSwitchStrategy] {
        ClaudeSwapSwitchMenuPlanner.availableStrategies(accounts: self.claudeSwapAccountSnapshots)
    }

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

            // Publish the known result before awaiting any refresh, so a failure
            // is never hidden behind a slow or queued reconcile (#3580).
            if self.isCurrentClaudeSwapConfiguration(executablePath: executablePath) {
                self.claudeSwapTransientState.lastSwitchOutcome = outcome
                // An error with no owning account card (any strategy switch, and
                // any blocked outcome) is reported on the section instead, so it
                // cannot silently disappear.
                if let switchError, let accountID {
                    self.claudeSwapTransientState.lastError = switchError
                    self.claudeSwapTransientState.lastErrorAccountID = accountID
                } else {
                    self.claudeSwapTransientState.lastSectionError = switchError
                }
                self.claudeSwapRevision &+= 1

                // Re-list claude-swap before reconciling ambient Claude usage. The
                // adapter owns the active marker and the numbers the cards render,
                // and re-listing is one short subprocess; the ambient fetch probes
                // OAuth, the CLI and the web and can take seconds. Refreshing
                // ambient first left the cards showing the pre-switch state for
                // that whole window, so a completed switch read as a click that
                // did nothing.
                //
                // Only after a switch that landed: a failed or blocked attempt
                // changed no account state, so re-listing would spend a
                // subprocess to redraw identical cards.
                if switchError == nil {
                    await self.refreshClaudeSwapAccounts()
                }
            }
            self.claudeSwapTransientState.switchingAccountID = nil
            self.claudeSwapTransientState.switchingStrategy = nil
            self.claudeSwapRevision &+= 1

            // Claude Code owns the ambient credential, so it still has to be
            // reconciled. The transaction marker is held until that finishes so
            // two credential writes can never overlap.
            if self.isCurrentClaudeSwapConfiguration(executablePath: executablePath) {
                await self.refreshProvider(.claude)
            }
            // The adapter configuration can change while either refresh runs.
            // Re-check after the awaits rather than trusting a value read before
            // them: a result that no longer belongs to the current configuration
            // must not stay on screen.
            if !self.isCurrentClaudeSwapConfiguration(executablePath: executablePath) {
                self.claudeSwapTransientState.lastError = nil
                self.claudeSwapTransientState.lastErrorAccountID = nil
                self.claudeSwapTransientState.lastSectionError = nil
                self.claudeSwapTransientState.lastSwitchOutcome = nil
            }
            self.claudeSwapTransientState.task = nil
            self.claudeSwapRevision &+= 1
        }
    }

    private func probeClaudeSwapVersionIfNeeded(executablePath: String) async {
        guard self.claudeSwapTransientState.versionProbedPath != executablePath else { return }
        self.claudeSwapTransientState.versionProbeGeneration &+= 1
        let generation = self.claudeSwapTransientState.versionProbeGeneration
        guard let version = await ClaudeSwapAccountReader.readVersion(executablePath: executablePath),
              self.claudeSwapTransientState.versionProbeGeneration == generation,
              self.isCurrentClaudeSwapRefresh(executablePath: executablePath, generation: nil)
        else { return }
        self.claudeSwapTransientState.versionProbedPath = executablePath
        self.claudeSwapDetectedVersion = version
    }

    func isCurrentClaudeSwapRefresh(executablePath: String, generation: UInt64?) -> Bool {
        !Task.isCancelled &&
            self.isCurrentProviderRefreshGeneration(.claude, generation: generation) &&
            self.isCurrentClaudeSwapConfiguration(executablePath: executablePath)
    }

    private func isCurrentClaudeSwapConfiguration(executablePath: String) -> Bool {
        self.isEnabled(.claude) && self.settings.claudeSwapEnabled &&
            self.settings.claudeSwapExecutablePath == executablePath
    }
}

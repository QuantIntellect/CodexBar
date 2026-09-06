import Foundation
import Testing
@testable import CodexBarCore

/// Rows whose live usage is unavailable used to project to `nil`, so the menu
/// card went blank while `cswap list` still showed numbers. These cover the
/// display-only fallback, the real measurement age, spend, and the disabled marker.
struct ClaudeSwapLastGoodProjectionTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_782_158_400)
    private let now = Date(timeIntervalSince1970: 1_782_160_000)

    private func snapshots(for row: ClaudeSwapAccountRow) -> [ProviderAccountUsageSnapshot] {
        ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: row.isActive ? row.number : nil,
                accounts: [row]),
            now: self.now)
    }

    private func lastGood(
        fiveHour: Double? = nil,
        sevenDay: Double? = nil,
        spend: ClaudeSwapSpendWindow? = nil) -> ClaudeSwapLastGoodUsage
    {
        ClaudeSwapLastGoodUsage(
            measurement: ClaudeSwapUsageMeasurement(
                fiveHour: fiveHour.map { ClaudeSwapUsageWindow(usedPercent: $0, resetsAt: nil) },
                sevenDay: sevenDay.map { ClaudeSwapUsageWindow(usedPercent: $0, resetsAt: nil) },
                spend: spend),
            freshness: ClaudeSwapUsageFreshness(fetchedAt: self.fetchedAt, ageSeconds: 1600))
    }

    @Test
    func `a token expired row keeps its last known bars instead of blanking`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .tokenExpired,
            fiveHour: nil,
            sevenDay: nil,
            lastGoodUsage: self.lastGood(fiveHour: 62, sevenDay: 41))).first)

        let snapshot = try #require(account.snapshot)
        #expect(snapshot.primary?.usedPercent == 62)
        #expect(snapshot.secondary?.usedPercent == 41)
        // The card must state the measurement's real age, not the refresh time.
        #expect(snapshot.updatedAt == self.fetchedAt)
        // The row stays non-actionable and keeps explaining why.
        #expect(account.canActivate == false)
        #expect(account.error?.contains("Token expired") == true)
    }

    @Test
    func `a row with neither live nor last known usage still projects to nil`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .noCredentials,
            fiveHour: nil,
            sevenDay: nil)).first)

        #expect(account.snapshot == nil)
    }

    @Test
    func `an ok row is dated by claude swap's own fetch time`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil,
            usageFreshness: ClaudeSwapUsageFreshness(fetchedAt: self.fetchedAt, ageSeconds: 1600))).first)

        #expect(account.snapshot?.updatedAt == self.fetchedAt)
    }

    @Test
    func `an ok row without freshness falls back to the refresh time`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil)).first)

        #expect(account.snapshot?.updatedAt == self.now)
    }

    @Test
    func `spend projects onto the shared provider cost row`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil,
            spend: ClaudeSwapSpendWindow(
                used: 12.5,
                limit: 50,
                usedPercent: 25,
                currencyCode: "USD",
                resetsAt: nil))).first)

        let cost = try #require(account.snapshot?.providerCost)
        #expect(cost.used == 12.5)
        #expect(cost.limit == 50)
        #expect(cost.currencyCode == "USD")
    }

    @Test
    func `an account with only spend still renders a card`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: nil,
            sevenDay: nil,
            spend: ClaudeSwapSpendWindow(
                used: 1,
                limit: 10,
                usedPercent: 10,
                currencyCode: "USD",
                resetsAt: nil))).first)

        #expect(account.snapshot?.providerCost?.used == 1)
    }

    @Test
    func `a disabled account is marked but stays an explicit switch target`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil,
            isDisabled: true)).first)

        #expect(account.displayLabel == "a@b.c (disabled)")
        #expect(account.isHeldOutOfRotation == true)
        #expect(account.canActivate == true)
    }

    @Test
    func `a foreign credential row explains that a switch repairs it`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: true,
            usageStatus: .foreignCredential,
            fiveHour: nil,
            sevenDay: nil,
            lastGoodUsage: self.lastGood(fiveHour: 12))).first)

        #expect(account.error?.contains("different account") == true)
        #expect(account.snapshot?.primary?.usedPercent == 12)
    }
}

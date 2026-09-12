import CoreFoundation
import Foundation

/// How claude-swap should pick the account to activate.
///
/// Every case maps to a fixed argument array. CodexBar never forwards
/// user-supplied arguments, and each of these is still driven by an explicit
/// click — none of them starts claude-swap's background `auto` loop.
public enum ClaudeSwapSwitchStrategy: String, CaseIterable, Equatable, Sendable {
    /// `cswap --switch` — rotate to the next account in slot order.
    case rotate
    /// `cswap --switch --strategy best` — the account with the most quota left.
    case best
    /// `cswap --switch --strategy next-available` — rotate, skipping accounts at their limit.
    case nextAvailable

    /// The exact argument array executed for this strategy.
    public var arguments: [String] {
        switch self {
        case .rotate: ["--switch", "--json"]
        case .best: ["--switch", "--strategy", "best", "--json"]
        case .nextAvailable: ["--switch", "--strategy", "next-available", "--json"]
        }
    }
}

/// Allow-listed result of a `cswap` switch (schema v1).
///
/// `toAccountNumber` is nil only for a strategy switch that found no viable
/// target; a slot-targeted switch always reports the slot it landed on.
public struct ClaudeSwapAccountSwitchResult: Equatable, Sendable {
    public let switched: Bool
    public let fromAccountNumber: Int?
    public let toAccountNumber: Int?
    /// Machine-readable outcome token (e.g. `switched`, `already-active`).
    /// claude-swap's human `message` field is deliberately not parsed: it embeds
    /// the account email, which must not bypass Hide Personal Info.
    public let reason: String

    public init(switched: Bool, fromAccountNumber: Int?, toAccountNumber: Int?, reason: String) {
        self.switched = switched
        self.fromAccountNumber = fromAccountNumber
        self.toAccountNumber = toAccountNumber
        self.reason = reason
    }
}

public enum ClaudeSwapSwitchParserError: LocalizedError, Equatable, Sendable {
    case notJSONObject
    case missingSchemaVersion
    case unsupportedSchemaVersion(Int)
    case reportedError(type: String, message: String)
    case malformedShape(String)
    case mismatchedTarget(expected: Int, actual: Int?)
    case noViableTarget(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notJSONObject:
            "claude-swap returned switch output that is not a JSON object."
        case .missingSchemaVersion:
            "claude-swap switch output has no schemaVersion field."
        case let .unsupportedSchemaVersion(version):
            "claude-swap switch output uses unsupported schema version \(version); CodexBar supports version 1."
        case let .reportedError(type, message):
            "claude-swap reported \(type): \(message)"
        case let .malformedShape(details):
            "claude-swap switch output is malformed: \(details)"
        case let .mismatchedTarget(expected, actual):
            if let actual {
                "claude-swap reported account slot \(actual) after CodexBar requested slot \(expected)."
            } else {
                "claude-swap reported no account slot after CodexBar requested slot \(expected)."
            }
        case let .noViableTarget(reason):
            "claude-swap found no account to switch to (\(reason))."
        }
    }
}

public enum ClaudeSwapSwitchParser {
    public static func parse(_ data: Data) throws -> ClaudeSwapAccountSwitchResult {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClaudeSwapSwitchParserError.notJSONObject
        }
        guard let object = raw as? [String: Any] else {
            throw ClaudeSwapSwitchParserError.notJSONObject
        }
        guard let schemaVersion = self.integer(object["schemaVersion"]) else {
            throw ClaudeSwapSwitchParserError.missingSchemaVersion
        }
        guard schemaVersion == ClaudeSwapListParser.supportedSchemaVersion else {
            throw ClaudeSwapSwitchParserError.unsupportedSchemaVersion(schemaVersion)
        }
        if let errorObject = object["error"] as? [String: Any] {
            throw ClaudeSwapSwitchParserError.reportedError(
                type: errorObject["type"] as? String ?? "Error",
                message: errorObject["message"] as? String ?? "unknown error")
        }
        guard let switched = object["switched"] as? Bool else {
            throw ClaudeSwapSwitchParserError.malformedShape("missing switched flag")
        }
        guard let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty
        else {
            throw ClaudeSwapSwitchParserError.malformedShape("missing reason")
        }
        let fromAccountNumber = try self.accountNumber(
            in: object["from"],
            field: "from",
            allowsNull: true)
        // A strategy switch that finds nothing viable reports `to: null`; a
        // slot-targeted switch always names the slot it landed on. The caller
        // decides which of those it will accept.
        let toAccountNumber = try self.accountNumber(
            in: object["to"],
            field: "to",
            allowsNull: true)
        return ClaudeSwapAccountSwitchResult(
            switched: switched,
            fromAccountNumber: fromAccountNumber,
            toAccountNumber: toAccountNumber,
            reason: reason)
    }

    private static func accountNumber(in raw: Any?, field: String, allowsNull: Bool) throws -> Int? {
        if raw is NSNull, allowsNull { return nil }
        guard let account = raw as? [String: Any] else {
            throw ClaudeSwapSwitchParserError.malformedShape("missing \(field) account")
        }
        guard let rawNumber = account["number"] else {
            throw ClaudeSwapSwitchParserError.malformedShape("\(field) account has no number")
        }
        if rawNumber is NSNull, allowsNull { return nil }
        guard let number = self.integer(rawNumber), number > 0
        else {
            throw ClaudeSwapSwitchParserError.malformedShape("\(field) account number is not a positive slot")
        }
        return number
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return raw as? Int
    }
}

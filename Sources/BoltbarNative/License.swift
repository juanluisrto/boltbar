import CryptoKit
import Foundation

/// A supporter license: a one-off payment that keeps Boltbar going and silences
/// the occasional reminder. Boltbar works the same without one.
struct License: Codable, Equatable {
    var name: String
    var email: String
    var order: String
    /// The day it was issued, as YYYY-MM-DD.
    var issued: String
    var edition: String
    /// Redirects to the Stripe Payment Link, so the price or link can change without a release.
    static let buyURL = URL(string: "https://juanluis.me/boltbar/buy")!
}

/// A license key is `base64url(JSON payload).base64url(Ed25519 signature of the payload)`,
/// made by scripts/make-license.swift. It is checked on this Mac and never sent anywhere.
enum LicenseKey {
    /// Resources/license-public-key.txt, which scripts/configure-bundle.py puts in the bundle's Info.plist.
    /// `swift run` builds have none, so they can't check keys and never ask for support.
    static let bundled = (Bundle.main.object(forInfoDictionaryKey: "BoltbarLicensePublicKey") as? String).flatMap(publicKey)
    static func publicKey(_ base64: String) -> Curve25519.Signing.PublicKey? {
        Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { try? .init(rawRepresentation: $0) }
    }
    static func verify(_ key: String, with publicKey: Curve25519.Signing.PublicKey) throws -> License {
        // Mail clients wrap long lines; a key never contains whitespace.
        let parts = key.filter { !$0.isWhitespace }.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]), signature.count == 64 else {
            throw AppError("That doesn't look like a Boltbar license key.")
        }
        guard publicKey.isValidSignature(signature, for: payload) else { throw AppError("This license key isn't valid for Boltbar.") }
        guard let license = try? JSONDecoder().decode(License.self, from: payload), !license.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AppError("This license key is damaged.")
        }
        return license
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?<S: StringProtocol>(base64URL text: S) {
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}

/// Where the pasted key lives: the Keychain beside the API keys, under its own account.
struct LicenseStore {
    var load: @Sendable (_ allowInteraction: Bool) throws -> String?
    var save: (String) throws -> Void
    var remove: () throws -> Void
    static let keychain = LicenseStore(
        load: { try Keychain.read(account: "license", name: "license", allowInteraction: $0) },
        save: { try Keychain.save($0, account: "license") },
        remove: { try Keychain.delete(account: "license") })
}

enum LicenseState: Equatable {
    /// Not read yet, or the Keychain wants to ask first: either way, don't ask for support.
    case checking, locked(String), unlicensed, licensed(License)
}

/// When an unlicensed copy may ask for support: a week after the first launch and
/// 30 finished replies, then at most once a week.
struct SupportSchedule {
    static let interval: TimeInterval = 7 * 24 * 60 * 60
    static let replies = 30
    let defaults: UserDefaults
    var now: () -> Date = Date.init
    func started() { if defaults.object(forKey: "supportFirstLaunch") == nil { defaults.set(now(), forKey: "supportFirstLaunch") } }
    func replyFinished() { defaults.set(defaults.integer(forKey: "supportReplies") + 1, forKey: "supportReplies") }
    func nudged() { defaults.set(now(), forKey: "supportLastNudge") }
    var due: Bool {
        guard let first = defaults.object(forKey: "supportFirstLaunch") as? Date, now().timeIntervalSince(first) >= Self.interval,
              defaults.integer(forKey: "supportReplies") >= Self.replies else { return false }
        guard let last = defaults.object(forKey: "supportLastNudge") as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.interval
    }
}

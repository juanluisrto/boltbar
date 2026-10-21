// Signs a Boltbar supporter license with the Ed25519 key in the login Keychain and
// prints the key to stdout. Never prints, writes or commits the private key.
//
//   swift scripts/make-license.swift --name "Ada Lovelace" --email ada@example.com --order 1001
//
// Optional: --edition (default supporter), --issued YYYY-MM-DD (default today, UTC).
// The first run creates the key pair in the login Keychain and writes the public key
// to Resources/license-public-key.txt. Later runs check the two still match.
import CryptoKit
import Foundation
import Security

let service = "com.boltbar.license-signing", account = "ed25519"
let publicKeyFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/license-public-key.txt").standardizedFileURL

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-license: \(message)\n".utf8)); exit(1)
}
func note(_ message: String) { FileHandle.standardError.write(Data("\(message)\n".utf8)) }

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard flag.hasPrefix("--"), let value = arguments.popFirst() else { fail("expected --flag value pairs, got \(flag)") }
    options[String(flag.dropFirst(2))] = value
}
let today: String = {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}()
guard let name = options["name"], !name.isEmpty, let email = options["email"], let order = options["order"] else {
    fail("usage: swift scripts/make-license.swift --name NAME --email EMAIL --order ORDER [--edition supporter] [--issued YYYY-MM-DD]")
}
let unknown = Set(options.keys).subtracting(["name", "email", "order", "edition", "issued"])
guard unknown.isEmpty else { fail("unknown option --\(unknown.sorted()[0])") }
let issued = options["issued"] ?? today
guard issued.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { fail("--issued must be YYYY-MM-DD") }

func savedPrivateKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, let raw = Data(base64Encoded: data),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("could not read the signing key from the Keychain (\(status))") }
    return key
}

let committed = (try? String(contentsOf: publicKeyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let privateKey: Curve25519.Signing.PrivateKey
if let saved = savedPrivateKey() {
    privateKey = saved
    if !committed.isEmpty && committed != saved.publicKey.rawRepresentation.base64EncodedString() {
        fail("the Keychain key doesn't match \(publicKeyFile.path); licenses it signs would be rejected")
    }
} else {
    // A new pair would invalidate every license already sold: restore the old key instead.
    guard committed.isEmpty else {
        fail("\(publicKeyFile.path) has a public key but its private key isn't in this Keychain (service \(service), account \(account)). Restore it from your backup.")
    }
    privateKey = Curve25519.Signing.PrivateKey()
    let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecAttrLabel as String: "Boltbar license signing key", kSecAttrDescription as String: "Ed25519 private key",
        kSecValueData as String: Data(privateKey.rawRepresentation.base64EncodedString().utf8)]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("could not save the new signing key in the Keychain (\(status))") }
    do { try (privateKey.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: publicKeyFile, atomically: true, encoding: .utf8) }
    catch { fail("saved the key pair but could not write \(publicKeyFile.path): \(error.localizedDescription)") }
    note("Created a signing key in the login Keychain (\"Boltbar license signing key\") and wrote \(publicKeyFile.path).")
    note("Back it up now: losing it means every license sold must be reissued.")
}

struct License: Codable { var name: String, email: String, order: String, issued: String, edition: String }
extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
let license = License(name: name, email: email, order: order, issued: issued, edition: options["edition"] ?? "supporter")
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let payload = try encoder.encode(license)
let signature = try privateKey.signature(for: payload)
guard privateKey.publicKey.isValidSignature(signature, for: payload) else { fail("the new signature doesn't verify") }
print(payload.base64URL + "." + signature.base64URL)

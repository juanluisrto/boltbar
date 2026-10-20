import CryptoKit
import XCTest
@testable import BoltbarNative

final class LicenseTests: XCTestCase {
    let signer = Curve25519.Signing.PrivateKey()
    let ada = License(name: "Ada Lovelace", email: "ada@example.com", order: "1001", issued: "2026-10-20", edition: "supporter")

    /// The same format scripts/make-license.swift prints.
    func key(_ license: License, signedBy signer: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(license)
        return payload.base64URL + "." + (try signer.signature(for: payload)).base64URL
    }
    func rejects(_ key: String, with publicKey: Curve25519.Signing.PublicKey, _ message: String, line: UInt = #line) {
        XCTAssertThrowsError(try LicenseKey.verify(key, with: publicKey), line: line) { XCTAssertEqual($0.localizedDescription, message, line: line) }
    }

    func testValidKeyVerifiesEvenWhenWrappedByAMailClient() throws {
        let key = try key(ada, signedBy: signer)
        XCTAssertEqual(try LicenseKey.verify(key, with: signer.publicKey), ada)
        let wrapped = "  " + key.enumerated().map { $0.offset > 0 && $0.offset % 40 == 0 ? "\n\($0.element)" : String($0.element) }.joined() + "\n"
        XCTAssertEqual(try LicenseKey.verify(wrapped, with: signer.publicKey), ada)
    }
    func testTamperedKeysAreRejected() throws {
        let parts = try key(ada, signedBy: signer).split(separator: ".").map(String.init)
        // Someone else's name on Ada's signature.
        var forged = ada; forged.name = "Mallory"
        let forgedPayload = try JSONEncoder().encode(forged).base64URL
        rejects(forgedPayload + "." + parts[1], with: signer.publicKey, "This license key isn't valid for Boltbar.")
        var signature = Data(base64URL: parts[1])!; signature[0] ^= 1
        rejects(parts[0] + "." + signature.base64URL, with: signer.publicKey, "This license key isn't valid for Boltbar.")
    }
    func testKeySignedByAnotherKeyIsRejected() throws {
        let key = try key(ada, signedBy: Curve25519.Signing.PrivateKey())
        rejects(key, with: signer.publicKey, "This license key isn't valid for Boltbar.")
    }
    func testMalformedKeysAreRejected() throws {
        for text in ["", "hello", "a.b.c", "!!!.???", "eyJuYW1lIjoiQSJ9.c2hvcnQ"] {
            rejects(text, with: signer.publicKey, "That doesn't look like a Boltbar license key.")
        }
        // Signed but not a license: still refused.
        let payload = Data("not json".utf8)
        rejects(payload.base64URL + "." + (try signer.signature(for: payload)).base64URL, with: signer.publicKey, "This license key is damaged.")
    }
    func testCommittedPublicKeyIsAnEd25519Key() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/license-public-key.txt")
        XCTAssertNotNil(LicenseKey.publicKey(try String(contentsOf: file, encoding: .utf8)))
        XCTAssertNil(LicenseKey.publicKey("not a key"))
    }

    // MARK: When to ask

    func testScheduleWaitsAWeekAndThirtyReplies() {
        let (defaults, suite) = fresh()
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        var schedule = SupportSchedule(defaults: defaults); schedule.now = { now }
        schedule.started()
        for _ in 0..<29 { schedule.replyFinished() }
        now += SupportSchedule.interval
        XCTAssertFalse(schedule.due, "29 replies")
        schedule.replyFinished()
        XCTAssertTrue(schedule.due)
        now -= 1
        XCTAssertFalse(schedule.due, "a second short of a week")
        // A later launch doesn't restart the week.
        now += 2; schedule.started()
        XCTAssertTrue(schedule.due)
    }
    func testScheduleAsksAtMostOnceAWeek() {
        let (defaults, suite) = fresh()
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        var schedule = SupportSchedule(defaults: defaults); schedule.now = { now }
        schedule.started()
        for _ in 0..<30 { schedule.replyFinished() }
        now += SupportSchedule.interval
        schedule.nudged()
        now += SupportSchedule.interval - 60
        XCTAssertFalse(schedule.due)
        now += 60
        XCTAssertTrue(schedule.due)
    }
    func testScheduleNeverAsksBeforeTheFirstLaunchIsRecorded() {
        let (defaults, suite) = fresh()
        defer { defaults.removePersistentDomain(forName: suite) }
        let schedule = SupportSchedule(defaults: defaults)
        for _ in 0..<100 { schedule.replyFinished() }
        XCTAssertFalse(schedule.due)
    }

    // MARK: The reminder in the bar

    @MainActor func testThirtiethReplyBringsTheReminder() async throws {
        let (model, defaults, suite) = await unlicensedModel(replies: SupportSchedule.replies - 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.draft = "Hi"; model.send()
        await settle(model)
        XCTAssertEqual(model.notice?.actions.map(\.title), ["Buy", "Enter key", "Not now"])
        // Not now just dismisses; the next reply in the same week stays quiet.
        model.perform(model.notice!.actions[2])
        XCTAssertNil(model.notice)
        model.draft = "Again"; model.send()
        await settle(model)
        XCTAssertNil(model.notice)
    }
    @MainActor func testEnterKeyOpensSettingsAtTheLicense() async throws {
        let (model, defaults, suite) = await unlicensedModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        var opened = false; model.openSettings = { opened = true }
        model.askForSupportIfDue()
        model.perform(try XCTUnwrap(model.notice?.actions.first { $0.title == "Enter key" }))
        XCTAssertTrue(opened)
        XCTAssertEqual(model.settingsTarget, "license")
        XCTAssertNil(model.notice)
    }
    @MainActor func testValidLicenseSilencesTheReminder() async throws {
        let (model, defaults, suite) = await unlicensedModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.askForSupportIfDue()
        XCTAssertNotNil(model.notice)
        XCTAssertThrowsError(try model.enterLicense(try key(ada, signedBy: Curve25519.Signing.PrivateKey())))
        XCTAssertEqual(model.licenseState, .unlicensed)
        try model.enterLicense(try key(ada, signedBy: signer))
        XCTAssertEqual(model.license, ada)
        XCTAssertNil(model.notice, "entering a key takes the reminder away")
        model.draft = "Hi"; model.send()
        await settle(model)
        XCTAssertNil(model.notice)
        // Removing it brings the reminder back on the same terms.
        try model.removeLicense()
        model.support.now = { Date() + 3 * SupportSchedule.interval }
        model.askForSupportIfDue()
        XCTAssertNotNil(model.notice)
    }
    @MainActor func testNoReminderDuringAReplyOrAPermissionRequest() async throws {
        let started = expectation(description: "reply started")
        let (model, defaults, suite) = await unlicensedModel(streamer: { _, _ in started.fulfill(); try await Task.sleep(nanoseconds: 5_000_000_000) })
        defer { defaults.removePersistentDomain(forName: suite) }
        model.draft = "Hi"; model.send()
        await fulfillment(of: [started], timeout: 2)
        model.askForSupportIfDue()
        XCTAssertNil(model.notice, "while streaming")
        model.stop()
        let asking = Task { await model.askApproval(ApprovalRequest(id: "1", action: "Run", subject: "ls", directory: "/")) }
        while model.pendingApproval == nil { await Task.yield() }
        model.askForSupportIfDue()
        XCTAssertNil(model.notice, "while a permission request waits")
        model.resolveApproval(.deny); _ = await asking.value
        model.barHidden()
        model.askForSupportIfDue()
        XCTAssertNil(model.notice, "while the bar is hidden")
        model.summon()
        model.askForSupportIfDue()
        XCTAssertNotNil(model.notice, "otherwise it was due")
    }
    @MainActor func testLaunchReadsTheSavedLicense() async throws {
        let (defaults, suite) = fresh()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ChatModel(defaults: defaults)
        model.licensePublicKey = signer.publicKey
        let saved = SavedKey()
        model.licenseStore = saved.store
        await model.loadLicense()
        XCTAssertEqual(model.licenseState, .unlicensed)
        XCTAssertNotNil(defaults.object(forKey: "supportFirstLaunch"))
        saved.value = try key(ada, signedBy: signer)
        await model.loadLicense()
        XCTAssertEqual(model.license, ada)
        saved.value = try key(ada, signedBy: Curve25519.Signing.PrivateKey())
        await model.loadLicense()
        XCTAssertEqual(model.licenseState, .unlicensed)
        model.support.now = { Date() + 2 * SupportSchedule.interval }
        for _ in 0..<SupportSchedule.replies { model.support.replyFinished() }
        saved.error = AppError("Approve access to the saved license in Settings.")
        await model.loadLicense()
        XCTAssertEqual(model.licenseState, .locked("Approve access to the saved license in Settings."))
        model.askForSupportIfDue()
        XCTAssertNil(model.notice, "a license the Keychain won't show yet may well exist")
        saved.error = nil; saved.value = nil
        await model.loadLicense()
        model.askForSupportIfDue()
        XCTAssertNotNil(model.notice, "otherwise it was due")
    }
    @MainActor func testPlainNoticeHasNoActions() {
        let model = ChatModel(defaults: UserDefaults(suiteName: "com.boltbar.tests.notice.\(UUID())")!)
        model.copyTerminalCommand()
        XCTAssertEqual(model.notice?.text, "No agent session yet: send a message in agent mode first.")
        XCTAssertEqual(model.notice?.actions.isEmpty, true)
    }

    // MARK: Helpers

    func fresh() -> (UserDefaults, String) {
        let suite = "com.boltbar.tests.license.\(UUID())"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    /// An unlicensed copy exactly a week after its first launch.
    @MainActor func unlicensedModel(replies: Int = SupportSchedule.replies, streamer: @escaping ChatModel.Streamer = { _, delta in await delta(.text("OK")) }) async -> (ChatModel, UserDefaults, String) {
        let (defaults, suite) = fresh()
        let model = ChatModel(defaults: defaults, streamer: streamer)
        model.licensePublicKey = signer.publicKey
        model.licenseStore = SavedKey().store
        let launched = Date()
        model.support.now = { launched }
        await model.loadLicense()
        for _ in 0..<replies { model.support.replyFinished() }
        model.support.now = { launched + SupportSchedule.interval }
        return (model, defaults, suite)
    }
    @MainActor func settle(_ model: ChatModel) async {
        for _ in 0..<500 where model.streaming { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertFalse(model.streaming)
    }
}

/// The Keychain item, in memory.
final class SavedKey: @unchecked Sendable {
    var value: String?
    var error: Error?
    var store: LicenseStore {
        LicenseStore(load: { _ in if let error = self.error { throw error }; return self.value },
            save: { self.value = $0 }, remove: { self.value = nil })
    }
}

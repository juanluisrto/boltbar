import XCTest
@testable import BoltbarNative

final class ProcessTests: XCTestCase {
    func testAllCLITransportsKeepLargeDocumentsOffArgumentList() throws {
        let document = try Attachment(name: "large.txt", mime: "text/plain", data: Data(repeating: 65, count: 1_048_576))
        for provider in Provider.allCases {
            let request = ChatRequest(provider: provider, model: provider.defaults[0], effort: .low, transport: .cli,
                messages: [Message(role: .user, text: "Summarize", attachments: [document])])
            let arguments: [String], input: Data
            if provider == .openai {
                arguments = CodexChat.arguments
                input = try JSONSerialization.data(withJSONObject: CLIInput.blocks(request, codex: true))
            } else {
                let invocation = try CLI.invocation(request); arguments = invocation.arguments; input = invocation.input
            }
            XCTAssertLessThan(arguments.joined().utf8.count, 2048)
            XCTAssertGreaterThan(input.count, document.data.count)
            XCTAssertTrue(String(decoding: input, as: UTF8.self).contains("Attached document large.txt:"))
        }
    }
    func testCaptureKeepsWhatACLIPrintsOnStderr() async throws {
        // `codex login status` says "Logged in using ChatGPT" on stderr.
        let output = try await CLI.capture("/bin/sh", args: ["-c", "echo on-stdout; echo on-stderr >&2"])
        XCTAssertTrue(output.contains("on-stdout") && output.contains("on-stderr"), output)
    }
    func testProcessDrainsInputLargerThanPipeAndArgumentLimits() async throws {
        let input = Data(repeating: 65, count: 2_097_152)
        let child = try LineProcess(program: "/usr/bin/wc", args: ["-c"], stdin: input)
        defer { child.cancel() }
        var output = ""
        for try await line in child.lines { output += line }
        XCTAssertEqual(Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), input.count)
    }
}

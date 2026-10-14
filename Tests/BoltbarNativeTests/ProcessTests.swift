import XCTest
@testable import BoltbarNative

final class ProcessTests: XCTestCase {
    func testAllCLITransportsKeepLargeDocumentsOffArgumentList() throws {
        let document = try Attachment(name: "large.txt", mime: "text/plain", data: Data(repeating: 65, count: 1_048_576))
        for provider in Provider.allCases {
            let request = ChatRequest(provider: provider, model: provider.defaults[0], effort: .low, transport: .cli,
                messages: [Message(role: .user, text: "Summarize", attachments: [document])])
            let invocation = try CLI.invocation(request)
            XCTAssertLessThan(invocation.arguments.joined().utf8.count, 2048)
            XCTAssertGreaterThan(invocation.input.count, document.data.count)
            XCTAssertTrue(String(decoding: invocation.input, as: UTF8.self).contains("Attached document large.txt:"))
        }
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

import Foundation

/// Bounded, opt-in developer probe using the same transport as the UI.
/// Only pass synthetic fixtures: the optional response text is saved by the caller.
enum QAProbe {
    @MainActor static func run() async {
        let args = CommandLine.arguments
        let provider = args.count > 2 ? Provider(rawValue: args[2]) ?? .openai : .openai
        let model = args.count > 3 ? args[3] : provider.defaults[0]
        let files = Array(args.dropFirst(min(4, args.count)))
        let start = ProcessInfo.processInfo.systemUptime
        var first: Double?, count = 0, text = ""
        do {
            let attachments = try files.map { try Attachment(url: URL(fileURLWithPath: $0)) }
            let prompt = attachments.isEmpty ? "Print the integers 1 through 40, separated by spaces. No other text." : "Briefly describe the attached icon and state the document's control word. Answer in English."
            let request = ChatRequest(provider: provider, model: model, effort: .low,
                transport: ProcessInfo.processInfo.environment["BOLTBAR_QA_TRANSPORT"] == "cli" ? .cli : .automatic,
                messages: [Message(role: .user, text: prompt, attachments: attachments)])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Providers.stream(request) { delta in
                        await MainActor.run {
                            if first == nil { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                            count += 1; text += delta
                        }
                    }
                }
                group.addTask { try await Task.sleep(nanoseconds: 90_000_000_000); throw AppError("QA probe timed out.") }
                defer { group.cancelAll() }
                try await group.next()
            }
            var result: [String: Any] = ["provider": provider.rawValue, "model": model, "completed": true, "deltas": count,
                "ttft_ms": first ?? -1, "total_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000]
            if !attachments.isEmpty { result["synthetic_response"] = text; result["control_word_found"] = text.uppercased().contains("ZAFIRO") }
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!); fflush(stdout); exit(0)
        } catch {
            print("QA probe failed: \(error.localizedDescription)"); fflush(stdout); exit(1)
        }
    }
}

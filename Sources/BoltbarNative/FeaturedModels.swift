import Foundation

/// Bundled suggestions and display-name helpers. The synced catalog and user
/// shortlist are independent of these defaults.
enum FeaturedModels {
    static let families = ["astra", "sol", "luna"]
    static let fallback = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"]
    static func parts(_ id: String) -> (version: [Int], family: String)? {
        let pieces = id.split(separator: "-")
        guard pieces.count == 3, pieces[0] == "gpt", families.contains(String(pieces[2])) else { return nil }
        let components = pieces[1].split(separator: ".", omittingEmptySubsequences: false)
        let version = components.compactMap { Int($0) }
        guard !version.isEmpty, version.count == components.count, version.allSatisfy({ $0 >= 0 }) else { return nil }
        return (version, String(pieces[2]))
    }
    static func latest(_ ids: [String]) -> [String] {
        families.compactMap { family in
            ids.filter { parts($0)?.family == family }.max { left, right in
                let a = parts(left)!.version, b = parts(right)!.version
                for index in 0..<max(a.count, b.count) {
                    let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
                    if x != y { return x < y }
                }
                return left < right
            }
        }
    }
}

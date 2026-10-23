import Foundation

public enum AppVersion {
    /// Compares dotted numeric versions ("1.10.0" > "1.2.0"); a leading "v" and missing parts are fine.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

/// The bits of GitHub's "latest release" response that Isle uses.
public struct ReleaseInfo: Equatable {
    public var version: String
    public var pageURL: URL
    public var notes: String

    /// The release page is opened in the browser, so only an https github.com address is accepted.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:)),
              (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true,
              page.scheme == "https", page.host?.lowercased() == "github.com" else { return nil }
        return ReleaseInfo(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")), pageURL: page, notes: (obj["body"] as? String) ?? "")
    }
}

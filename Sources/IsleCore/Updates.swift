import CryptoKit
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
    /// The release's `Isle-<version>.zip` and its `.zip.sig` signature, when both are attached (https, github.com only).
    public var zipURL: URL?
    public var signatureURL: URL?

    public init(version: String, pageURL: URL, notes: String, zipURL: URL? = nil, signatureURL: URL? = nil) {
        self.version = version; self.pageURL = pageURL; self.notes = notes; self.zipURL = zipURL; self.signatureURL = signatureURL
    }

    static func trusted(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
        return url
    }

    /// The release page is opened in the browser, so only an https github.com address is accepted.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = trusted((obj["html_url"] as? String).flatMap(URL.init(string:))),
              (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true else { return nil }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        func asset(_ suffix: String) -> URL? {
            assets.compactMap { a -> URL? in
                guard let name = a["name"] as? String, name.hasPrefix("Isle-"), name.hasSuffix(suffix),
                      !(suffix == ".zip" && name.hasSuffix(".zip.sig")) else { return nil }
                return trusted((a["browser_download_url"] as? String).flatMap(URL.init(string:)))
            }.first
        }
        return ReleaseInfo(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")), pageURL: page,
                           notes: (obj["body"] as? String) ?? "", zipURL: asset(".zip"), signatureURL: asset(".zip.sig"))
    }
}

/// Checks that a downloaded update was signed by the developer. A code signature on its own proves nothing for a locally
/// signed app, so updates carry an Ed25519 signature (`<zip>.sig`, base64) made with a private key only the developer holds.
public enum UpdateSignature {
    /// Public half of the update-signing key.
    public static let publicKey = "rrWyWDN4lucczuUJQAKRODmHecakqtCCVn4axkf8WZI="

    public static func isValid(signature: Data, for payload: Data, publicKey: String = UpdateSignature.publicKey) -> Bool {
        guard let keyBytes = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let text = String(data: signature, encoding: .utf8),
              let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(sig, for: payload)
    }
}

//
//  PKCE.swift
//  SpotifyRecs
//

import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) helpers.
enum PKCE {
    /// A high-entropy verifier using only unreserved URL characters (43–128 chars).
    static func makeCodeVerifier(byteCount: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func makeState() -> String {
        makeCodeVerifier(byteCount: 16)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

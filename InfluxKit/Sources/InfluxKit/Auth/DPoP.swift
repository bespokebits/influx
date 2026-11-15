import Foundation

/// DPoP proofs (RFC 9449): a short JWT, signed by the key the tokens are
/// bound to, sent with every token and resource request.
enum DPoP {
    struct Header: Codable, Hashable {
        var typ = "dpop+jwt"
        var alg = "ES256"
        var jwk: JWK
    }

    struct Claims: Codable, Hashable {
        /// Unique per proof, so a server can refuse replays.
        var jti: String
        var htm: String
        var htu: String
        var iat: Int
        /// The server's latest nonce, once it has sent one.
        var nonce: String?
        /// base64url(SHA-256(access token)), on resource requests only.
        var ath: String?
    }

    /// A proof for one request. `htu` is the URL without its query or
    /// fragment, as the RFC requires.
    static func proof(
        key: any DPoPKey, method: String, url: URL, nonce: String?, accessToken: String?,
        crypto: OAuthCrypto, now: Date
    ) throws -> String {
        let claims = Claims(
            jti: crypto.randomToken(bytes: 16),
            htm: method.uppercased(),
            htu: requestTarget(url),
            iat: Int(now.timeIntervalSince1970),
            nonce: nonce,
            ath: accessToken.map { crypto.sha256(Data($0.utf8)).base64URLEncoded }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signingInput = try encoder.encode(Header(jwk: key.publicJWK)).base64URLEncoded
            + "." + encoder.encode(claims).base64URLEncoded
        let signature = try key.sign(Data(signingInput.utf8))
        return signingInput + "." + signature.base64URLEncoded
    }

    static func requestTarget(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension HTTPURLResponse {
    /// A header by name, ignoring case.
    func header(_ name: String) -> String? {
        value(forHTTPHeaderField: name)
    }
}

extension URLRequest {
    /// A form-encoded POST (`application/x-www-form-urlencoded`).
    static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(fields).utf8)
        return request
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        // RFC 3986 unreserved characters pass through; everything else,
        // including "+", "&" and "=", is percent-encoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }
        return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}

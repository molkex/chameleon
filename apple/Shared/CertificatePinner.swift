import Foundation
import Security
import CryptoKit

final class CertificatePinner: NSObject, URLSessionDelegate {
    /// SHA256 hashes of the Subject Public Key Info (SPKI) for pinned certificates.
    /// Generate with:
    /// openssl s_client -connect mdfrog.site:443 | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64
    static let pinnedHashes: [String] = [
        // TODO: Add actual certificate hash before production release
        // "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    ]

    /// When pinned hashes are empty, pinning is disabled (development mode)
    static var isPinningEnabled: Bool {
        !pinnedHashes.isEmpty
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // If pinning not configured, use default validation
        guard Self.isPinningEnabled else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the server trust
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check if any certificate in the chain matches our pins
        let certificateCount = SecTrustGetCertificateCount(serverTrust)
        for i in 0..<certificateCount {
            guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  i < chain.count else { continue }
            let certificate = chain[i]

            // Get the public key
            guard let publicKey = SecCertificateCopyKey(certificate) else { continue }
            guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { continue }

            // Hash the public key
            let hash = SHA256.hash(data: publicKeyData)
            let hashBase64 = Data(hash).base64EncodedString()

            if Self.pinnedHashes.contains(hashBase64) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pin matched
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

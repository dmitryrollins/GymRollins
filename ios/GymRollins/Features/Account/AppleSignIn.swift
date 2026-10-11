import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

/// Nonce for Sign in with Apple via Supabase: Apple gets the SHA-256 hash in the request, Supabase gets the raw
/// value with the identity token and checks that they match (replay protection).
enum AppleNonce {
    static let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    enum Failure: Error { case randomUnavailable(OSStatus) }

    /// A cryptographically random string drawn from `charset`.
    static func random(length: Int = 32) throws -> String {
        precondition(length > 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Failure.randomUnavailable(status) }
        // 256 is a multiple of the 64-character charset, so the modulo keeps the distribution uniform.
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    /// Lowercase hex SHA-256 of the UTF-8 string.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// "Sign in with Apple" wired to Supabase: generates a fresh nonce per attempt and hands the identity token plus
/// the raw nonce to `onToken`. Failures (other than the user cancelling) go to `onError` with a readable message.
struct AppleSignInButton: View {
    let onToken: (_ idToken: String, _ rawNonce: String) -> Void
    let onError: (String) -> Void
    @State private var rawNonce: String?

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            do {
                let nonce = try AppleNonce.random()
                rawNonce = nonce
                request.requestedScopes = [.email]
                request.nonce = AppleNonce.sha256(nonce)
            } catch {
                onError("Couldn't start Sign in with Apple. Please try again.")
            }
        } onCompletion: { result in
            handle(result)
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 50)
        .accessibilityIdentifier("account.apple")
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8),
                  let nonce = rawNonce
            else {
                onError("Couldn't sign in with Apple. Please try again.")
                return
            }
            onToken(token, nonce)
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            onError("Couldn't sign in with Apple. Please try again.")
        }
    }
}

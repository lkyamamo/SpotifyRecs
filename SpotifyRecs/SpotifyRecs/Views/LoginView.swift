//
//  LoginView.swift
//  SpotifyRecs
//

import SwiftUI

struct LoginView: View {
    let auth: SpotifyAuth
    @State private var errorMessage: String?
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            VStack(spacing: 8) {
                Text("SpotifyRecs")
                    .font(.largeTitle.bold())
                Text("Discover new music from your listening history, matched with Last.fm’s similar artists and tags.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !AppConfig.missingKeys.isEmpty {
                Label(
                    "Missing \(AppConfig.missingKeys.joined(separator: ", ")). Copy Secrets.example.xcconfig to Secrets.xcconfig and rebuild.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            Spacer()

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await signIn() }
            } label: {
                Group {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Text("Sign in with Spotify")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isSigningIn || !AppConfig.missingKeys.isEmpty)
        }
        .padding(24)
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
            errorMessage = nil
        } catch SpotifyAuthError.cancelled {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

//
//  ContentView.swift
//  SpotifyRecs
//
//  Created by Logan Yamamoto on 7/24/24.
//

import SwiftUI

struct ContentView: View {
    @State private var auth: SpotifyAuth
    @State private var app: AppModel

    init() {
        let auth = SpotifyAuth()
        _auth = State(initialValue: auth)
        _app = State(initialValue: AppModel(auth: auth))
    }

    var body: some View {
        if auth.isSignedIn {
            GenresView(app: app)
        } else {
            LoginView(auth: auth)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [GenrePreference.self, ShownTrack.self], inMemory: true)
}

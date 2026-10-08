//
//  SpotifyRecsApp.swift
//  SpotifyRecs
//
//  Created by Logan Yamamoto on 7/24/24.
//

import SwiftData
import SwiftUI

@main
struct SpotifyRecsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [GenrePreference.self, ShownTrack.self])
    }
}

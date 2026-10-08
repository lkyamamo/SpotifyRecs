//
//  GenresView.swift
//  SpotifyRecs
//
//  Home screen: request genres and jump into each one's recommendations.
//

import SwiftData
import SwiftUI

struct GenresView: View {
    let app: AppModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GenrePreference.createdAt, order: .reverse) private var genres: [GenrePreference]

    @State private var newGenre = ""
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var path: [GenrePreference] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack {
                        TextField("Add a genre — e.g. dubstep, J-rock", text: $newGenre)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { Task { await addGenre(newGenre) } }
                        if isResolving {
                            ProgressView()
                        } else {
                            Button("Add") { Task { await addGenre(newGenre) } }
                                .disabled(GenreNames.key(newGenre).isEmpty)
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    suggestions
                } header: {
                    Text("Request a genre")
                }

                if !genres.isEmpty {
                    Section("Your genres") {
                        ForEach(genres) { genre in
                            NavigationLink(value: genre) {
                                GenreRow(genre: genre, store: FeedbackStore(context: modelContext))
                            }
                        }
                        .onDelete { offsets in
                            let store = FeedbackStore(context: modelContext)
                            offsets.map { genres[$0] }.forEach(store.deleteGenre)
                        }
                    }
                }
            }
            .navigationTitle("Genres")
            .navigationDestination(for: GenrePreference.self) { genre in
                GenreDetailView(genre: genre, app: app, store: FeedbackStore(context: modelContext))
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh My Taste", systemImage: "arrow.clockwise") {
                            Task { _ = try? await app.loadTasteContext(forceRefresh: true) }
                        }
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            app.signOut()
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .task { _ = try? await app.loadTasteContext() }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let existing = Set(genres.map(\.key))
        let picks = app.suggestedGenres.filter { !existing.contains(GenreNames.key($0)) }
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("From your listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(picks, id: \.self) { tag in
                            Button(GenreNames.displayName(tag)) {
                                Task { await addGenre(tag) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .disabled(isResolving)
        }
    }

    private func addGenre(_ input: String) async {
        let key = GenreNames.key(input)
        guard !key.isEmpty, !isResolving else { return }
        if let existing = genres.first(where: { $0.key == key }) {
            path.append(existing)
            newGenre = ""
            return
        }

        isResolving = true
        defer { isResolving = false }
        do {
            let tag = try await app.resolveGenre(input)
            let genre = GenrePreference(key: key, displayName: GenreNames.displayName(input), lastFMTag: tag)
            modelContext.insert(genre)
            try? modelContext.save()
            newGenre = ""
            errorMessage = nil
            path.append(genre)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GenreRow: View {
    let genre: GenrePreference
    let store: FeedbackStore

    var body: some View {
        let stats = store.batchStats(genreKey: genre.key)
        let liked = stats.reduce(0) { $0 + $1.liked }
        VStack(alignment: .leading, spacing: 2) {
            Text(genre.displayName)
                .font(.body.weight(.medium))
            Text(subtitle(batches: stats.count, liked: liked))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(batches: Int, liked: Int) -> String {
        guard batches > 0 else { return "Last.fm tag: \(genre.lastFMTag) · not run yet" }
        let last = genre.lastRunAt.map { " · last run \($0.formatted(.relative(presentation: .named)))" } ?? ""
        return "\(batches) batch\(batches == 1 ? "" : "es") · \(liked) liked\(last)"
    }
}

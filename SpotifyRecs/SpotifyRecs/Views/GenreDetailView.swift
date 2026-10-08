//
//  GenreDetailView.swift
//  SpotifyRecs
//

import Charts
import SwiftUI

struct GenreDetailView: View {
    @State private var model: GenreViewModel
    @Environment(\.openURL) private var openURL

    init(genre: GenrePreference, app: AppModel, store: FeedbackStore) {
        _model = State(initialValue: GenreViewModel(genre: genre, app: app, store: store))
    }

    var body: some View {
        List {
            if let message = model.statusMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            switch model.state {
            case .idle:
                Section {
                    Button {
                        Task { await model.generate() }
                    } label: {
                        Label("Find \(model.genre.displayName) for me", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .listRowBackground(Color.clear)
                }
            case .loading(let stage):
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(stage.rawValue)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await model.generate() } }
                }
            case .loaded:
                Section {
                    ForEach(model.recommendations) { rec in
                        RecommendationRow(
                            recommendation: rec,
                            feedback: model.feedback[rec.id] ?? 0,
                            onOpen: { if let url = rec.track.spotifyURL { openURL(url) } },
                            onFeedback: { model.setFeedback($0, for: rec) }
                        )
                    }
                } header: {
                    Text("Rate songs to teach the model · \(model.recommendations.filter(\.isExploration).count) are exploration picks")
                }
            }

            LearnedSection(insights: model.insights)
        }
        .navigationTitle(model.genre.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.generate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .accessibilityLabel("New batch")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if case .loaded = model.state {
                Button {
                    Task { await model.addToPlaylist() }
                } label: {
                    Group {
                        if model.isAddingToPlaylist {
                            ProgressView()
                        } else {
                            Label("Add to \(model.genre.playlistName)", systemImage: "plus.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(model.isAddingToPlaylist)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct RecommendationRow: View {
    let recommendation: Recommendation
    let feedback: Int
    let onOpen: () -> Void
    let onFeedback: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AsyncImage(url: recommendation.track.artworkURL()) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(recommendation.track.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            if recommendation.isExploration {
                                Text("Explore")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(recommendation.track.artists.map(\.name).joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(recommendation.explanation)
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 10) {
                feedbackButton(value: 1, symbol: "hand.thumbsup", label: "Like")
                feedbackButton(value: -1, symbol: "hand.thumbsdown", label: "Dislike")
            }
        }
        .padding(.vertical, 2)
    }

    private func feedbackButton(value: Int, symbol: String, label: String) -> some View {
        Button {
            onFeedback(value)
        } label: {
            Image(systemName: feedback == value ? "\(symbol).fill" : symbol)
                .foregroundStyle(feedback == value ? (value > 0 ? Color.green : Color.red) : Color.secondary)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityAddTraits(feedback == value ? .isSelected : [])
    }
}

/// What the model has picked up from your ratings, plus like-rate per batch.
private struct LearnedSection: View {
    let insights: GenreViewModel.Insights

    var body: some View {
        Section {
            if insights.ratedCount == 0 {
                Text("Rate a few songs (or remove ones you don’t like from the playlist) and this will show what the model has learned.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Based on \(insights.ratedCount) rated song\(insights.ratedCount == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !insights.likedTags.isEmpty {
                    tagLine(title: "Boosting", tags: insights.likedTags, symbol: "arrow.up.circle")
                }
                if !insights.dislikedTags.isEmpty {
                    tagLine(title: "Avoiding", tags: insights.dislikedTags, symbol: "arrow.down.circle")
                }
                ForEach(insights.habits, id: \.self) { habit in
                    Label(habit, systemImage: "lightbulb")
                        .font(.subheadline)
                }
                let rated = insights.stats.filter { $0.likeRate != nil }
                if !rated.isEmpty {
                    LikeRateChart(stats: rated)
                }
            }
        } header: {
            Text("What I’ve learned")
        }
    }

    private func tagLine(title: String, tags: [String], symbol: String) -> some View {
        Label {
            Text("\(title): ").font(.subheadline.weight(.medium))
                + Text(tags.joined(separator: ", ")).font(.subheadline)
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// Single-series bar chart: share of rated songs liked, per batch. Rising bars mean it's learning.
private struct LikeRateChart: View {
    let stats: [BatchStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Liked share of rated songs, per batch")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(stats) { stat in
                BarMark(
                    x: .value("Batch", "#\(stat.index)"),
                    y: .value("Liked %", (stat.likeRate ?? 0) * 100),
                    width: .ratio(0.5)
                )
                .cornerRadius(4)
                .foregroundStyle(Color.green)
                .accessibilityLabel("Batch \(stat.index)")
                .accessibilityValue("\(stat.liked) of \(stat.rated) rated songs liked")
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            .frame(height: 140)

            if let last = stats.last {
                Text("Latest batch: \(last.liked) of \(last.rated) rated songs liked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

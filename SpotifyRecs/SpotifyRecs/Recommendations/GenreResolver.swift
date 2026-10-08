//
//  GenreResolver.swift
//  SpotifyRecs
//
//  Maps what the user types ("Jrock", "drum n bass") onto the Last.fm tag with the most data.
//

import Foundation

enum GenreNames {
    /// Stable key for a user-entered genre: lowercase, single spaces.
    static func key(_ input: String) -> String {
        input.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Spelling variants to try on Last.fm, most likely first.
    static func variants(for input: String) -> [String] {
        let base = key(input)
        let hyphenated = base.replacingOccurrences(of: " ", with: "-")
        let spaced = base.replacingOccurrences(of: "-", with: " ")
        let squashed = base.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let aliasKey = squashed.replacingOccurrences(of: "&", with: "and")

        let result = [base, hyphenated, spaced, squashed] + (aliases[aliasKey] ?? [])
        var seen = Set<String>()
        return result.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static let aliases: [String: [String]] = [
        "jrock": ["j-rock", "japanese rock"],
        "jpop": ["j-pop", "japanese pop"],
        "kpop": ["k-pop"],
        "cpop": ["c-pop"],
        "dnb": ["drum and bass"],
        "drumnbass": ["drum and bass"],
        "drumandbass": ["drum and bass"],
        "hiphop": ["hip-hop", "hip hop"],
        "rnb": ["rnb", "r&b"],
        "randb": ["rnb", "r&b"],
        "lofi": ["lo-fi"],
        "electronicdancemusic": ["edm"],
        "synthwave": ["synthwave", "retrowave"],
        "citypop": ["city pop"],
    ]

    /// Filters out tags that describe era, origin, or vocals rather than a sound.
    static func isGenreTag(_ tag: String) -> Bool {
        if TasteAnalyzer.ignoredTags.contains(tag) || nonGenreTags.contains(tag) { return false }
        // Decades / years: "80s", "1990s", "2010"
        return tag.range(of: #"^(\d{2}|\d{4})s?$"#, options: .regularExpression) == nil
    }

    private static let nonGenreTags: Set<String> = [
        "female vocalists", "male vocalists", "female vocalist", "male vocalist", "vocalists",
        "british", "american", "uk", "usa", "canadian", "australian", "swedish", "norwegian",
        "icelandic", "irish", "scottish", "german", "french", "japanese", "korean", "brazilian",
        "new zealand", "english", "all", "music", "good",
    ]

    static func displayName(_ input: String) -> String {
        let special = ["edm": "EDM", "r&b": "R&B", "rnb": "R&B", "idm": "IDM", "dnb": "DnB",
                       "jrock": "J-Rock", "j-rock": "J-Rock", "jpop": "J-Pop", "j-pop": "J-Pop",
                       "kpop": "K-Pop", "k-pop": "K-Pop"]
        let key = key(input)
        return special[key] ?? key.capitalized
    }
}

enum GenreResolverError: LocalizedError {
    case unknownGenre(String)

    var errorDescription: String? {
        switch self {
        case .unknownGenre(let genre): "Last.fm doesn’t have enough data for “\(genre)”. Try another spelling."
        }
    }
}

struct GenreResolver {
    let lastFM: LastFMProviding

    /// Returns the Last.fm tag with the highest reach among the input's spelling variants.
    func resolve(_ input: String) async throws -> String {
        let infos = try await concurrentMap(GenreNames.variants(for: input), limit: 3) { variant in
            try? await lastFM.tagInfo(variant)
        }
        guard let best = infos.compactMap({ $0 }).max(by: { $0.reach < $1.reach }), best.reach > 0 else {
            throw GenreResolverError.unknownGenre(input)
        }
        return best.name
    }
}

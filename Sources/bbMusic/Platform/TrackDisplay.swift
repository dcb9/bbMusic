import Foundation

/// Derives display metadata that is friendlier to classical music than the raw fields are.
///
/// QQ Music has no structured classical fields. What it does give is a free-text title (which for
/// classical recordings usually carries the work and its catalogue number) and a singer field that
/// lists every credited performer. Classical listeners care about the opposite grouping from pop:
/// the composer and the work come first, the performers are secondary, and an "artist" is rarely a
/// single name.
///
/// This is a **derivation, not data**: it never invents a composer that the title does not state,
/// and everything it cannot parse is left as it was. `isClassical` only changes how a row is
/// presented, never what is played or scrobbled.
enum TrackDisplay {
    /// Catalogue-number patterns that practically only appear on classical works.
    /// `Op.`, `BWV`, `KV`/`K.`, `Hob.`, `D.`, `RV`, `WoO`, `S.`
    private static let cataloguePattern = try? NSRegularExpression(
        // The trailing group keeps sub-designations such as "No. 2" or "K. 331" attached to the
        // number, so a title reads "Op. 9 No. 2" rather than a misleading "Op. 9".
        pattern: #"\b(Op\.?\s?\d+(?:\s?No\.?\s?\d+)?|BWV\.?\s?\d+|KV\.?\s?\d+|K\.\s?\d+|Hob\.?\s?[IVX]+a?:\d+|D\.\s?\d+|RV\.?\s?\d+|WoO\.?\s?\d+|S\.\s?\d+)"#,
        options: [.caseInsensitive]
    )

    /// Words that mark a classical work rather than a pop song.
    private static let classicalMarkers = [
        "symphony", "sonata", "concerto", "quartet", "quintet", "trio", "prelude", "fugue",
        "nocturne", "etude", "étude", "waltz", "mazurka", "ballade", "rhapsody", "suite",
        "requiem", "mass", "cantata", "oratorio", "overture", "aria", "lied", "variations",
        "symphonie", "konzert", "klaviersonate", "streichquartett",
        "交响", "奏鸣曲", "协奏曲", "四重奏", "前奏曲", "赋格", "夜曲", "练习曲", "圆舞曲",
        "组曲", "安魂曲", "弥撒", "序曲", "咏叹调", "变奏曲", "小夜曲", "叙事曲",
    ]

    struct Info {
        /// The work as stated, catalogue number included.
        var work: String
        /// Catalogue number on its own (`Op. 27 No. 2`), when one was found.
        var catalogue: String?
        /// Performers split out of the combined singer field.
        var performers: [String]
        var isClassical: Bool
    }

    static func info(for track: Track) -> Info {
        let work = track.title.trimmingCharacters(in: .whitespaces)
        let catalogue = catalogueNumber(in: work)
        let performers = performers(from: track.artist)
        let isClassical = isClassical(
            title: work,
            artist: track.artist,
            album: track.album,
            catalogue: catalogue,
            performerCount: performers.count
        )
        return Info(work: work, catalogue: catalogue, performers: performers, isClassical: isClassical)
    }

    /// The catalogue number (`Op. 27 No. 2`, `BWV 846`, `KV 331`) if the title carries one.
    static func catalogueNumber(in title: String) -> String? {
        guard let regex = cataloguePattern else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, options: [], range: range),
              let matchRange = Range(match.range, in: title)
        else { return nil }
        return String(title[matchRange])
    }

    /// Splits a combined credit list into individual performers.
    ///
    /// QQ Music joins credits with `/`, `、`, `;`, or `&`. A single name is returned untouched — an
    /// artist with "&" in their actual name is rare enough to accept the risk, and the result only
    /// affects presentation.
    static func performers(from artist: String) -> [String] {
        let separators = CharacterSet(charactersIn: "/、;；&")
        let parts = artist
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [artist] : parts
    }

    /// Whether to present this as a classical recording.
    ///
    /// Deliberately conservative: a catalogue number or a work-type word, or several credited
    /// performers together with a non-pop-looking credit. A wrong "classical" label only reorders a
    /// row, so a borderline case is acceptable; a false negative just leaves the pop layout.
    static func isClassical(
        title: String,
        artist: String,
        album: String,
        catalogue: String?,
        performerCount: Int
    ) -> Bool {
        if catalogue != nil { return true }
        let haystack = (title + " " + album).lowercased()
        if classicalMarkers.contains(where: { haystack.contains($0.lowercased()) }) { return true }
        // Several performers AND a long free-text title reads like a classical credit block.
        if performerCount >= 2 && title.count > 24 { return true }
        return false
    }

    /// The secondary line under a title: performers first for classical, album otherwise.
    static func secondaryLine(for track: Track) -> String {
        let info = info(for: track)
        if info.isClassical {
            if !info.performers.isEmpty, info.performers != [track.artist] {
                return info.performers.joined(separator: " · ")
            }
            return track.artist
        }
        return track.album.isEmpty ? track.artist : track.album
    }
}

import Foundation

/// Parses LRC lyric text into timed lines.
///
/// QQ Music's legacy lyric endpoint returns one LRC body for the song and an optional second body
/// carrying translations, keyed by the same timestamps. Translation lines are merged onto the
/// lyric line they share a timestamp with; unmatched ones are dropped rather than invented into the
/// wrong place.
enum LRCParser {
    static func parse(lyric: String, translation: String = "") -> Lyrics {
        let main = parseBody(lyric)
        guard !main.isEmpty else { return .empty }

        var translations: [Int: String] = [:]
        for line in parseBody(translation) {
            translations[millisecondKey(line.time)] = line.text
        }

        let merged = main.map { line -> Lyrics.Line in
            var copy = line
            if let text = translations[millisecondKey(line.time)] {
                copy.translation = text
            }
            return copy
        }
        return Lyrics(lines: merged)
    }

    /// One LRC body: `[mm:ss.xx]text`, possibly several timestamps on one line, plus `[ti:]`-style
    /// metadata tags which are skipped.
    private static func parseBody(_ body: String) -> [Lyrics.Line] {
        var lines: [Lyrics.Line] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            var times: [TimeInterval] = []
            var cursor = line.startIndex
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break }
                let inner = String(line[line.index(after: cursor)..<close])
                if let time = parseTimestamp(inner) {
                    times.append(time)
                }
                cursor = line.index(after: close)
            }
            guard !times.isEmpty else { continue }

            let text = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for time in times {
                lines.append(Lyrics.Line(time: time, text: text, translation: nil))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// `mm:ss.xx`, `mm:ss.xxx`, or `mm:ss`. Metadata tags like `ti:晴天` return nil.
    private static func parseTimestamp(_ inner: String) -> TimeInterval? {
        let parts = inner.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1])
        else { return nil }
        return minutes * 60 + seconds
    }

    /// Timestamps are compared at millisecond precision; float equality across two parses of the
    /// same string is safe, but keying by integer avoids depending on it.
    private static func millisecondKey(_ time: TimeInterval) -> Int {
        Int((time * 1000).rounded())
    }
}

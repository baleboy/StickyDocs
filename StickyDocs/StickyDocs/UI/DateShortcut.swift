import Foundation

// `@today`, `@tomorrow`, `@yesterday` and `@week`, typed in a sticky and
// followed by a space, Tab or Return, are replaced with plain text: the date
// in the system's medium style, or the ISO 8601 week number ("W42").
enum DateShortcut {
    nonisolated static let keywords: Set<String> = ["today", "tomorrow", "yesterday", "week"]

    // The text a keyword (without its "@", any case) expands to, or nil if
    // it isn't one.
    nonisolated static func expansion(for keyword: String, now: Date = Date(),
                                      calendar: Calendar = .autoupdatingCurrent,
                                      locale: Locale = .autoupdatingCurrent) -> String? {
        let dayOffset: Int
        switch keyword.lowercased() {
        case "today": dayOffset = 0
        case "tomorrow": dayOffset = 1
        case "yesterday": dayOffset = -1
        case "week":
            // ISO whatever the locale: weeks start Monday, W1 holds the first Thursday.
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            return "W\(iso.component(.weekOfYear, from: now))"
        default: return nil
        }
        guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // The range of an "@keyword" token ending right at `end` in `text`, if
    // there is one. The "@" must start the text or a line, or follow
    // whitespace or an opening bracket or quote, so "bob@today" (email-like)
    // never matches; the keyword must be the whole token, so "@todays" and
    // "@today.com" don't either.
    nonisolated static func token(endingAt end: Int, in text: NSString) -> (range: NSRange, keyword: String)? {
        guard end > 0, end <= text.length else { return nil }
        var start = end
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
              CharacterSet.letters.contains(scalar) {
            start -= 1
        }
        guard start < end, start > 0, text.character(at: start - 1) == UInt16(UInt8(ascii: "@")) else { return nil }
        let at = start - 1
        if at > 0 {
            guard let before = Unicode.Scalar(text.character(at: at - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(before) || openers.contains(before)
            else { return nil }
        }
        let keyword = text.substring(with: NSRange(location: start, length: end - start))
        guard keywords.contains(keyword.lowercased()) else { return nil }
        return (NSRange(location: at, length: end - at), keyword)
    }

    nonisolated private static let openers = CharacterSet(charactersIn: "([{\"'“‘«")
}

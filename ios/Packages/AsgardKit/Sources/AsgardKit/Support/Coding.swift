import Foundation

public enum Coding {
    /// Go emits RFC 3339 with optional fractional seconds.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        return e
    }()

    static func parseDate(_ s: String) -> Date? {
        // Trim nanoseconds to milliseconds; ISO8601FormatStyle handles 3 fractional digits.
        var str = s
        if let dot = str.firstIndex(of: "."), let end = str[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let frac = str[str.index(after: dot)..<end]
            str.replaceSubrange(str.index(after: dot)..<end, with: String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        if let d = try? Date(str, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return d }
        if let d = try? Date(str, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return d }
        if let d = try? Date(str, strategy: .iso8601) { return d }
        return nil
    }
}

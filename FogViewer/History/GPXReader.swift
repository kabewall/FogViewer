import Foundation

/// GPX から時刻つきの地点を読む。trkpt / wpt / rtept のうち、時刻があるものだけを返す。
final class GPXReader: NSObject, XMLParserDelegate {
    struct Point: Equatable {
        var lat: Double
        var lon: Double
        var time: Date
    }

    private var points: [Point] = []
    private var current: (lat: Double, lon: Double)?
    private var text = ""
    private var inTime = false
    private var time: Date?

    static func read(data: Data) -> [Point] {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.points
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "trkpt", "wpt", "rtept":
            if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                current = (lat, lon)
                time = nil
            }
        case "time" where current != nil:
            inTime = true
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTime { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "time" where inTime:
            inTime = false
            time = Self.parseTime(text)
        case "trkpt", "wpt", "rtept":
            if let c = current, let time { points.append(Point(lat: c.lat, lon: c.lon, time: time)) }
            current = nil
        default:
            break
        }
    }

    /// ISO 8601 の日時。小数秒・タイムゾーンは省略可。タイムゾーンがなければ UTC とみなす
    /// （Google タイムラインから変換した GPX は UTC でタイムゾーンを書かない）。
    static func parseTime(_ raw: String) -> Date? {
        let s = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= s.count else { return nil }
            var v = 0
            for c in s[from..<(from + len)] {
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2) else { return nil }
        var i = 19
        var fraction = 0.0
        if i < s.count, s[i] == UInt8(ascii: ".") {
            var scale = 0.1
            i += 1
            while i < s.count, s[i] >= 48 && s[i] <= 57 {
                fraction += Double(s[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < s.count {
            switch s[i] {
            case UInt8(ascii: "Z"): break
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                guard let oh = num(i + 1, 2) else { return nil }
                let om = num(i + 4, 2) ?? num(i + 3, 2) ?? 0
                offset = (oh * 3600 + om * 60) * (s[i] == UInt8(ascii: "+") ? 1 : -1)
            default: return nil
            }
        }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        guard let base = utcCalendar.date(from: comps) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

import Foundation

/// Google マップのタイムラインを書き出した JSON から、時刻つきの地点を読む。
///
/// 2 つの形式に対応する。
/// - iPhone から書き出した形式：最上位が配列。各要素に startTime / endTime と
///   timelinePath（point: "geo:緯度,経度", durationMinutesOffsetFromStartTime）・visit・activity のどれか
/// - Android から書き出した形式：最上位が辞書で semanticSegments の配列。
///   timelinePath（point: "35.6°, 139.7°", time）・visit・activity の位置は latLng
enum TimelineJSONReader {
    static func read(data: Data) -> [GPXReader.Point] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let segments: [[String: Any]]
        if let list = root as? [[String: Any]] {
            segments = list
        } else if let dict = root as? [String: Any], let list = dict["semanticSegments"] as? [[String: Any]] {
            segments = list
        } else {
            return []
        }

        var out: [GPXReader.Point] = []
        func add(_ location: Any?, _ time: Date?) {
            guard let time, let (lat, lon) = coordinate(location) else { return }
            out.append(.init(lat: lat, lon: lon, time: time))
        }
        for seg in segments {
            let start = (seg["startTime"] as? String).flatMap(GPXReader.parseTime)
            let end = (seg["endTime"] as? String).flatMap(GPXReader.parseTime)
            if let path = seg["timelinePath"] as? [[String: Any]] {
                for p in path {
                    if let t = (p["time"] as? String).flatMap(GPXReader.parseTime) {
                        add(p["point"], t)
                    } else if let offset = (p["durationMinutesOffsetFromStartTime"] as? String).flatMap(Double.init)
                                ?? (p["durationMinutesOffsetFromStartTime"] as? Double), let start {
                        add(p["point"], start.addingTimeInterval(offset * 60))
                    }
                }
            }
            if let visit = seg["visit"] as? [String: Any],
               let top = visit["topCandidate"] as? [String: Any] {
                add(top["placeLocation"], start)
            }
            if let activity = seg["activity"] as? [String: Any] {
                add(activity["start"], start)
                add(activity["end"], end)
            }
        }
        return out
    }

    /// "geo:35.1,139.2" / "35.1°, 139.2°" / {"latLng": "..."} のいずれかを緯度経度にする。
    static func coordinate(_ value: Any?) -> (Double, Double)? {
        if let dict = value as? [String: Any] { return coordinate(dict["latLng"]) }
        guard var s = value as? String else { return nil }
        if s.hasPrefix("geo:") { s.removeFirst(4) }
        let parts = s.replacingOccurrences(of: "°", with: "").split(separator: ",")
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (lat, lon)
    }
}

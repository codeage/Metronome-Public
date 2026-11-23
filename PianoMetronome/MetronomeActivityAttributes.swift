import ActivityKit

struct MetronomeActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        let bpm: Int
        let beats: Int
        let unit: Int
        let subdivision: Int
        let rhythmName: String?
        let accent: Bool

        var meter: String { "\(beats)/\(unit)" }
    }
}

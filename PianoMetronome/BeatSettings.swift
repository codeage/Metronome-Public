import Foundation

enum BeatAccent: Int, CaseIterable, Codable, Sendable {
    case strong, medium, weak, silent

    var title: String {
        switch self {
        case .strong: String(localized: "强音")
        case .medium: String(localized: "次强音")
        case .weak: String(localized: "弱音")
        case .silent: String(localized: "静音")
        }
    }

    var next: Self { Self.allCases[(rawValue + 1) % Self.allCases.count] }
}

enum BeatRhythm: Int, CaseIterable, Codable, Sendable, Identifiable {
    case quarter, eighth, triplet, sixteenth, dotted, syncopated, swing

    var id: Self { self }
    var title: String {
        switch self {
        case .quarter: String(localized: "四分音符")
        case .eighth: String(localized: "八分音符")
        case .triplet: String(localized: "三连音")
        case .sixteenth: String(localized: "十六分音符")
        case .dotted: String(localized: "附点")
        case .syncopated: String(localized: "切分")
        case .swing: String(localized: "Swing")
        }
    }
}

enum BeatSound: Int, CaseIterable, Codable, Sendable, Identifiable {
    // Persisted in settings and presets and passed to MetronomeRenderer.c.
    case mechanical = 0
    case electronic = 1
    case wood = 2
    case voice = 3
    case bell = 4
    case softTap = 5
    case shortDrum = 6

    var id: Self { self }
    var title: String {
        switch self {
        case .mechanical: String(localized: "机械")
        case .electronic: String(localized: "蜂鸣")
        case .wood: String(localized: "木鱼")
        case .voice: String(localized: "人声")
        case .bell: String(localized: "铃声")
        case .softTap: String(localized: "轻点声")
        case .shortDrum: String(localized: "短鼓声")
        }
    }
}

struct SpeedTrainer: Equatable, Codable, Sendable {
    var enabled = false
    var start = 80
    var target = 120
    var step = 5
    var bars = 4
}

struct SilentBars: Equatable, Codable, Sendable {
    var enabled = false
    var audible = 4
    var silent = 2
}

struct MetronomePreferences: Equatable, Codable, Sendable {
    var professionalTempo = false
    var extendedMeter = false
    var showTempoMark = false
    var keepAwake = true
    var mixWithOthers = true
    var flash = true
    var haptics = false
    var offsetMilliseconds = 0
    var volume = 1.0
    var balance = 0.0
    var trainer = SpeedTrainer()
    var ghost = SilentBars()

    var tempoRange: ClosedRange<Int> { professionalTempo ? 20...300 : 30...250 }
    var beatsRange: ClosedRange<Int> { 1...(extendedMeter ? 32 : 16) }
}

struct BeatSettings: Equatable, Codable, Sendable {
    var bpm: Int
    var beats: Int {
        didSet { accents = Self.resized(accents, to: beats) }
    }
    var unit: Int
    var rhythm: BeatRhythm
    var sound: BeatSound
    var accents: [BeatAccent]

    static let units = [2, 4, 8, 16, 32, 64]

    init(bpm: Int = 120, beats: Int = 4, unit: Int = 4, subdivision: Int = 1, accent: Bool = true) {
        self.bpm = bpm
        self.beats = beats
        self.unit = unit
        self.rhythm = (1...4).contains(subdivision) ? BeatRhythm(rawValue: subdivision - 1) ?? .quarter : .quarter
        self.sound = .mechanical
        self.accents = Self.resized([accent ? .strong : .weak], to: beats)
    }

    var subdivision: Int {
        get { rhythm.rawValue < 4 ? rhythm.rawValue + 1 : 1 }
        set { if (1...4).contains(newValue) { rhythm = BeatRhythm(rawValue: newValue - 1) ?? .quarter } }
    }

    var accent: Bool {
        get { accents.first.map { $0 == .strong || $0 == .medium } ?? false }
        set { if !accents.isEmpty { accents[0] = newValue ? .strong : .weak } }
    }

    var meter: String { "\(beats)/\(unit)" }

    var isValid: Bool {
        (20...300).contains(bpm) && (1...32).contains(beats)
            && Self.units.contains(unit) && accents.count == beats
    }

    var tempoMark: String {
        switch bpm {
        case ..<40: "Grave"
        case ..<60: "Largo"
        case ..<76: "Adagio"
        case ..<108: "Andante"
        case ..<120: "Moderato"
        case ..<156: "Allegro"
        case ..<176: "Vivace"
        default: "Presto"
        }
    }

    private static func resized(_ accents: [BeatAccent], to beats: Int) -> [BeatAccent] {
        let count = min(32, max(0, beats))
        return (0..<count).map { $0 < accents.count ? accents[$0] : ($0 == 0 ? .strong : .weak) }
    }

    enum CodingKeys: String, CodingKey { case bpm, beats, unit, rhythm, sound, accents, subdivision, accent }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bpm: try fields.decode(Int.self, forKey: .bpm),
                  beats: try fields.decode(Int.self, forKey: .beats),
                  unit: try fields.decode(Int.self, forKey: .unit),
                  subdivision: try fields.decodeIfPresent(Int.self, forKey: .subdivision) ?? 1,
                  accent: try fields.decodeIfPresent(Bool.self, forKey: .accent) ?? true)
        rhythm = try fields.decodeIfPresent(BeatRhythm.self, forKey: .rhythm) ?? rhythm
        sound = try fields.decodeIfPresent(BeatSound.self, forKey: .sound) ?? sound
        if let existing = try fields.decodeIfPresent([BeatAccent].self, forKey: .accents) {
            accents = Self.resized(existing, to: beats)
        }
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(bpm, forKey: .bpm)
        try fields.encode(beats, forKey: .beats)
        try fields.encode(unit, forKey: .unit)
        try fields.encode(rhythm, forKey: .rhythm)
        try fields.encode(sound, forKey: .sound)
        try fields.encode(accents, forKey: .accents)
        try fields.encode(subdivision, forKey: .subdivision)
        try fields.encode(accent, forKey: .accent)
    }
}

struct MetronomePreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var settings: BeatSettings
}

struct TapTempo {
    private var times: [TimeInterval] = []

    mutating func tap(at time: TimeInterval, within range: ClosedRange<Int>) -> Int? {
        if let last = times.last, time - last > 60 / Double(range.lowerBound) * 1.25 || time <= last {
            times.removeAll(keepingCapacity: true)
        }
        times.append(time)
        if times.count > 4 { times.removeFirst() }
        guard times.count >= 3, let first = times.first else { return nil }
        let average = (time - first) / Double(times.count - 1)
        let tempo = (60 / average).rounded()
        guard tempo.isFinite else { return nil }
        return Int(min(Double(range.upperBound), max(Double(range.lowerBound), tempo)))
    }
}

/// Translates angular travel into tempo while keeping the starting value under the user's finger.
struct TempoDialDrag {
    static let zeroAngle = 90.0
    static let sweep = 360.0

    private let range: ClosedRange<Int>
    private let referenceRadius: Double
    private var angle: Double?
    private var offset: Double
    private var hasTurned = false

    init(tempo: Int, range: ClosedRange<Int>, start: CGPoint) {
        self.range = range
        referenceRadius = hypot(Double(start.x), Double(start.y))
        angle = Self.angle(at: start)
        offset = Self.progress(for: tempo, in: range) * Self.sweep
    }

    var tempo: Int {
        Int((offset / Self.sweep * Double(range.upperBound)).rounded())
    }

    static func progress(for tempo: Int, in range: ClosedRange<Int>) -> Double {
        Double(min(max(tempo, 0), range.upperBound)) / Double(range.upperBound)
    }

    mutating func update(to point: CGPoint) {
        let radius = hypot(Double(point.x), Double(point.y))
        guard radius >= referenceRadius * 0.55 else {
            angle = nil
            return
        }

        let previousAngle = angle
        let nextAngle = Self.angle(at: point)
        angle = nextAngle
        guard let previousAngle else { return }

        let delta = (nextAngle - previousAngle + 540).truncatingRemainder(dividingBy: 360) - 180
        // Discard discontinuities if a finger crosses the center between samples.
        guard abs(delta) <= 90 else { return }
        if !hasTurned {
            let tangentialTravel = abs(delta) * .pi / 180 * referenceRadius
            guard tangentialTravel > abs(radius - referenceRadius) else { return }
            hasTurned = true
        }
        let minimumOffset = Self.progress(for: range.lowerBound, in: range) * Self.sweep
        offset = min(max(offset + delta, minimumOffset), Self.sweep)
    }

    private static func angle(at point: CGPoint) -> Double {
        atan2(Double(point.y), Double(point.x)) * 180 / .pi
    }
}

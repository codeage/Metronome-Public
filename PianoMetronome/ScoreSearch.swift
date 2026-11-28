import CryptoKit
import PDFKit
import UIKit
import SQLite3
import SwiftUI

struct ScoreWork: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let composer: String
    let instruments: String
    let meter: String
    let supportsFollowing: Bool

    var openingMeter: (beats: Int, unit: Int)? {
        let parts = meter.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let beats = Int(parts[0]), let unit = Int(parts[1]),
              beats > 0, unit > 0 else { return nil }
        return (beats, unit)
    }
}

private actor ScoreCatalog {
    static let shared = ScoreCatalog()

    private enum CatalogError: Error {
        case unavailable
        case queryFailed(Int32)
    }

    func search(_ query: String, publishedOnly: Bool = false) throws -> [ScoreWork] {
        let terms = String(query.prefix(100))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(8)
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        let phrase = terms.joined(separator: " ")
        let filter = Array(repeating: "search_text LIKE ?", count: terms.count).joined(separator: " AND ")
        let availability = publishedOnly ? " AND published.score_id IS NOT NULL" : ""
        let matches = terms.map { term in
            if term.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil {
                return "%\(term)%"
            }
            return "% \(term)%"
        }
        return try withStatement("""
            SELECT score_id, title, subtitle, composer, instruments, meter,
                   COALESCE(published.has_timing, 0)
            FROM scores LEFT JOIN published_scores AS published USING (score_id)
            WHERE \(filter)\(availability)
            ORDER BY (search_title = ?) DESC, (search_title LIKE ?) DESC, title COLLATE NOCASE, score_id
            LIMIT 20
            """, bindings: matches + [phrase, phrase + "%"]) { statement in
            var works: [ScoreWork] = []
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return works }
                guard result == SQLITE_ROW else { throw CatalogError.queryFailed(result) }
                works.append(ScoreWork(id: text(0, in: statement), title: text(1, in: statement),
                                       subtitle: text(2, in: statement), composer: text(3, in: statement),
                                       instruments: text(4, in: statement), meter: text(5, in: statement),
                                       supportsFollowing: sqlite3_column_int(statement, 6) != 0))
            }
        }
    }

    private func withStatement<Result>(_ sql: String, bindings: [String],
                                       read: (OpaquePointer) throws -> Result) throws -> Result {
        try Task.checkCancellation()
        guard let url = Bundle.main.url(forResource: "PDMXScoreIndex", withExtension: "sqlite") else {
            throw CatalogError.unavailable
        }
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK, let database else { throw CatalogError.unavailable }

        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
        defer { sqlite3_finalize(prepared) }
        guard status == SQLITE_OK, let prepared else { throw CatalogError.queryFailed(status) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let bound = sqlite3_bind_text(prepared, Int32(index + 1), value, -1, transient)
            guard bound == SQLITE_OK else { throw CatalogError.queryFailed(bound) }
        }
        return try read(prepared)
    }

    private func text(_ index: Int32, in statement: OpaquePointer) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}

struct ScoreEndpoint: Sendable {
    static let production = ScoreEndpoint(address: "https://bytereset.com/metronome/scores/v1/")!
    let baseURL: URL
    var isProduction: Bool { baseURL.scheme == "https" }

    init?(address: String) {
        guard let parts = URLComponents(string: address),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host, let url = parts.url else { return nil }
        if parts.scheme == "https", host == "bytereset.com", parts.port == nil,
           parts.percentEncodedPath == "/metronome/scores/v1/" {
            baseURL = url
            return
        }
        guard parts.scheme == "http", let port = parts.port, (1...65_535).contains(port),
              parts.percentEncodedPath.range(of: #"^/s/[A-Za-z0-9_-]{24}/$"#, options: .regularExpression) != nil
        else { return nil }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { UInt8($0) }
        guard components.count == 4, octets.count == 4,
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) else { return nil }
        baseURL = url
    }

    init?(connectionURL: URL) {
        guard let parts = URLComponents(url: connectionURL, resolvingAgainstBaseURL: false),
              parts.scheme == "bytereset-metronome", parts.host == "catalog",
              let address = parts.queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        self.init(address: address)
    }

    func timingURL(for id: String) -> URL? {
        resource("timing", id: id, extension: "json")
    }

    func pdfURL(for id: String) -> URL? {
        resource("pdf", id: id, extension: "pdf")
    }

    private func resource(_ folder: String, id: String, extension ext: String) -> URL? {
        guard id.range(of: #"^[0-9]{1,16}$"#, options: .regularExpression) != nil else { return nil }
        return baseURL.appending(path: folder, directoryHint: .isDirectory)
            .appending(path: id + "." + ext, directoryHint: .notDirectory)
    }
}

struct ScoreSearchResults: View {
    let query: String
    let endpoint: ScoreEndpoint?
    let onOpen: (ScoreWork, ScoreEndpoint) -> Void

    @State private var needsConnection = false

    @State private var works: [ScoreWork] = []
    @State private var completedQuery: String?
    @State private var failed = false

    var body: some View {
        Group {
            if completedQuery != query {
                ProgressView().accessibilityLabel("搜索曲谱")
            } else if works.isEmpty {
                Text(failed ? LocalizedStringKey("无法读取曲库") : LocalizedStringKey("未找到曲谱"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(works) { work in
                            if work.id != works.first?.id { Divider().padding(.horizontal, 14) }
                            Button {
                                guard let endpoint else {
                                    needsConnection = true
                                    return
                                }
                                onOpen(work, endpoint)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(work.title).font(.subheadline.weight(.semibold))
                                        if !work.subtitle.isEmpty {
                                            Text(verbatim: work.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        if !work.composer.isEmpty {
                                            Text(work.composer)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Group {
                                            if work.instruments.isEmpty {
                                                Text("乐器未注明")
                                            } else {
                                                Text(verbatim: work.instruments)
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(MetronomePalette.cyan)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        if let meter = work.openingMeter {
                                            Text("\(meter.beats)/\(meter.unit)")
                                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                        }
                                        if work.supportsFollowing {
                                            Text("支持跟谱")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(MetronomePalette.cyan.opacity(0.13), in: Capsule())
                                        }
                                        Label("PDF", systemImage: "doc.text")
                                            .font(.caption2)
                                            .accessibilityHidden(true)
                                    }
                                    .foregroundStyle(MetronomePalette.cyan)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("打开曲谱 PDF")
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(works.count) * 83, 288))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        .alert("连接 Windows 曲库", isPresented: $needsConnection) {
            Button("好", role: .cancel) {}
        } message: {
            Text("在 Safari 打开 Windows 曲库链接，然后点「在 Metronome 中连接这个曲库」。")
        }
        .task(id: [query, endpoint?.baseURL.absoluteString ?? ""]) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let found = try await ScoreCatalog.shared.search(
                    query.trimmingCharacters(in: .whitespacesAndNewlines), publishedOnly: endpoint?.isProduction == true
                )
                try Task.checkCancellation()
                works = found
                failed = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                works = []
                failed = true
            }
            completedQuery = query
        }
    }
}
struct ScoreTiming: Decodable, Sendable {
    struct Event: Decodable, Sendable {
        let beat: Double
        let notes: [Note]
    }

    struct Note: Decodable, Sendable {
        let page: Int
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        func bounds(on page: PDFPage) -> CGRect {
            let visible = page.bounds(for: .cropBox)
            return CGRect(x: visible.minX + x * visible.width,
                          y: visible.maxY - (y + h) * visible.height,
                          width: w * visible.width, height: h * visible.height)
        }
    }

    let version: Int
    let sha256: String
    let pages: Int
    let endBeat: Double
    let events: [Event]

    func event(at beat: Double) -> Int? {
        var lower = 0
        var upper = events.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if events[middle].beat <= beat { lower = middle + 1 }
            else { upper = middle }
        }
        return lower == 0 ? nil : lower - 1
    }
}

struct ScorePDFSheet: View {
    let work: ScoreWork
    let endpoint: ScoreEndpoint
    @ObservedObject var metronome: Metronome
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var timing: ScoreTiming?
    @State private var failed = false
    @State private var preparingTiming = true
    @State private var meterError: String?
    @State private var active: Int?
    @State private var origin = 0.0
    @State private var position = 0.0
    @State private var firstSerial: UInt64?

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    ScorePDFView(document: document, timing: timing, active: active,
                                 allowSeek: metronome.playing, seek: seek)
                } else if failed {
                    ContentUnavailableView("无法打开曲谱", systemImage: "doc.badge.exclamationmark")
                } else {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if document != nil {
                    HStack {
                        Text(verbatim: metronome.settings.meter)
                            .monospacedDigit()
                        if let timing, !timing.events.isEmpty {
                            Text("\(metronome.effectiveTempo ?? metronome.settings.bpm) BPM")
                                .monospacedDigit()
                        } else if preparingTiming {
                            ProgressView().padding(.trailing, 2)
                            Text("正在核对音符位置")
                        } else {
                            Text("此谱暂无跟谱数据")
                        }
                        Spacer()
                        Button {
                            toggle()
                        } label: {
                            Label(metronome.playing ? "停止" : "开始", systemImage: metronome.playing ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let meterError {
                    Text(meterError)
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(.regularMaterial)
                }
            }
            .navigationTitle(work.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .task(id: work.id) { await load() }
        .task(id: work.id) { await applyOpeningMeter() }
        .task(id: metronome.playing) {
            guard metronome.playing else {
                origin = position
                firstSerial = nil
                return
            }
            while !Task.isCancelled {
                advance()
                do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
            }
        }
    }

    private func applyOpeningMeter() async {
        guard let meter = work.openingMeter, work.meter != metronome.settings.meter else { return }
        var settings = metronome.settings
        settings.beats = meter.beats
        settings.unit = meter.unit
        await metronome.refreshAccessIfNeeded(for: settings)
        guard !Task.isCancelled else { return }
        settings = metronome.settings
        settings.beats = meter.beats
        settings.unit = meter.unit
        do {
            try metronome.update(settings)
        } catch {
            meterError = String(localized: "无法应用曲谱拍号 \(work.meter)。\(error.localizedDescription)")
        }
    }

    private func load() async {
        defer { preparingTiming = false }
        guard let pdfURL = endpoint.pdfURL(for: work.id),
              let timingURL = endpoint.timingURL(for: work.id) else { failed = true; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: pdfURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let loaded = PDFDocument(data: data), loaded.pageCount > 0 else { failed = true; return }
            try Task.checkCancellation()
            document = loaded
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            for attempt in 0..<14 {
                let (json, result) = try await session.data(from: timingURL)
                switch (result as? HTTPURLResponse)?.statusCode {
                case 200:
                    let map = try JSONDecoder().decode(ScoreTiming.self, from: json)
                    guard map.version == 1, map.sha256 == fingerprint,
                          map.pages == loaded.pageCount, !map.events.isEmpty else { return }
                    timing = map
                    return
                case 202, 503:
                    if attempt < 13 { try await Task.sleep(for: .seconds(4)) }
                default:
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            failed = document == nil
        }
    }

    private func toggle() {
        if metronome.playing {
            metronome.stop()
        } else {
            do {
                try metronome.start()
            } catch {
                metronome.error = error.localizedDescription
            }
        }
    }

    private func advance() {
        guard let timing, let clock = metronome.scoreBeatClock() else { return }
        if firstSerial == nil { firstSerial = clock.serial }
        guard let firstSerial, clock.serial >= firstSerial else { return }
        let quartersPerClick = 4.0 / Double(metronome.settings.unit)
        position = origin + (Double(clock.serial - firstSerial) + clock.fraction) * quartersPerClick
        if position >= timing.endBeat {
            position = 0
            origin = 0
            active = nil
            metronome.stop()
            return
        }
        let index = timing.event(at: position)
        if active != index { active = index }
    }

    private func seek(_ index: Int) {
        guard metronome.playing, let timing, timing.events.indices.contains(index) else { return }
        origin = timing.events[index].beat
        position = origin
        active = index
        firstSerial = nil
        metronome.stop()
        do {
            try metronome.start()
        } catch {
            metronome.error = error.localizedDescription
        }
    }
}

private struct ScorePDFView: UIViewRepresentable {
    let document: PDFDocument
    let timing: ScoreTiming?
    let active: Int?
    let allowSeek: Bool
    let seek: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayBox = .cropBox
        view.autoScales = true
        view.document = document
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let handler = context.coordinator
        handler.timing = timing
        handler.allowSeek = allowSeek
        handler.seek = seek
        if view.document !== document { view.document = document }
        handler.show(active, on: view)
    }

    @MainActor
    final class Coordinator: NSObject {
        var timing: ScoreTiming?
        var allowSeek = false
        var seek: ((Int) -> Void)?
        private var previous: Int?
        private var marks: [(PDFPage, PDFAnnotation)] = []

        func show(_ index: Int?, on view: PDFView) {
            guard previous != index else { return }
            previous = index
            for (page, annotation) in marks { page.removeAnnotation(annotation) }
            marks.removeAll()
            guard let index, let timing, let document = view.document else { return }
            for note in timing.events[index].notes {
                guard let page = document.page(at: note.page) else { continue }
                let annotation = PDFAnnotation(bounds: note.bounds(on: page), forType: .square, withProperties: nil)
                annotation.color = .clear
                annotation.interiorColor = UIColor.systemTeal.withAlphaComponent(0.55)
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                page.addAnnotation(annotation)
                marks.append((page, annotation))
            }
            if let (page, note) = marks.first {
                let around = note.bounds.insetBy(dx: -18, dy: -28)
                if !view.bounds.insetBy(dx: 6, dy: 28).intersects(view.convert(around, from: page)) {
                    view.go(to: around, on: page)
                }
            }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard allowSeek, let timing, let view = recognizer.view as? PDFView,
                  let document = view.document else { return }
            let touch = recognizer.location(in: view)
            guard let page = view.page(for: touch, nearest: false) else { return }
            let pageIndex = document.index(for: page)
            let point = view.convert(touch, to: page)
            var closest: (index: Int, distance: CGFloat)?
            for (index, event) in timing.events.enumerated() {
                for note in event.notes where note.page == pageIndex {
                    let rectangle = note.bounds(on: page)
                    let margin = 8 / max(view.scaleFactor, 0.1)
                    guard rectangle.insetBy(dx: -margin, dy: -margin).contains(point) else { continue }
                    let distance = hypot(point.x - rectangle.midX, point.y - rectangle.midY)
                    if let selected = closest {
                        if distance > selected.distance + 0.01 { continue }
                        let active = previous ?? 0
                        if abs(distance - selected.distance) <= 0.01 &&
                            abs(index - active) >= abs(selected.index - active) { continue }
                    }
                    closest = (index, distance)
                }
            }
            if let closest { seek?(closest.index) }
        }
    }
}
import SQLite3
import SwiftUI

private struct ScoreWork: Identifiable, Sendable {
    let id: Int64
    let title: String
    let composer: String
    let catalog: String
    let url: URL
}

private actor ScoreCatalog {
    static let shared = ScoreCatalog()

    private enum CatalogError: Error {
        case unavailable
        case queryFailed(Int32)
    }

    func search(_ query: String) throws -> [ScoreWork] {
        let terms = String(query.prefix(100))
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(8)
            .map(String.init)
        guard !terms.isEmpty else { return [] }
        try Task.checkCancellation()
        guard let path = Bundle.main.path(forResource: "ScoreCatalog", ofType: "sqlite") else {
            throw CatalogError.unavailable
        }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(handle) }
        guard opened == SQLITE_OK, let handle else { throw CatalogError.unavailable }

        let match = terms.map { "\"" + $0 + "\"*" }.joined(separator: " AND ")
        let indexed = try? select("""
            SELECT w.work_id, w.title, w.composer, w.catalog_number, w.url
            FROM work_search JOIN works w ON w.work_id = work_search.rowid
            WHERE work_search MATCH ?
            ORDER BY CASE WHEN w.title = ? COLLATE NOCASE THEN 0 ELSE 1 END,
                bm25(work_search, 8, 3, 2, 4), w.work_id
            LIMIT 20
            """, binding: [match, query], in: handle)
        if let indexed, !indexed.isEmpty { return indexed }

        // The fallback matches fragments within Chinese aliases and supports system SQLite without FTS5.
        let searchable = "(title || ' ' || composer || ' ' || coalesce(catalog_number, '') || ' ' || coalesce(aliases, ''))"
        let filter = Array(repeating: "\(searchable) LIKE ?", count: terms.count).joined(separator: " AND ")
        return try select("""
            SELECT work_id, title, composer, catalog_number, url
            FROM works WHERE \(filter) LIMIT 20
            """, binding: terms.map { "%\($0)%" }, in: handle)
    }

    private func select(_ sql: String, binding values: [String], in database: OpaquePointer) throws -> [ScoreWork] {
        try Task.checkCancellation()
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
        defer { sqlite3_finalize(prepared) }
        guard status == SQLITE_OK, let statement = prepared else { throw CatalogError.queryFailed(status) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let bound = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            guard bound == SQLITE_OK else { throw CatalogError.queryFailed(bound) }
        }
        func column(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
        var works: [ScoreWork] = []
        while true {
            try Task.checkCancellation()
            let next = sqlite3_step(statement)
            if next == SQLITE_DONE { return works }
            guard next == SQLITE_ROW else { throw CatalogError.queryFailed(next) }
            guard let url = URL(string: column(4)), url.scheme == "https", url.host == "imslp.org" else {
                continue
            }
            works.append(ScoreWork(id: sqlite3_column_int64(statement, 0), title: column(1),
                                   composer: column(2), catalog: column(3), url: url))
        }
    }
}

private actor ScorePDFResolver {
    static let shared = ScorePDFResolver()

    private struct WikiResponse: Decodable {
        let query: Query
        struct Query: Decodable { let pages: [String: Page] }
        struct Page: Decodable {
            let revisions: [Revision]?
            let imageinfo: [ImageInfo]?
        }
        struct Revision: Decodable {
            let content: String
            enum CodingKeys: String, CodingKey { case content = "*" }
        }
        struct ImageInfo: Decodable {
            let url: String
            let mime: String?
        }
    }

    // The source servers return the PDF itself for these specific piano editions.
    private let verifiedEditions: [Int64: String] = [
        71_969: "https://www.bruzanemediabase.com/sites/default/files/2024-09/mbonis_desdemona_ed.pdf",
        98_025: "https://www.mutopiaproject.org/ftp/BeethovenLv/WoO59/fur_Elise_WoO59/fur_Elise_WoO59-a4.pdf",
        180_282: "https://www.mutopiaproject.org/ftp/BeethovenLv/O27/moonlight/moonlight-a4.pdf"
    ]
    private var resolved: [Int64: URL] = [:]

    func resolve(_ work: ScoreWork) async throws -> URL? {
        if let known = verifiedEditions[work.id], let url = URL(string: known) { return url }
        if let cached = resolved[work.id] { return cached }
        guard work.url.path.hasPrefix("/wiki/") else { return nil }
        let title = String(work.url.path.dropFirst("/wiki/".count))
        let pages = try await request(["prop": "revisions", "rvprop": "content", "redirects": "1", "titles": title])
        guard let source = pages.values.first?.revisions?.first?.content else { return nil }
        let names = pianoPDFNames(in: source)
        guard !names.isEmpty else { return nil }
        let files = try await request(["prop": "imageinfo", "iiprop": "url|mime",
                                       "titles": names.map { "File:" + $0 }.joined(separator: "|")])
        let candidates = files.values.compactMap { page -> URL? in
            guard let info = page.imageinfo?.first, info.mime == "application/pdf" else { return nil }
            let value = info.url.hasPrefix("//") ? "https:" + info.url : info.url
            guard let url = URL(string: value), isIMSLP(url) else { return nil }
            return url
        }
        for name in names {
            try Task.checkCancellation()
            let filename = name.replacingOccurrences(of: "_", with: " ")
            guard let url = candidates.first(where: { $0.lastPathComponent.replacingOccurrences(of: "_", with: " ") == filename }) else { continue }
            if let pdf = try? await confirmedPDF(url) {
                resolved[work.id] = pdf
                return pdf
            }
        }
        try Task.checkCancellation()
        return nil
    }

    private func request(_ parameters: [String: String]) async throws -> [String: WikiResponse.Page] {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "imslp.org"
        endpoint.path = "/api.php"
        let arguments = parameters.merging(["action": "query", "format": "json"]) { existing, _ in existing }
        endpoint.queryItems = arguments.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = endpoint.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Metronome/1.1 (score link lookup)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let result = response as? HTTPURLResponse, 200..<300 ~= result.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(WikiResponse.self, from: data).query.pages
    }

    private func confirmedPDF(_ url: URL) async throws -> URL? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("bytes=0-4", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode,
              let finalURL = response.url, isIMSLP(finalURL) else { return nil }
        var iterator = bytes.makeAsyncIterator()
        for byte in "%PDF-".utf8 {
            guard try await iterator.next() == byte else { return nil }
        }
        return finalURL
    }

    private func isIMSLP(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return host == "imslp.org" || host.hasSuffix(".imslp.org")
    }

    private func pianoPDFNames(in wikitext: String) -> [String] {
        let sections = wikitext.components(separatedBy: "*****FILES*****")
        guard sections.count > 1,
              let files = sections[1].components(separatedBy: "*****WORK INFO*****").first else { return [] }
        let instrument = captures(#"(?mi)^[ \t]*\|[ \t]*Instrumentation[ \t]*=[ \t]*([^\r\n]*)"#, in: wikitext).first?[1] ?? ""
        let soloPiano = !captures(#"(?i)^(?:solo\s+)?piano(?:\s*\(solo\))?$"#, in: instrument).isEmpty
        let blocks = captures(#"(?ms)^(?:(={3,5})([^=\r\n]+)\1[ \t]*$|\{\{#fte:imslpfile\b(.*?)^\}\})"#, in: files)
        var section = "Scores"
        var pianoArrangement = false
        var complete: [String] = []
        var other: [String] = []
        for block in blocks {
            if let level = block[1], let heading = block[2] {
                if level.count == 3 {
                    section = heading
                    pianoArrangement = false
                } else if section == "Arrangements and Transcriptions" {
                    pianoArrangement = !captures(#"(?i)^\*?\s*for piano(?:\s*\([^)]*\))?$"#, in: heading).isEmpty
                }
                continue
            }
            guard (section == "Scores" && soloPiano) || pianoArrangement, let source = block[3] else { continue }
            let rows = captures(#"(?m)^[ \t]*\|[ \t]*File (Name|Description) (\d+)[ \t]*=([^\r\n]*)"#, in: source)
            var descriptions: [String: String] = [:]
            for row in rows where row[1] == "Description" {
                if let number = row[2], let text = row[3] { descriptions[number] = text.lowercased() }
            }
            for row in rows where row[1] == "Name" {
                guard let name = row[3], let number = row[2], name.lowercased().hasSuffix(".pdf") else { continue }
                let description = descriptions[number] ?? ""
                guard !description.contains("cover"), !description.contains("preview"), !description.contains("facsimile of title") else { continue }
                if description.contains("complete score") { complete.append(name) }
                else { other.append(name) }
            }
        }
        var seen = Set<String>()
        return Array((complete + other).filter { seen.insert($0).inserted }.prefix(3))
    }

    private func captures(_ pattern: String, in text: String) -> [[String?]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { group in
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

struct ScoreSearchResults: View {
    let query: String
    let onOpen: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var works: [ScoreWork] = []
    @State private var completedQuery: String?
    @State private var failed = false
    @State private var opening: ScoreWork?
    @State private var scoreUnavailable = false

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
                                scoreUnavailable = false
                                opening = work
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(work.title).font(.subheadline.weight(.semibold))
                                        Text([work.composer, work.catalog].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        if opening?.id == work.id {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.up.right")
                                            Text(verbatim: "PDF").font(.caption2)
                                        }
                                    }
                                    .foregroundStyle(MetronomePalette.cyan)
                                    .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(opening != nil)
                            .accessibilityHint("在浏览器中打开曲谱")
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(works.count) * 64, 272))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if scoreUnavailable {
                Text("没有找到可直接打开的钢琴谱 PDF。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        .onChange(of: query) { _, _ in
            opening = nil
            scoreUnavailable = false
        }
        .task(id: opening?.id) {
            guard let work = opening else { return }
            let pdf = try? await ScorePDFResolver.shared.resolve(work)
            guard !Task.isCancelled else { return }
            opening = nil
            if let pdf {
                onOpen()
                openURL(pdf)
            } else {
                scoreUnavailable = true
            }
        }
        .task(id: query) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let found = try await ScoreCatalog.shared.search(query.trimmingCharacters(in: .whitespacesAndNewlines))
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

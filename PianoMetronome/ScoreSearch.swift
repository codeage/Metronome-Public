import SQLite3
import SwiftUI

private struct ScoreWork: Identifiable, Sendable {
    let id: String
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
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
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

        let phrase = terms.joined(separator: " ")
        let filter = Array(repeating: "search_text LIKE ?", count: terms.count).joined(separator: " AND ")
        let matches = terms.map { term in
            if term.range(of: #"\p{Han}"#, options: .regularExpression) != nil { return "%\(term)%" }
            return "% \(term)%"
        }
        return try select("""
            SELECT score_id, title, composer, catalog_number, pdf_url
            FROM piano_scores WHERE \(filter)
            ORDER BY (search_title = ?) DESC, (search_title LIKE ?) DESC, title COLLATE NOCASE, score_id
            LIMIT 20
            """, binding: matches + [phrase, phrase + "%"], in: handle)
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
            guard let url = URL(string: column(4)), url.scheme == "https",
                  url.pathExtension.lowercased() == "pdf",
                  url.host == "www.mutopiaproject.org" || url.host == "www.bruzanemediabase.com" else {
                continue
            }
            works.append(ScoreWork(id: column(0), title: column(1),
                                   composer: column(2), catalog: column(3), url: url))
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

    var body: some View {
        Group {
            if completedQuery != query {
                ProgressView().accessibilityLabel("搜索曲谱")
            } else if works.isEmpty {
                Text(failed ? LocalizedStringKey("无法读取曲库") : LocalizedStringKey("未找到可直接打开的钢琴谱"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(works) { work in
                            if work.id != works.first?.id { Divider().padding(.horizontal, 14) }
                            Button {
                                onOpen()
                                openURL(work.url)
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
                                        Image(systemName: "arrow.up.right")
                                        Text(verbatim: "PDF").font(.caption2)
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
                            .accessibilityHint("在浏览器中打开曲谱")
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(works.count) * 64, 272))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
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

import PDFKit
import SQLite3
import SwiftUI

struct ScoreWork: Identifiable, Sendable {
    let id: String
    let title: String
    let composer: String
    let instruments: String
}

private actor ScoreCatalog {
    static let shared = ScoreCatalog()

    private enum CatalogError: Error {
        case unavailable
        case queryFailed(Int32)
        case missingPDF
    }

    func search(_ query: String) throws -> [ScoreWork] {
        let terms = String(query.prefix(100))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(8)
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        let phrase = terms.joined(separator: " ")
        let filter = Array(repeating: "search_text LIKE ?", count: terms.count).joined(separator: " AND ")
        let matches = terms.map { term in
            if term.range(of: #"\p{Han}"#, options: .regularExpression) != nil { return "%\(term)%" }
            return "% \(term)%"
        }
        return try withStatement("""
            SELECT score_id, title, composer, instruments
            FROM scores WHERE \(filter)
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
                                       composer: text(2, in: statement), instruments: text(3, in: statement)))
            }
        }
    }

    func pdf(for id: String) throws -> Data {
        try withStatement("SELECT content FROM score_pdf WHERE score_id = ?", bindings: [id]) { statement in
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { throw CatalogError.missingPDF }
            guard status == SQLITE_ROW else { throw CatalogError.queryFailed(status) }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw CatalogError.missingPDF }
            return Data(bytes: bytes, count: count)
        }
    }

    private func withStatement<Result>(_ sql: String, bindings: [String],
                                       read: (OpaquePointer) throws -> Result) throws -> Result {
        try Task.checkCancellation()
        let url = URL.documentsDirectory.appending(path: "PDMXScoreCatalog.sqlite")
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

struct ScorePDFSheet: View {
    let work: ScoreWork

    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    ScorePDFView(document: document)
                } else if failed {
                    ContentUnavailableView("无法打开曲谱", systemImage: "doc.badge.exclamationmark")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(work.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task(id: work.id) {
            do {
                let data = try await ScoreCatalog.shared.pdf(for: work.id)
                try Task.checkCancellation()
                document = PDFDocument(data: data)
                failed = document == nil
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }
}

private struct ScorePDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}

struct ScoreSearchResults: View {
    let query: String
    let onOpen: (ScoreWork) -> Void

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
                                onOpen(work)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(work.title).font(.subheadline.weight(.semibold))
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
                                        Image(systemName: "doc.text")
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
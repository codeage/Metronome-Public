import Foundation
import StoreKit

struct MetronomeUpdate {
    let version: String
    let destination: Destination

    enum Destination {
        case appStore(URL)
        case testFlight

        var buttonTitle: String {
            switch self {
            case .appStore: "前往 App Store"
            case .testFlight: "打开 TestFlight"
            }
        }
    }

    private struct AppStoreLookup: Decodable {
        struct Product: Decodable {
            let bundleId: String
            let version: String
            let minimumOsVersion: String
        }

        let results: [Product]
    }

    private struct TestFlightFeed: Decodable {
        struct Build: Decodable {
            let number: String
            let minimumOS: String
            let expiresAt: Int64
        }

        let bundleId: String
        let build: Build?
    }

    static func checkAtLaunch() async -> Self? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result,
              transaction.bundleID == bundleID else { return nil }

        switch transaction.environment {
        case .production:
            return await appStoreUpdate(bundleID: bundleID)
        case .sandbox:
            return await testFlightUpdate(bundleID: bundleID)
        default:
            return nil
        }
    }

    private static func appStoreUpdate(bundleID: String) async -> Self? {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let storefront = await Storefront.current,
              let country = AppStoreCountryCode.alpha2(for: storefront.countryCode),
              let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=6838589687&country=\(country)"),
              let lookup: AppStoreLookup = await fetch(lookupURL),
              let product = lookup.results.first(where: { $0.bundleId == bundleID }),
              isNewer(product.version, than: current), supportsOS(product.minimumOsVersion),
              let storeURL = URL(string: "https://apps.apple.com/\(country)/app/id6838589687") else { return nil }
        return Self(version: product.version, destination: .appStore(storeURL))
    }

    private static func testFlightUpdate(bundleID: String) async -> Self? {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let url = URL(string: "https://raw.githubusercontent.com/codeage/Metronome-Public/app-updates/testflight.json"),
              let feed: TestFlightFeed = await fetch(url), feed.bundleId == bundleID,
              let build = feed.build, isNewer(build.number, than: current),
              Date(timeIntervalSince1970: TimeInterval(build.expiresAt)) > .now,
              supportsOS(build.minimumOS) else { return nil }
        return Self(version: "Build \(build.number)", destination: .testFlight)
    }

    private static func fetch<Value: Decodable>(_ url: URL) async -> Value? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateParts = versionComponents(candidate),
              let currentParts = versionComponents(current) else { return false }
        return currentParts.lexicographicallyPrecedes(candidateParts)
    }

    private static func supportsOS(_ minimum: String) -> Bool {
        guard let parts = versionComponents(minimum) else { return false }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ![os.majorVersion, os.minorVersion, os.patchVersion].lexicographicallyPrecedes(parts)
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let tokens = version.split(separator: ".", omittingEmptySubsequences: false)
        let values = tokens.compactMap { Int($0) }
        guard (1...3).contains(tokens.count), values.count == tokens.count,
              values.allSatisfy({ $0 >= 0 }) else { return nil }
        return values + Array(repeating: 0, count: 3 - values.count)
    }
}

private enum AppStoreCountryCode {
    // StoreKit returns alpha-3 codes; the public App Store lookup accepts alpha-2.
    private static let codes = [
        "AFG": "af", "AGO": "ao", "AIA": "ai", "ALB": "al", "ARE": "ae",
        "ARG": "ar", "ARM": "am", "ATG": "ag", "AUS": "au", "AUT": "at",
        "AZE": "az", "BEL": "be", "BEN": "bj", "BFA": "bf", "BGR": "bg",
        "BHR": "bh", "BHS": "bs", "BIH": "ba", "BLR": "by", "BLZ": "bz",
        "BMU": "bm", "BOL": "bo", "BRA": "br", "BRB": "bb", "BRN": "bn",
        "BTN": "bt", "BWA": "bw", "CAN": "ca", "CHE": "ch", "CHL": "cl",
        "CHN": "cn", "CIV": "ci", "CMR": "cm", "COD": "cd", "COG": "cg",
        "COL": "co", "CPV": "cv", "CRI": "cr", "CYM": "ky", "CYP": "cy",
        "CZE": "cz", "DEU": "de", "DMA": "dm", "DNK": "dk", "DOM": "do",
        "DZA": "dz", "ECU": "ec", "EGY": "eg", "ESP": "es", "EST": "ee",
        "FIN": "fi", "FJI": "fj", "FRA": "fr", "FSM": "fm", "GAB": "ga",
        "GBR": "gb", "GEO": "ge", "GHA": "gh", "GMB": "gm", "GNB": "gw",
        "GRC": "gr", "GRD": "gd", "GTM": "gt", "GUY": "gy", "HKG": "hk",
        "HND": "hn", "HRV": "hr", "HUN": "hu", "IDN": "id", "IND": "in",
        "IRL": "ie", "IRQ": "iq", "ISL": "is", "ISR": "il", "ITA": "it",
        "JAM": "jm", "JOR": "jo", "JPN": "jp", "KAZ": "kz", "KEN": "ke",
        "KGZ": "kg", "KHM": "kh", "KNA": "kn", "KOR": "kr", "KWT": "kw",
        "LAO": "la", "LBN": "lb", "LBR": "lr", "LBY": "ly", "LCA": "lc",
        "LKA": "lk", "LTU": "lt", "LUX": "lu", "LVA": "lv", "MAC": "mo",
        "MAR": "ma", "MDA": "md", "MDG": "mg", "MDV": "mv", "MEX": "mx",
        "MKD": "mk", "MLI": "ml", "MLT": "mt", "MMR": "mm", "MNE": "me",
        "MNG": "mn", "MOZ": "mz", "MRT": "mr", "MSR": "ms", "MUS": "mu",
        "MWI": "mw", "MYS": "my", "NAM": "na", "NER": "ne", "NGA": "ng",
        "NIC": "ni", "NLD": "nl", "NOR": "no", "NPL": "np", "NRU": "nr",
        "NZL": "nz", "OMN": "om", "PAK": "pk", "PAN": "pa", "PER": "pe",
        "PHL": "ph", "PLW": "pw", "PNG": "pg", "POL": "pl", "PRT": "pt",
        "PRY": "py", "QAT": "qa", "ROU": "ro", "RUS": "ru", "RWA": "rw",
        "SAU": "sa", "SEN": "sn", "SGP": "sg", "SLB": "sb", "SLE": "sl",
        "SLV": "sv", "SRB": "rs", "STP": "st", "SUR": "sr", "SVK": "sk",
        "SVN": "si", "SWE": "se", "SWZ": "sz", "SYC": "sc", "TCA": "tc",
        "TCD": "td", "THA": "th", "TJK": "tj", "TKM": "tm", "TON": "to",
        "TTO": "tt", "TUN": "tn", "TUR": "tr", "TWN": "tw", "TZA": "tz",
        "UGA": "ug", "UKR": "ua", "URY": "uy", "USA": "us", "UZB": "uz",
        "VCT": "vc", "VEN": "ve", "VGB": "vg", "VNM": "vn", "VUT": "vu",
        "XKS": "xk", "YEM": "ye", "ZAF": "za", "ZMB": "zm", "ZWE": "zw",
    ]

    static func alpha2(for code: String) -> String? {
        codes[code.uppercased()]
    }
}

//
//  EarningsFeature.swift
//  StockEarnings
//
//  Created by Codex on 8/27/26.
//

import Foundation
import SwiftUI
import Combine

enum MembershipGroup: String, CaseIterable, Identifiable {
    case sp100 = "S&P100"
    case russell1000 = "arrRussel1000Stocks"
    case russell2000 = "Russel2000"
    case occTop500 = "OCCNormalizedTop500"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sp100:
            return "S&P100"
        case .russell1000:
            return "Russell 1000"
        case .russell2000:
            return "Russell 2000"
        case .occTop500:
            return "OCC Top 500"
        }
    }
}

struct EarningsRow: Identifiable, Hashable {
    let index: String
    let reportDate: String
    let symbol: String
    let name: String
    let estimate: String
    let timeOfTheDay: String

    var id: String { "\(reportDate)|\(symbol)|\(index)" }

    var membershipSet: Set<String> {
        Set(index.split(separator: ",").map(String.init))
    }

    var marketSessionSortOrder: Int {
        switch timeOfTheDay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bmo": return 0
        case "amc": return 1
        default: return 2
        }
    }

    var displayTimeOfTheDay: String {
        switch timeOfTheDay.lowercased() {
        case "bmo":
            return "Before Open"
        case "amc":
            return "After Close"
        case let value where value.isEmpty:
            return "Unknown"
        default:
            return timeOfTheDay
        }
    }
}

enum StockLookback: String, CaseIterable, Identifiable {
    case oneDay = "1d"
    case twoDays = "2d"
    case threeDays = "3d"
    case oneWeek = "1w"
    case twoWeeks = "2w"
    case oneMonth = "1m"
    case threeMonths = "3m"
    case sixMonths = "6m"
    case oneYear = "1y"
    case twoYears = "2y"

    var id: String { rawValue }

    func startDate(before anchorDate: Date, calendar: Calendar) -> Date? {
        let anchor = calendar.startOfDay(for: anchorDate)
        switch self {
        case .oneDay, .twoDays, .threeDays:
            var remainingDays = -(offset.day ?? 0)
            var date = anchor
            while remainingDays > 0 {
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: date) else {
                    return nil
                }
                date = previousDay
                let weekday = calendar.component(.weekday, from: date)
                if weekday != 1 && weekday != 7 {
                    remainingDays -= 1
                }
            }
            return date
        default:
            guard let date = calendar.date(byAdding: offset, to: anchor) else {
                return nil
            }
            switch calendar.component(.weekday, from: date) {
            case 7: return calendar.date(byAdding: .day, value: -1, to: date)
            case 1: return calendar.date(byAdding: .day, value: 1, to: date)
            default: return date
            }
        }
    }

    private var offset: DateComponents {
        switch self {
        case .oneDay: return DateComponents(day: -1)
        case .twoDays: return DateComponents(day: -2)
        case .threeDays: return DateComponents(day: -3)
        case .oneWeek: return DateComponents(day: -7)
        case .twoWeeks: return DateComponents(day: -14)
        case .oneMonth: return DateComponents(month: -1)
        case .threeMonths: return DateComponents(month: -3)
        case .sixMonths: return DateComponents(month: -6)
        case .oneYear: return DateComponents(year: -1)
        case .twoYears: return DateComponents(year: -2)
        }
    }
}

struct StockPricePoint: Hashable {
    let date: Date
    let close: Double
}

struct StockPerformanceSnapshot: Hashable {
    let symbol: String
    let currentPrice: Double
    let anchorDate: Date
    let prices: [StockPricePoint]

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    func relativePrice(period: StockLookback) -> Double? {
        guard let startDate = period.startDate(before: anchorDate, calendar: calendar) else {
            return nil
        }
        let windowPrices = prices.filter {
            let day = calendar.startOfDay(for: $0.date)
            return day >= startDate && day <= anchorDate
        }
        guard let minPrice = windowPrices.map(\.close).min(),
              let maxPrice = windowPrices.map(\.close).max(),
              maxPrice > minPrice else {
            return nil
        }
        return 100 * ((currentPrice - minPrice) / (maxPrice - minPrice))
    }

    func gainPercent(period: StockLookback) -> Double? {
        guard let targetDate = period.startDate(before: anchorDate, calendar: calendar),
              let historicalPrice = prices.last(where: {
                  calendar.startOfDay(for: $0.date) <= targetDate
              })?.close else {
            return nil
        }
        return ((currentPrice - historicalPrice) / currentPrice) * 100
    }
}

enum EarningsError: LocalizedError {
    case invalidResponse
    case rateLimited
    case invalidDateRange
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Alpha Vantage returned an invalid response."
        case .invalidDateRange:
            return "DateFrom must be on or before DateTo."
        case .rateLimited:
            return "Alpha Vantage rate limit reached. Try again shortly."
        case .apiError(let message):
            return message
        }
    }
}

enum StockPriceError: LocalizedError {
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Yahoo Finance returned an invalid response."
        case .unavailable:
            return "Price history is unavailable for this symbol."
        }
    }
}

struct EarningsService {
    private let apiKey = "7LSXOMBJO0A4TCG9"
    private let session: URLSession
    private let calendar = Calendar(identifier: .gregorian)
    private let cacheURL: URL

    nonisolated init(session: URLSession = .shared, cacheURL: URL? = nil) {
        self.session = session
        self.cacheURL = cacheURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("StockEarnings", isDirectory: true)
            .appendingPathComponent("earnings-calendar.csv")
    }

    func cachedHistoricalEarnings(from startDate: Date, to endDate: Date) throws -> [EarningsRow] {
        let today = isoDateFormatter.string(from: Date())
        return filterRows(try readCache().filter { $0["reportDate", default: ""] < today },
                          from: startDate, to: endDate)
    }

    func fetchEarnings(from startDate: Date, to endDate: Date) async throws -> [EarningsRow] {
        guard normalizedDay(startDate) <= normalizedDay(endDate) else {
            throw EarningsError.invalidDateRange
        }
        let today = normalizedDay(Date())
        if normalizedDay(endDate) < today {
            return try cachedHistoricalEarnings(from: startDate, to: endDate)
        }
        let horizon = [3, 6, 12].first { months in
            endDate <= (calendar.date(byAdding: .month, value: months, to: today) ?? today)
        } ?? 12
        var components = URLComponents(string: "https://www.alphavantage.co/query")
        components?.queryItems = [
            URLQueryItem(name: "function", value: "EARNINGS_CALENDAR"),
            URLQueryItem(name: "horizon", value: "\(horizon)month"),
            URLQueryItem(name: "apikey", value: apiKey),
        ]

        guard let url = components?.url else {
            throw EarningsError.invalidResponse
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw EarningsError.invalidResponse
        }

        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EarningsError.invalidResponse
        }

        if raw.contains("Thank you for using Alpha Vantage") {
            throw EarningsError.rateLimited
        }

        if raw.hasPrefix("{"), raw.contains("Error Message") {
            throw EarningsError.apiError("Alpha Vantage error: \(raw)")
        }

        let dictionaries = try decodeCalendar(raw)
        // Re-read after the network request so another completed fetch is preserved.
        let cached = try readCache()
        let todayString = isoDateFormatter.string(from: today)
        let horizonEnd = isoDateFormatter.string(from:
            calendar.date(byAdding: .month, value: horizon, to: today) ?? today)
        // Replace the fetched window so rescheduled or removed events do not linger.
        let retained = cached.filter {
            let date = $0["reportDate", default: ""]
            return date < todayString || date > horizonEnd
        }
        var merged: [String: [String: String]] = [:]
        for row in retained + dictionaries {
            let key = row["symbol", default: ""].uppercased() + "|" + row["reportDate", default: ""]
            merged[key] = row
        }
        try writeCache(Array(merged.values))
        let historical = cached.filter { $0["reportDate", default: ""] < todayString }
        return filterRows(historical + dictionaries.filter {
            $0["reportDate", default: ""] >= todayString
        }, from: startDate, to: endDate)
    }

    private func readCache() throws -> [[String: String]] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return [] }
        return try decodeCalendar(String(contentsOf: cacheURL, encoding: .utf8))
    }

    private func decodeCalendar(_ raw: String) throws -> [[String: String]] {
        let csvRows = parseCSV(raw)
        guard let header = csvRows.first,
              Set(header).count == header.count,
              ["symbol", "name", "reportDate"].allSatisfy(header.contains) else {
            throw EarningsError.invalidResponse
        }
        return try csvRows.dropFirst().map { row in
            guard row.count == header.count else { throw EarningsError.invalidResponse }
            let values = Dictionary(uniqueKeysWithValues: zip(header, row))
            guard !values["symbol", default: ""].isEmpty,
                  isoDateFormatter.date(from: values["reportDate", default: ""]) != nil else {
                throw EarningsError.invalidResponse
            }
            return values
        }
    }

    private func writeCache(_ rows: [[String: String]]) throws {
        let header = Set(rows.flatMap { $0.keys }).union(["symbol", "name", "reportDate"]).sorted()
        func escape(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let sorted = rows.sorted {
            ($0["reportDate", default: ""], $0["symbol", default: ""]) <
            ($1["reportDate", default: ""], $1["symbol", default: ""])
        }
        let lines = [header] + sorted.map { row in header.map { row[$0, default: ""] } }
        let csv = lines.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try csv.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    private func filterRows(_ rows: [[String: String]], from startDate: Date, to endDate: Date) -> [EarningsRow] {
        let memberships: [(String, Set<String>)] = [
            ("S&P100", StockUniverse.sp100),
            ("arrRussel1000Stocks", StockUniverse.russell1000),
            ("Russel2000", StockUniverse.russell2000),
            ("OCCNormalizedTop500", StockUniverse.occTop500),
        ]
        let rejectSet = Set(["Russel2000"])
        let cutoff = 300
        let normalizedStartDate = normalizedDay(startDate)
        let normalizedEndDate = normalizedDay(endDate)

        var filtered: [EarningsRow] = []

        for sourceRow in rows {
            let symbol = sourceRow["symbol", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let occRank = StockUniverse.occRank[symbol], occRank <= cutoff else {
                continue
            }

            let reportDate = sourceRow["reportDate", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let reportComponents = isoDateFormatter.date(from: reportDate),
                normalizedDay(reportComponents) >= normalizedStartDate,
                normalizedDay(reportComponents) <= normalizedEndDate
            else {
                continue
            }

            let matchedMemberships = memberships.compactMap { name, symbols in
                symbols.contains(symbol) ? name : nil
            }

            guard !matchedMemberships.isEmpty else {
                continue
            }

            if Set(matchedMemberships) == rejectSet {
                continue
            }

            filtered.append(
                EarningsRow(
                    index: matchedMemberships.joined(separator: ","),
                    reportDate: reportDate,
                    symbol: sourceRow["symbol", default: ""],
                    name: sourceRow["name", default: ""],
                    estimate: sourceRow["estimate", default: ""],
                    timeOfTheDay: sourceRow["timeOfTheDay", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return filtered.sorted { lhs, rhs in
            if lhs.reportDate != rhs.reportDate {
                return lhs.reportDate < rhs.reportDate
            }
            if lhs.marketSessionSortOrder != rhs.marketSessionSortOrder {
                return lhs.marketSessionSortOrder < rhs.marketSessionSortOrder
            }
            return lhs.symbol < rhs.symbol
        }
    }

    private func parseCSV(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var values: [String] = []
        var current = ""
        var insideQuotes = false
        var index = csv.startIndex
        while index < csv.endIndex {
            let character = csv[index]
            if character == "\"" {
                let nextIndex = csv.index(after: index)
                if insideQuotes, nextIndex < csv.endIndex, csv[nextIndex] == "\"" {
                    current.append("\"")
                    index = csv.index(after: nextIndex)
                    continue
                }
                insideQuotes.toggle()
            } else if character == ",", !insideQuotes {
                values.append(current)
                current = ""
            } else if character.isNewline, !insideQuotes {
                if !values.isEmpty || !current.isEmpty {
                    rows.append(values + [current])
                }
                values = []
                current = ""
            } else {
                current.append(character)
            }
            index = csv.index(after: index)
        }
        if !values.isEmpty || !current.isEmpty { rows.append(values + [current]) }
        return rows
    }

    private func normalizedDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private var isoDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

struct StockPriceService {
    private let session: URLSession
    private let calendar = Calendar(identifier: .gregorian)

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchPerformance(for symbol: String) async throws -> StockPerformanceSnapshot {
        let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedSymbol)?interval=1d&range=2y&includePrePost=false"
        guard let url = URL(string: urlString) else {
            throw StockPriceError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw StockPriceError.invalidResponse
        }

        let payload = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard
            let result = payload.chart.result?.first,
            let timestamps = result.timestamp,
            let closes = result.indicators.quote.first?.close
        else {
            throw StockPriceError.unavailable
        }

        let prices: [StockPricePoint] = zip(timestamps, closes).compactMap { timestamp, close in
            guard let close else { return nil }
            return StockPricePoint(date: Date(timeIntervalSince1970: TimeInterval(timestamp)), close: close)
        }
        .sorted { $0.date < $1.date }

        guard !prices.isEmpty else {
            throw StockPriceError.unavailable
        }

        let currentPrice = result.meta.regularMarketPrice ?? prices.last?.close ?? 0
        guard currentPrice > 0 else {
            throw StockPriceError.unavailable
        }

        let anchorDate = calendar.startOfDay(for: result.meta.regularMarketTime.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        } ?? Date())

        return StockPerformanceSnapshot(
            symbol: symbol,
            currentPrice: currentPrice,
            anchorDate: anchorDate,
            prices: prices
        )
    }
}

private struct YahooChartResponse: Decodable {
    let chart: Chart

    struct Chart: Decodable {
        let result: [Result]?
    }

    struct Result: Decodable {
        let meta: Meta
        let timestamp: [Int]?
        let indicators: Indicators
    }

    struct Meta: Decodable {
        let regularMarketPrice: Double?
        let regularMarketTime: Int?
    }

    struct Indicators: Decodable {
        let quote: [Quote]
    }

    struct Quote: Decodable {
        let close: [Double?]
    }
}

@MainActor
final class EarningsViewModel: ObservableObject {
    @Published var dateFrom: Date
    @Published var dateTo: Date
    @Published var enabledGroups = Set(MembershipGroup.allCases)
    @Published private(set) var rows: [EarningsRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedRow: EarningsRow?
    @Published private(set) var selectedPerformance: StockPerformanceSnapshot?
    @Published private(set) var isLoadingPerformance = false
    @Published private(set) var performanceErrorMessage: String?

    private let service: EarningsService
    private let priceService: StockPriceService
    private var activeRequestID: UUID?

    init(
        service: EarningsService = EarningsService(),
        priceService: StockPriceService = StockPriceService(),
        calendar: Calendar = .current
    ) {
        self.service = service
        self.priceService = priceService
        let today = calendar.startOfDay(for: Date())
        self.dateFrom = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        self.dateTo = Self.currentWeekSaturday(from: today, calendar: calendar) ?? today
    }

    func load() async {
        let requestID = UUID()
        activeRequestID = requestID
        let startDate = dateFrom
        let endDate = dateTo
        isLoading = true
        errorMessage = nil
        rows = []

        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }

        do {
            rows = try service.cachedHistoricalEarnings(from: startDate, to: endDate)
            let fetchedRows = try await service.fetchEarnings(from: startDate, to: endDate)
            guard !Task.isCancelled, activeRequestID == requestID,
                  dateFrom == startDate, dateTo == endDate else { return }
            rows = fetchedRows
            if let selectedSymbol = selectedRow?.symbol {
                selectedRow = rows.first(where: { $0.symbol == selectedSymbol })
            }
        } catch {
            guard !Task.isCancelled, activeRequestID == requestID,
                  dateFrom == startDate, dateTo == endDate else { return }
            selectedRow = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func toggle(_ group: MembershipGroup) {
        if enabledGroups.contains(group) {
            enabledGroups.remove(group)
        } else {
            enabledGroups.insert(group)
        }
    }

    var filteredRows: [EarningsRow] {
        guard !enabledGroups.isEmpty else {
            return []
        }

        let selectedMemberships = Set(enabledGroups.map(\.rawValue))
        return rows.filter { !$0.membershipSet.isDisjoint(with: selectedMemberships) }
    }

    func select(_ row: EarningsRow) async {
        selectedRow = row
        selectedPerformance = nil
        performanceErrorMessage = nil
        isLoadingPerformance = true

        do {
            selectedPerformance = try await priceService.fetchPerformance(for: row.symbol)
        } catch {
            performanceErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isLoadingPerformance = false
    }

    private static func currentWeekSaturday(from today: Date, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: today)
        let saturdayWeekday = 7
        let daysUntilSaturday = (saturdayWeekday - weekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysUntilSaturday, to: today)
    }
}

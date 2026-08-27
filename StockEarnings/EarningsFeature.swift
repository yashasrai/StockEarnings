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

struct StockPerformanceMetric: Identifiable, Hashable {
    let label: String
    let value: Double

    var id: String { label }
    var displayValue: String { String(format: "%.2f%%", value) }
}

struct StockPerformanceSnapshot: Hashable {
    let symbol: String
    let currentPrice: Double
    let metrics: [StockPerformanceMetric]
}

enum EarningsError: LocalizedError {
    case invalidResponse
    case rateLimited
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Alpha Vantage returned an invalid response."
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

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchEarnings(from startDate: Date, to endDate: Date) async throws -> [EarningsRow] {
        var components = URLComponents(string: "https://www.alphavantage.co/query")
        components?.queryItems = [
            URLQueryItem(name: "function", value: "EARNINGS_CALENDAR"),
            URLQueryItem(name: "horizon", value: "3month"),
            URLQueryItem(name: "apikey", value: apiKey),
        ]

        guard let url = components?.url else {
            throw EarningsError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
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

        let csvRows = parseCSV(raw)
        guard let header = csvRows.first else {
            return []
        }

        let dictionaries = csvRows.dropFirst().map { row -> [String: String] in
            Dictionary(uniqueKeysWithValues: zip(header, row))
        }

        return filterRows(dictionaries, from: startDate, to: endDate)
    }

    private func filterRows(_ rows: [[String: String]], from startDate: Date, to endDate: Date) -> [EarningsRow] {
        let memberships: [(String, Set<String>)] = [
            ("S&P100", StockUniverse.sp100),
            ("arrRussel1000Stocks", StockUniverse.russell1000),
            ("Russel2000", StockUniverse.russell2000),
            ("OCCNormalizedTop500", StockUniverse.occTop500),
        ]
        let indexOrder = Dictionary(uniqueKeysWithValues: memberships.enumerated().map { ($1.0, $0) })
        let rejectSet = Set(["Russel2000"])
        let cutoff = 300
        let normalizedStartDate = normalizedDay(startDate)
        let normalizedEndDate = normalizedDay(adjustedEndDate(start: startDate, end: endDate))

        var filtered: [(row: EarningsRow, membershipCount: Int)] = []

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

            filtered.append((
                row: EarningsRow(
                    index: matchedMemberships.joined(separator: ","),
                    reportDate: reportDate,
                    symbol: sourceRow["symbol", default: ""],
                    name: sourceRow["name", default: ""],
                    estimate: sourceRow["estimate", default: ""],
                    timeOfTheDay: sourceRow["timeOfTheDay", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                membershipCount: matchedMemberships.count
            ))
        }

        filtered.sort { lhs, rhs in
            if lhs.membershipCount != rhs.membershipCount {
                return lhs.membershipCount > rhs.membershipCount
            }

            let lhsFirstIndex = lhs.row.index.split(separator: ",").first.map(String.init) ?? ""
            let rhsFirstIndex = rhs.row.index.split(separator: ",").first.map(String.init) ?? ""
            let lhsOrder = indexOrder[lhsFirstIndex] ?? .max
            let rhsOrder = indexOrder[rhsFirstIndex] ?? .max

            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }

            if lhs.row.reportDate != rhs.row.reportDate {
                return lhs.row.reportDate < rhs.row.reportDate
            }

            return lhs.row.symbol < rhs.row.symbol
        }

        return filtered.map(\.row)
    }

    private func parseCSV(_ csv: String) -> [[String]] {
        csv
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map(parseCSVLine)
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var insideQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let nextIndex = line.index(after: index)
                if insideQuotes, nextIndex < line.endIndex, line[nextIndex] == "\"" {
                    current.append("\"")
                    index = line.index(after: nextIndex)
                    continue
                }
                insideQuotes.toggle()
            } else if character == ",", !insideQuotes {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }

        values.append(current)
        return values
    }

    private func normalizedDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func adjustedEndDate(start: Date, end: Date) -> Date {
        let startComponents = calendar.dateComponents([.month, .day], from: start)
        let endComponents = calendar.dateComponents([.month, .day], from: end)
        guard let startMonth = startComponents.month, let startDay = startComponents.day,
              let endMonth = endComponents.month, let endDay = endComponents.day else {
            return end
        }

        if (endMonth, endDay) < (startMonth, startDay) {
            return calendar.date(byAdding: .year, value: 1, to: end) ?? end
        }

        return end
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

        let prices: [(date: Date, close: Double)] = zip(timestamps, closes).compactMap { timestamp, close in
            guard let close else { return nil }
            return (Date(timeIntervalSince1970: TimeInterval(timestamp)), close)
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

        let metricDefinitions: [(String, DateComponents)] = [
            ("1D", DateComponents(day: -1)),
            ("2D", DateComponents(day: -2)),
            ("3D", DateComponents(day: -3)),
            ("1W", DateComponents(day: -7)),
            ("1M", DateComponents(month: -1)),
            ("1Y", DateComponents(year: -1)),
            ("2Y", DateComponents(year: -2)),
        ]

        let metrics = metricDefinitions.compactMap { label, offset -> StockPerformanceMetric? in
            guard
                let targetDate = calendar.date(byAdding: offset, to: anchorDate),
                let historicalPrice = historicalPrice(onOrBefore: targetDate, from: prices)
            else {
                return nil
            }

            let gain = ((currentPrice - historicalPrice) / currentPrice) * 100
            return StockPerformanceMetric(label: label, value: gain)
        }

        let relativeMetricDefinitions: [(String, DateComponents)] = [
            ("1YRelative", DateComponents(year: -1)),
            ("6MRelative", DateComponents(month: -6)),
            ("3MRelative", DateComponents(month: -3)),
            ("1MRelative", DateComponents(month: -1)),
        ]

        let relativeMetrics = relativeMetricDefinitions.compactMap { label, offset -> StockPerformanceMetric? in
            guard
                let startDate = calendar.date(byAdding: offset, to: anchorDate),
                let windowPrices = pricesInRange(startingAt: startDate, endingAt: anchorDate, from: prices),
                let minPrice = windowPrices.map(\.close).min(),
                let maxPrice = windowPrices.map(\.close).max(),
                maxPrice > minPrice
            else {
                return nil
            }

            let relative = 100 * ((currentPrice - minPrice) / (maxPrice - minPrice))
            return StockPerformanceMetric(label: label, value: relative)
        }

        return StockPerformanceSnapshot(symbol: symbol, currentPrice: currentPrice, metrics: metrics + relativeMetrics)
    }

    private func historicalPrice(onOrBefore targetDate: Date, from prices: [(date: Date, close: Double)]) -> Double? {
        let normalizedTarget = calendar.startOfDay(for: targetDate)
        return prices.last(where: { calendar.startOfDay(for: $0.date) <= normalizedTarget })?.close
    }

    private func pricesInRange(
        startingAt startDate: Date,
        endingAt endDate: Date,
        from prices: [(date: Date, close: Double)]
    ) -> [(date: Date, close: Double)]? {
        let normalizedStart = calendar.startOfDay(for: startDate)
        let normalizedEnd = calendar.startOfDay(for: endDate)
        let filtered = prices.filter {
            let date = calendar.startOfDay(for: $0.date)
            return date >= normalizedStart && date <= normalizedEnd
        }
        return filtered.isEmpty ? nil : filtered
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
    private var hasLoaded = false
    var hasFinishedInitialLoad: Bool { hasLoaded }

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

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        do {
            rows = try await service.fetchEarnings(from: dateFrom, to: dateTo)
            if let selectedSymbol = selectedRow?.symbol {
                selectedRow = rows.first(where: { $0.symbol == selectedSymbol })
            }
        } catch {
            rows = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isLoading = false
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

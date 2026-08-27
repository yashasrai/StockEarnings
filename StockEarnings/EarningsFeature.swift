//
//  EarningsFeature.swift
//  StockEarnings
//
//  Created by Codex on 8/27/26.
//

import Foundation
import SwiftUI
import Combine

struct EarningsRow: Identifiable, Hashable {
    let index: String
    let reportDate: String
    let symbol: String
    let name: String
    let estimate: String

    var id: String { "\(reportDate)|\(symbol)|\(index)" }
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
                    estimate: sourceRow["estimate", default: ""]
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

@MainActor
final class EarningsViewModel: ObservableObject {
    @Published var dateFrom: Date
    @Published var dateTo: Date
    @Published private(set) var rows: [EarningsRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: EarningsService
    private var hasLoaded = false

    init(service: EarningsService = EarningsService(), calendar: Calendar = .current) {
        self.service = service
        let currentYear = calendar.component(.year, from: Date())
        self.dateFrom = calendar.date(from: DateComponents(year: currentYear, month: 8, day: 26)) ?? Date()
        self.dateTo = calendar.date(from: DateComponents(year: currentYear, month: 9, day: 5)) ?? Date()
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
        } catch {
            rows = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isLoading = false
    }
}

//
//  ContentView.swift
//  StockEarnings
//
//  Created by Yashas Rai on 8/26/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = EarningsViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                controls
                status
                detailPane
                resultsTable
            }
            .padding()
            .navigationTitle("Stock Earnings")
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .task(id: viewModel.dateFrom) {
            guard viewModel.hasFinishedInitialLoad else { return }
            await viewModel.load()
        }
        .task(id: viewModel.dateTo) {
            guard viewModel.hasFinishedInitialLoad else { return }
            await viewModel.load()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DatePicker("DateFrom", selection: $viewModel.dateFrom, displayedComponents: .date)
                DatePicker("DateTo", selection: $viewModel.dateTo, displayedComponents: .date)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MembershipGroup.allCases) { group in
                        Toggle(group.title, isOn: binding(for: group))
                            .toggleStyle(.button)
                            .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        } else {
            Text("\(viewModel.filteredRows.count) rows")
                .foregroundStyle(.secondary)
        }
    }

    private var resultsTable: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                tableHeader
                ForEach(viewModel.filteredRows) { row in
                    tableRow(row)
                    Divider()
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedRow = viewModel.selectedRow {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selectedRow.symbol)
                        .font(.headline)
                        .fontDesign(.monospaced)
                    Text(selectedRow.name)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isLoadingPerformance {
                    ProgressView("Loading price metrics...")
                } else if let errorMessage = viewModel.performanceErrorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if let performance = viewModel.selectedPerformance {
                    Text("Current Price: \(String(format: "%.2f", performance.currentPrice))")
                        .font(.subheadline)

                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 92), spacing: 8)
                    ], spacing: 8) {
                        ForEach(performance.metrics) { metric in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(metric.displayValue)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(uiColor: .systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(uiColor: .systemGray6))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            headerCell("Report Date", width: 120)
            headerCell("Timing", width: 120)
            headerCell("Symbol", width: 90)
            headerCell("Name", width: 320)
        }
        .font(.headline)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemGray5))
    }

    private func tableRow(_ row: EarningsRow) -> some View {
        HStack(spacing: 0) {
            bodyCell(row.reportDate, width: 120)
            bodyCell(row.displayTimeOfTheDay, width: 120)
            bodyCell(row.symbol, width: 90, monospaced: true)
            bodyCell(row.name, width: 320)
        }
        .padding(.vertical, 10)
        .background(row.id == viewModel.selectedRow?.id ? Color(uiColor: .systemGray5) : Color(uiColor: .secondarySystemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await viewModel.select(row)
            }
        }
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 12)
    }

    private func bodyCell(_ value: String, width: CGFloat, monospaced: Bool = false) -> some View {
        Group {
            if monospaced {
                Text(value)
                    .fontDesign(.monospaced)
            } else {
                Text(value)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func binding(for group: MembershipGroup) -> Binding<Bool> {
        Binding(
            get: { viewModel.enabledGroups.contains(group) },
            set: { _ in viewModel.toggle(group) }
        )
    }
}

#Preview {
    ContentView()
}

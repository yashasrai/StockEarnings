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

            VStack(alignment: .leading, spacing: 8) {
                Text("Membership Filters")
                    .font(.headline)

                ForEach(MembershipGroup.allCases) { group in
                    Toggle(isOn: binding(for: group)) {
                        Text(group.title)
                    }
                    .toggleStyle(.switch)
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
        .background(Color(uiColor: .secondarySystemBackground))
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

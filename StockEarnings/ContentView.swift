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
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DatePicker("DateFrom", selection: $viewModel.dateFrom, displayedComponents: .date)
                DatePicker("DateTo", selection: $viewModel.dateTo, displayedComponents: .date)
            }

            Button {
                Task {
                    await viewModel.load()
                }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Fetch Earnings")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        } else {
            Text("\(viewModel.rows.count) rows")
                .foregroundStyle(.secondary)
        }
    }

    private var resultsTable: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                tableHeader
                ForEach(viewModel.rows) { row in
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
            headerCell("Symbol", width: 90)
            headerCell("Name", width: 260)
            headerCell("Estimate", width: 110)
            headerCell("Index", width: 260)
        }
        .font(.headline)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemGray5))
    }

    private func tableRow(_ row: EarningsRow) -> some View {
        HStack(spacing: 0) {
            bodyCell(row.reportDate, width: 120)
            bodyCell(row.symbol, width: 90, monospaced: true)
            bodyCell(row.name, width: 260)
            bodyCell(row.estimate, width: 110)
            bodyCell(row.index, width: 260)
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
}

#Preview {
    ContentView()
}

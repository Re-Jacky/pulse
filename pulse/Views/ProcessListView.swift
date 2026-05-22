import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var searchText = ""
    @State private var sortByColumn: SortColumn = .cpu
    @State private var sortAscending = false
    @State private var processToKill: ProcessInfo2? = nil
    @State private var killError: String? = nil
    @State private var showKillConfirm = false

    private let processMonitor = ProcessMonitor()

    enum SortColumn { case name, cpu, mem }

    private var filtered: [ProcessInfo2] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let base: [ProcessInfo2]
        if trimmed.isEmpty {
            base = monitor.processes
        } else if let port = UInt16(trimmed) {
            base = monitor.processes.filter { $0.ports.contains(port) }
        } else {
            base = monitor.processes.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }
        }

        return base.sorted {
            switch sortByColumn {
            case .name: return sortAscending ? $0.name < $1.name : $0.name > $1.name
            case .cpu: return sortAscending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent
            case .mem: return sortAscending ? $0.memoryMB < $1.memoryMB : $0.memoryMB > $1.memoryMB
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter by name or port…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .cornerRadius(7)
                .padding(.bottom, 10)

            HStack(spacing: 0) {
                sortHeader("NAME", column: .name, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                sortHeader("CPU", column: .cpu, alignment: .trailing)
                    .frame(width: 38, alignment: .trailing)
                sortHeader("MEM", column: .mem, alignment: .trailing)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            Divider().background(Color.white.opacity(0.06))

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { process in
                        ProcessRowView(process: process) {
                            processToKill = process
                            showKillConfirm = true
                        }
                        Divider().background(Color.white.opacity(0.04))
                    }
                }
            }

            Text("Right-click a process to kill it")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.20))
                .padding(.top, 8)
        }
        .padding(16)
        .alert("Kill Process?", isPresented: $showKillConfirm, presenting: processToKill) { p in
            Button("Cancel", role: .cancel) {}
            Button("Kill \(p.name)", role: .destructive) {
                let result = processMonitor.kill(pid: p.id)
                if case .failure(let error) = result {
                    killError = error.description
                }
            }
        } message: { p in
            Text("Kill \(p.name) (PID \(p.id))?")
        }
        .alert("Error", isPresented: .init(get: { killError != nil }, set: { if !$0 { killError = nil } })) {
            Button("OK") { killError = nil }
        } message: {
            Text(killError ?? "")
        }
    }

    @ViewBuilder
    private func sortHeader(_ title: String, column: SortColumn, alignment: Alignment) -> some View {
        Button(action: {
            if sortByColumn == column {
                sortAscending.toggle()
            } else {
                sortByColumn = column
                sortAscending = column == .name
            }
        }) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .regular))
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundColor(.white.opacity(sortByColumn == column ? 0.6 : 0.25))
                if sortByColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

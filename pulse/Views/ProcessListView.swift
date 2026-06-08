import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @AppStorage("processSearchText") private var searchText = ""
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
            let matchingPids = processMonitor.pidsListening(on: port)
            base = monitor.processes.filter { matchingPids.contains($0.id) }
        } else {
            base = monitor.processes.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed) ||
                $0.workingDir.localizedCaseInsensitiveContains(trimmed)
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
                .foregroundColor(.appPrimaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appFieldBackground)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.appFieldBorder, lineWidth: 1))
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

            Divider().background(Color.appDivider)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { process in
                        ProcessRowView(process: process) {
                            processToKill = process
                            showKillConfirm = true
                        }
                        Divider().background(Color.appDivider)
                    }
                }
            }

            Text("Right-click a process to kill it")
                .font(.system(size: 10))
                .foregroundColor(.appQuaternaryText)
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
                    .foregroundColor(sortByColumn == column ? .appSecondaryText : .appTertiaryText)
                if sortByColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                        .foregroundColor(.appSecondaryText)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

# All-Source Summary + Source Picker Hit Area — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "All" option to the agent source picker showing combined usage metrics across both sources, and fix the source picker hit area so the entire capsule segment is tappable.

**Architecture:** Add `AgentSource.all` as a virtual source case. `AgentUsageStore` gains a static helper to merge two `AgentUsageSummary` values. `AgentUsageView` routes to a combined summary + project selector when `.all` is selected, hiding session selector, context rows, and by-model table.

**Tech Stack:** Swift 5.9+, macOS 14.0+, SwiftUI, no external dependencies.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `pulse/Managers/AgentUsageModels.swift` | Modify | Add `AgentSource.all` case + `AgentUsageSummary.merge()` static method |
| `pulse/Views/AgentSourcePicker.swift` | Modify | Add `.contentShape(Rectangle())` to button labels |
| `pulse/Managers/AgentUsageStore.swift` | Modify | Update `availableSources` to include `.all`, update `databasePath`, update `refresh()` / `refreshIfNeeded()` to handle `.all` |
| `pulse/Views/AgentUsageView.swift` | Modify | Route `.all` in all computed properties, show/hide sections conditionally |

---

### Task 1: Add `AgentSource.all` case and `AgentUsageSummary.merge()`

**Files:**
- Modify: `pulse/Managers/AgentUsageModels.swift`

- [ ] **Step 1: Add `.all` case to `AgentSource` enum and update `displayName`**

Replace lines 3-15 of `AgentUsageModels.swift`:

```swift
enum AgentSource: String, CaseIterable, Identifiable {
    case all = "all"
    case openCode = "opencode"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .openCode: return "OpenCode"
        case .codex: return "Codex"
        }
    }
}
```

- [ ] **Step 2: Add `merge()` static method to `AgentUsageSummary`**

Add after the `AgentUsageSummary` struct (after line 60):

```swift
extension AgentUsageSummary {
    static func merge(_ a: AgentUsageSummary, _ b: AgentUsageSummary) -> AgentUsageSummary {
        AgentUsageSummary(
            totalTokens: a.totalTokens + b.totalTokens,
            inputTokens: mergeOptional(a.inputTokens, b.inputTokens, +),
            outputTokens: mergeOptional(a.outputTokens, b.outputTokens, +),
            reasoningTokens: mergeOptional(a.reasoningTokens, b.reasoningTokens, +),
            cacheReadTokens: mergeOptional(a.cacheReadTokens, b.cacheReadTokens, +),
            cacheWriteTokens: mergeOptional(a.cacheWriteTokens, b.cacheWriteTokens, +),
            sessionsCount: a.sessionsCount + b.sessionsCount,
            cost: mergeOptional(a.cost, b.cost, +),
            lastUpdated: {
                switch (a.lastUpdated, b.lastUpdated) {
                case let (a?, b?): return max(a, b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }()
        )
    }

    private static func mergeOptional<T: Numeric>(_ a: T?, _ b: T?, _ op: (T, T) -> T) -> T? {
        switch (a, b) {
        case let (a?, b?): return op(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -10
```

Expected: Compilation errors only in `AgentUsageStore` and `AgentUsageView` (switch exhaustiveness). We'll fix those in subsequent tasks.

- [ ] **Step 4: Commit**

```bash
git add pulse/Managers/AgentUsageModels.swift
git commit -m "feat: add AgentSource.all case and AgentUsageSummary.merge()"
```

---

### Task 2: Fix source picker hit area

**Files:**
- Modify: `pulse/Views/AgentSourcePicker.swift`

- [ ] **Step 1: Add `.contentShape(Rectangle())` to button labels**

Replace the `body` property of `AgentSourcePicker`:

```swift
var body: some View {
    HStack(spacing: 0) {
        ForEach(availableSources) { source in
            Button {
                onSelect(source)
            } label: {
                Text(source.displayName)
                    .font(.system(size: 12, weight: source == selectedSource ? .semibold : .medium))
                    .foregroundColor(source == selectedSource ? .appPrimaryText : .appSecondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(source == selectedSource ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    .clipShape(Capsule())
    .overlay(
        Capsule()
            .stroke(Color.appFieldBorder, lineWidth: 1)
    )
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -10
```

Expected: Same compilation errors as before (from switch exhaustiveness in other files).

- [ ] **Step 3: Commit**

```bash
git add pulse/Views/AgentSourcePicker.swift
git commit -m "fix: make entire capsule segment tappable in AgentSourcePicker"
```

---

### Task 3: Update `AgentUsageStore` for `.all` source

**Files:**
- Modify: `pulse/Managers/AgentUsageStore.swift`

- [ ] **Step 1: Update `availableSources` to include `.all` when 2+ real sources exist**

In `init()`, replace lines 43-50:

```swift
var sources: [AgentSource] = []
var realSources: [AgentSource] = []
if FileManager.default.fileExists(atPath: openCodeURL.path) {
    realSources.append(.openCode)
}
if let codexURL, FileManager.default.fileExists(atPath: codexURL.path) {
    realSources.append(.codex)
}
if realSources.isEmpty {
    realSources = [.openCode, .codex]
}
if realSources.count >= 2 {
    sources = [.all] + realSources
} else {
    sources = realSources
}
self.availableSources = sources

if realSources == [.codex] {
    selectedSource = .codex
} else if realSources.count >= 2 {
    selectedSource = .all
}
```

- [ ] **Step 2: Update `refresh()` to handle `.all`**

In `refresh()`, add a `.all` case before the existing cases. When `.all` is selected, call `refreshAll()`:

```swift
func refresh() {
    switch selectedSource {
    case .all:
        refreshAll()
    case .openCode:
        let firstLoad = openCodeHasLoaded == false
        if firstLoad { isLoading = true } else { isRefreshing = true }

        do {
            openCodeSnapshot = try OpenCodeUsageQuery.loadSnapshot(databaseURL: openCodeDatabaseURL)
            lastError = nil
        } catch let error as OpenCodeUsageQuery.QueryError {
            lastError = .openCode(error)
        } catch {
            lastError = .openCode(.queryStepFailed(message: error.localizedDescription))
        }

        openCodeHasLoaded = true
        isLoading = false
        isRefreshing = false

    case .codex:
        guard let codexDatabaseURL else {
            lastError = .codex(.databaseNotFound(path: "Codex database not found"))
            return
        }

        let firstLoad = codexHasLoaded == false
        if firstLoad { isLoading = true } else { isRefreshing = true }

        do {
            codexSnapshot = try CodexUsageQuery.loadSnapshot(databaseURL: codexDatabaseURL)
            lastError = nil
        } catch let error as CodexUsageQuery.QueryError {
            lastError = .codex(error)
        } catch {
            lastError = .codex(.queryStepFailed(message: error.localizedDescription))
        }

        codexHasLoaded = true
        isLoading = false
        isRefreshing = false
    }
}
```

- [ ] **Step 3: Update `refreshIfNeeded()` to handle `.all`**

Replace the `refreshIfNeeded()` method:

```swift
func refreshIfNeeded() {
    switch selectedSource {
    case .all where !openCodeHasLoaded || !codexHasLoaded:
        refreshAll()
    case .openCode where !openCodeHasLoaded:
        refresh()
    case .codex where !codexHasLoaded:
        refresh()
    default:
        break
    }
}
```

- [ ] **Step 4: Update `refreshAll()` loading state to also handle `.all` selected source**

In `refreshAll()`, update the loading/refreshing state checks to include `.all`:

Change line 111:
```swift
if firstLoad && (selectedSource == .openCode || selectedSource == .all) { isLoading = true }
else if selectedSource == .openCode || selectedSource == .all { isRefreshing = true }
```

Change line 116:
```swift
if selectedSource == .openCode || selectedSource == .all { lastError = nil }
```

Change lines 118, 120:
```swift
if selectedSource == .openCode || selectedSource == .all { lastError = .openCode(error) }
// ...
if selectedSource == .openCode || selectedSource == .all { lastError = .openCode(.queryStepFailed(message: error.localizedDescription)) }
```

Change line 128:
```swift
if firstLoad && selectedSource == .codex { isLoading = true }
else if selectedSource == .codex { isRefreshing = true }
```

Change line 133:
```swift
if selectedSource == .codex { lastError = nil }
```

Change lines 135, 137 (unchanged — codex-specific errors only show for .codex):
```swift
if selectedSource == .codex { lastError = .codex(error) }
// ...
if selectedSource == .codex { lastError = .codex(.queryStepFailed(message: error.localizedDescription)) }
```

- [ ] **Step 5: Update `databasePath` to handle `.all`**

Replace the `databasePath` computed property:

```swift
var databasePath: String {
    switch selectedSource {
    case .all:
        let paths = [openCodeDatabaseURL.path, codexDatabaseURL?.path].compactMap { $0 }
        return paths.joined(separator: " + ")
    case .openCode:
        return openCodeDatabaseURL.path
    case .codex:
        return codexDatabaseURL?.path ?? "Codex database not found"
    }
}
```

- [ ] **Step 6: Build to verify**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -10
```

Expected: Compilation errors only in `AgentUsageView` (switch exhaustiveness). We'll fix that in Task 4.

- [ ] **Step 7: Commit**

```bash
git add pulse/Managers/AgentUsageStore.swift
git commit -m "feat: update AgentUsageStore to handle .all source"
```

---

### Task 4: Update `AgentUsageView` for `.all` source

**Files:**
- Modify: `pulse/Views/AgentUsageView.swift`

- [ ] **Step 1: Update `selectedSource` fallback default**

Change line 12 from:
```swift
AgentSource(rawValue: selectedSourceRawValue) ?? .openCode
```
to:
```swift
AgentSource(rawValue: selectedSourceRawValue) ?? .all
```

- [ ] **Step 2: Add `combinedFilteredSnapshot` computed property and update `summary`**

After `codexFilteredSnapshot` (line 47), add:

```swift
private var combinedFilteredSnapshot: (openCode: OpenCodeUsageSnapshot, codex: CodexUsageSnapshot) {
    (openCodeFilteredSnapshot, codexFilteredSnapshot)
}
```

Replace the `summary` computed property (lines 49-54):

```swift
private var summary: AgentUsageSummary {
    switch selectedSource {
    case .all:
        let oc = openCodeFilteredSnapshot.summary(for: scope)
        let cx = codexFilteredSnapshot.summary(for: scope)
        return AgentUsageSummary.merge(oc, cx)
    case .openCode:
        return openCodeFilteredSnapshot.summary(for: scope)
    case .codex:
        return codexFilteredSnapshot.summary(for: scope)
    }
}
```

- [ ] **Step 3: Update `projectOptions` to handle `.all`**

Replace the `projectOptions` computed property (lines 56-75):

```swift
private var projectOptions: [SearchableSelectorOption] {
    switch selectedSource {
    case .all:
        let ocProjects = Dictionary(grouping: openCodeFilteredSnapshot.sessions, by: \.directory)
        let cxProjects = Dictionary(grouping: codexFilteredSnapshot.sessions.filter { $0.isSubagent == false }, by: \.cwd)
        let allDirs = Set(ocProjects.keys).union(cxProjects.keys)
        return allDirs.map { dir -> SearchableSelectorOption in
            let ocSessions = ocProjects[dir] ?? []
            let cxSessions = cxProjects[dir] ?? []
            let totalTokens = ocSessions.reduce(0) { $0 + $1.totalTokens } + cxSessions.reduce(0) { $0 + $1.tokensUsed }
            let sessionsCount = ocSessions.count + cxSessions.count
            return SearchableSelectorOption(
                id: dir,
                title: URL(fileURLWithPath: dir).lastPathComponent,
                subtitle: "\(compact(totalTokens)) total tokens \u{2022} \(sessionsCount) sessions \u{2022} \(dir)"
            )
        }
        .sorted { lhs, rhs in
            let lhsTokens = totalTokensForAllProject(lhs.id)
            let rhsTokens = totalTokensForAllProject(rhs.id)
            if lhsTokens == rhsTokens { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
            return lhsTokens > rhsTokens
        }
    case .openCode:
        return openCodeFilteredSnapshot.projectOptions.map {
            SearchableSelectorOption(
                id: $0.directory,
                title: $0.shortName,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
            )
        }
    case .codex:
        return codexFilteredSnapshot.projectOptions.map {
            SearchableSelectorOption(
                id: $0.directory,
                title: $0.shortName,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \($0.summary.sessionsCount) sessions \u{2022} \($0.directory)"
            )
        }
    }
}
```

Add the helper after `projectOptions`:

```swift
private func totalTokensForAllProject(_ dir: String) -> Int {
    let ocTokens = openCodeFilteredSnapshot.sessions.filter { $0.directory == dir }.reduce(0) { $0 + $1.totalTokens }
    let cxTokens = codexFilteredSnapshot.sessions.filter { $0.cwd == dir && $0.isSubagent == false }.reduce(0) { $0 + $1.tokensUsed }
    return ocTokens + cxTokens
}
```

- [ ] **Step 4: Update `sessionOptions` to handle `.all` (return empty)**

In the `sessionOptions` computed property, add a `.all` case at the top of the switch:

```swift
private var sessionOptions: [SearchableSelectorOption] {
    switch selectedSource {
    case .all:
        return []
    case .openCode:
        guard let selectedProjectDirectoryValue else { return [] }
        return openCodeFilteredSnapshot.sessionOptions(for: selectedProjectDirectory).map {
            SearchableSelectorOption(
                id: $0.id,
                title: $0.title,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime($0.updatedAt)) \u{2022} \($0.modelDisplayName)"
            )
        }
    case .codex:
        guard let selectedProjectDirectoryValue else { return [] }
        return codexFilteredSnapshot.sessionOptions(for: selectedProjectDirectory).map {
            let effort = $0.reasoningEffort.isEmpty ? "" : " \u{2022} \($0.reasoningEffort)"
            return SearchableSelectorOption(
                id: $0.id,
                title: $0.title,
                subtitle: "\(compact($0.summary.totalTokens)) total tokens \u{2022} \(shortDateTime($0.updatedAt)) \u{2022} \($0.modelDisplayName)\(effort)"
            )
        }
    }
}
```

- [ ] **Step 5: Update `selectedOpenCodeSession` and `selectedCodexSession` for `.all`**

These already guard against `selectedSource != .openCode` / `!= .codex` so no changes needed — they return `nil` for `.all`.

- [ ] **Step 6: Update `body` to conditionally hide sections for `.all`**

Replace the `body` property (lines 111-165):

```swift
var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
            header

            if agentStore.isLoading {
                ProgressView("Loading \(selectedSource.displayName) usage...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else if let error = agentStore.lastError {
                errorState(error)
            } else {
                timeRangeSelector
                selectorsBlock
                detailBlock

                if selectedSource != .all && isSessionScope == false {
                    byModelBlock
                }

                if selectedSource == .codex && isSessionScope {
                    CodexSessionDetailView()
                }
            }
        }
        .padding(16)
    }
    .onAppear {
        agentStore.selectedSource = selectedSource
        agentStore.refreshIfNeeded()
    }
    .onChange(of: agentStore.openCodeSnapshot) { _ in
        if selectedSource == .openCode || selectedSource == .all { reconcileSelection() }
    }
    .onChange(of: agentStore.codexSnapshot) { _ in
        if selectedSource == .codex || selectedSource == .all { reconcileSelection() }
    }
    .onChange(of: selectedTimeRangeRawValue) { _ in
        reconcileSelection()
    }
    .onChange(of: selectedSourceRawValue) { newValue in
        if let source = AgentSource(rawValue: newValue) {
            agentStore.selectedSource = source
            agentStore.refreshIfNeeded()
        }
        reconcileSelection()
    }
    .onChange(of: selectedSessionID) { _ in
        if selectedSource == .codex, selectedSessionID.isEmpty == false {
            agentStore.loadCodexDetail(for: selectedSessionID)
        } else {
            agentStore.clearCodexDetail()
        }
    }
}
```

- [ ] **Step 7: Update `detailBlock` to hide Context section for `.all`**

Replace the `detailBlock` computed property:

```swift
private var detailBlock: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("Usage")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricCard(title: "Total", value: compact(summary.totalTokens))

            if let input = summary.inputTokens {
                metricCard(title: "Input", value: compact(input))
            }
            if let output = summary.outputTokens {
                metricCard(title: "Output", value: compact(output))
            }
            if let cacheRead = summary.cacheReadTokens {
                metricCard(title: "Cache Read", value: compact(cacheRead))
            }
        }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let reasoning = summary.reasoningTokens {
                    summaryPill(title: "Reasoning", value: compact(reasoning))
                }
                if let cacheWrite = summary.cacheWriteTokens {
                    summaryPill(title: "Cache Write", value: compact(cacheWrite))
                }
                summaryPill(title: "Sessions", value: "\(summary.sessionsCount)")
                summaryPill(title: "Last Updated", value: summary.lastUpdated.map(shortDateTime) ?? "-")
                if let cost = summary.cost, cost > 0 {
                    summaryPill(title: "Cost", value: String(format: "$%.2f", cost))
                }
            }
        }

        if selectedSource != .all {
            Divider()
                .background(Color.appDivider)

            Text("Context")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            switch selectedSource {
            case .all:
                EmptyView()
            case .openCode:
                openCodeContextRows
            case .codex:
                codexContextRows
            }
        }
    }
    .padding(12)
    .background(Color.appFieldBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}
```

Note: The `switch` still needs `.all` for exhaustiveness, but `EmptyView()` will never execute because the `if selectedSource != .all` guard prevents it.

- [ ] **Step 8: Update `selectorsBlock` to hide session selector for `.all`**

Replace the `selectorsBlock` computed property:

```swift
private var selectorsBlock: some View {
    VStack(spacing: 12) {
        SearchableSelectorView(
            label: "Project",
            placeholder: "All Projects",
            selectedTitle: selectedProjectDirectoryValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All Projects",
            options: [
                SearchableSelectorOption(
                    id: "__all__",
                    title: "All Projects",
                    subtitle: "Show all \(selectedSource.displayName) sessions"
                )
            ] + projectOptions
        ) { option in
            if option.id == "__all__" {
                selectedProjectDirectory = ""
                selectedSessionID = ""
            } else {
                selectedProjectDirectory = option.id
                selectedSessionID = ""
            }
        }

        if selectedSource != .all && selectedProjectDirectoryValue != nil {
            SearchableSelectorView(
                label: "Session",
                placeholder: "All Sessions",
                selectedTitle: sessionOptions.first(where: { $0.id == selectedSessionIDValue })?.title ?? "All Sessions",
                options: [
                    SearchableSelectorOption(
                        id: "__all__",
                        title: "All Sessions",
                        subtitle: "Show the full project summary"
                    )
                ] + sessionOptions
            ) { option in
                selectedSessionID = option.id == "__all__" ? "" : option.id
            }
        }
    }
}
```

- [ ] **Step 9: Update `byModelBlock` to handle `.all`**

Add a `.all` case to the switch in `byModelBlock`:

```swift
private var byModelBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
        Text("By Model")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.appPrimaryText)

        switch selectedSource {
        case .all:
            EmptyView()
        case .openCode:
            let breakdown = openCodeFilteredSnapshot.modelBreakdown(for: scope)
            if breakdown.isEmpty {
                Text("No model usage data for this scope.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            } else {
                ForEach(breakdown) { model in
                    detailRow(
                        title: OpenCodeUsageSnapshot.modelDisplayName(
                            providerID: model.providerID,
                            modelID: model.modelID,
                            variant: model.variant
                        ),
                        value: compact(model.summary.totalTokens)
                    )
                }
            }
        case .codex:
            let breakdown = codexFilteredSnapshot.modelBreakdown(for: scope)
            if breakdown.isEmpty {
                Text("No model usage data for this scope.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            } else {
                ForEach(breakdown) { model in
                    detailRow(
                        title: "\(model.modelProvider) / \(model.model)",
                        value: compact(model.summary.totalTokens)
                    )
                }
            }
        }
    }
    .padding(12)
    .background(Color.appFieldBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}
```

Note: The `EmptyView()` for `.all` is unreachable because `byModelBlock` is only shown when `selectedSource != .all`.

- [ ] **Step 10: Update `reconcileSelection` to handle `.all`**

Replace the `reconcileSelection` method:

```swift
private func reconcileSelection() {
    let currentProjectOptions: [String]
    switch selectedSource {
    case .all:
        let ocDirs = Set(openCodeFilteredSnapshot.projectOptions.map(\.directory))
        let cxDirs = Set(codexFilteredSnapshot.projectOptions.map(\.directory))
        currentProjectOptions = Array(ocDirs.union(cxDirs))
    case .openCode:
        currentProjectOptions = openCodeFilteredSnapshot.projectOptions.map(\.directory)
    case .codex:
        currentProjectOptions = codexFilteredSnapshot.projectOptions.map(\.directory)
    }

    if let selectedProjectDirectoryValue,
       currentProjectOptions.contains(selectedProjectDirectory) == false {
        selectedProjectDirectory = ""
        selectedSessionID = ""
        return
    }

    if selectedSource != .all, let selectedProjectDirectoryValue, let selectedSessionIDValue {
        let validSessionIDs = Set(sessionOptions.map(\.id))
        if validSessionIDs.contains(selectedSessionID) == false {
            selectedProjectDirectory = selectedProjectDirectoryValue
            selectedSessionID = ""
        }
    }
}
```

- [ ] **Step 11: Build and verify**

```bash
xcodebuild -project pulse.xcodeproj -scheme pulse -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -10
```

Expected: BUILD SUCCEEDED

- [ ] **Step 12: Commit**

```bash
git add pulse/Views/AgentUsageView.swift
git commit -m "feat: add All-source combined summary with project selector and date range"
```

---

### Task 5: Bump version

**Files:**
- Modify: `pulse.xcodeproj/project.pbxproj`

- [ ] **Step 1: Bump MARKETING_VERSION**

Current version is 1.5.0. Bump to 1.5.1 (this is additive UI, not a new major feature — patch is appropriate given 1.5.0 was just cut for the Codex source work).

```bash
sed -i '' 's/MARKETING_VERSION = .*/MARKETING_VERSION = 1.5.1;/' pulse.xcodeproj/project.pbxproj
```

- [ ] **Step 2: Verify**

```bash
grep -m1 'MARKETING_VERSION' pulse.xcodeproj/project.pbxproj
```

Expected: `MARKETING_VERSION = 1.5.1;`

- [ ] **Step 3: Commit**

```bash
git add pulse.xcodeproj/project.pbxproj
git commit -m "chore: bump version to 1.5.1"
```

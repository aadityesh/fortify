import SwiftUI

struct AppListView: View {
    @Environment(AppState.self) private var state

    private enum Filter: String, CaseIterable {
        case all = "All apps"
        case locked = "Protected"
    }

    @State private var query = ""
    @State private var filter = Filter.all
    @State private var confirmBulk = false
    @FocusState private var searchFocused: Bool

    /// Installed apps that are protected. Read once per use, not per row.
    private var protectedCount: Int {
        state.catalog.apps.reduce(0) { $0 + (state.store.isLocked($1.id) ? 1 : 0) }
    }

    /// Filters every installed app, so each view reads it once into a `let`.
    private var visibleApps: [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return state.catalog.apps.filter { app in
            (filter == .all || state.store.isLocked(app.id))
                && (trimmed.isEmpty || app.name.localizedCaseInsensitiveContains(trimmed))
        }
    }

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 0) {
            topBar
            protectionSummary
                .padding(.top, 26)
            appHeading
                .padding(.top, 28)
            controls
                .padding(.top, 14)
            list
                .padding(.top, 12)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .sheet(isPresented: $state.showSettings) {
            SettingsView().environment(state)
        }
        .onChange(of: state.searchFocusToken) { searchFocused = true }
        // Apps installed since the last scan show up when the list does.
        .task { state.catalog.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.catalog.reload()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            Text(AppInfo.name)
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            ThemeToggle()
            IconButton(systemName: "gearshape", help: "Open Settings (⌘,)") {
                state.showSettings = true
            }
        }
    }

    private var protectionSummary: some View {
        let protectedCount = protectedCount
        return HStack(spacing: 16) {
            Image(systemName: protectedCount > 0 ? "lock.shield.fill" : "lock.shield")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(protectedCount > 0 ? Palette.positiveText : Palette.textSecondary)
                .frame(width: 48, height: 48)
                .background(protectedCount > 0 ? Palette.positiveFill : Palette.surfaceMuted,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(protectedCount > 0 ? "Protection is on" : "Choose an app to protect")
                    .font(.system(size: 16, weight: .semibold))
                Text(summaryDetail(protected: protectedCount))
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(protectedCount == 1 ? "1 app protected" : "\(protectedCount) apps protected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(protectedCount > 0 ? Palette.positiveText : Palette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(protectedCount > 0 ? Palette.positiveFill : Palette.surfaceMuted, in: Capsule())
                .accessibilityLabel("\(protectedCount) apps protected")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }

    private func summaryDetail(protected protectedCount: Int) -> String {
        if protectedCount == 0 { return "Turn on an app below to require Touch ID or your PIN." }
        return "Protected apps ask for Touch ID or your PIN when they open."
    }

    private var appHeading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your apps")
                    .font(.system(size: 23, weight: .semibold))
                Text("Choose which apps ask before opening.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        let targets = bulkTargets
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textSecondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false }
                    .accessibilityLabel("Search installed apps")
                if query.isEmpty {
                    Keycap(text: "/")
                        .accessibilityHidden(true)
                } else {
                    Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .card(radius: 10)
            .frame(maxWidth: 360)

            Spacer(minLength: 4)

            Button(filter == .locked ? "Unlock All" : "Lock All") { confirmBulk = true }
                .buttonStyle(OutlineButtonStyle())
                .font(Typo.bodyMedium)
                .disabled(targets.isEmpty)
                .confirmationDialog(bulkTitle(count: targets.count), isPresented: $confirmBulk) {
                    Button(filter == .locked ? "Unlock All" : "Lock All", role: filter == .locked ? .destructive : nil) {
                        applyBulk(targets.map(\.id))
                    }
                } message: {
                    Text(filter == .locked
                         ? "These apps will open without Touch ID or your PIN."
                         : "These apps will ask for Touch ID or your PIN when they open.")
                }

            SegmentedPills(options: Filter.allCases, selection: $filter, title: \.rawValue)
        }
    }

    /// Bulk actions apply only to the rows currently shown by the filter and search.
    private var bulkTargets: [InstalledApp] {
        visibleApps.filter { state.store.isLocked($0.id) == (filter == .locked) }
    }

    private func bulkTitle(count: Int) -> String {
        let apps = count == 1 ? "1 app" : "\(count) apps"
        return filter == .locked ? "Unlock \(apps)?" : "Lock \(apps)?"
    }

    private func applyBulk(_ ids: [String]) {
        if filter == .locked {
            ids.forEach { state.store.setLocked($0, false) }
        } else {
            state.lockAll(ids)
        }
    }

    private var list: some View {
        let apps = visibleApps
        return Group {
            if state.catalog.isLoading && state.catalog.apps.isEmpty {
                ProgressView("Finding your apps…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: query.isEmpty ? "app.dashed" : "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.bottom, 3)
                        .accessibilityHidden(true)
                    Text(emptyTitle).font(Typo.bodyMedium)
                    Text(emptySubtitle)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let lastID = apps.last?.id
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            AppRow(app: app)
                            if app.id != lastID {
                                Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 62)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
        // The filter pill slides; the rows switch in place (a live list doesn't animate).
        .animation(nil, value: filter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "No apps match “\(query)”" }
        return filter == .locked ? "No protected apps yet" : "No apps found"
    }

    private var emptySubtitle: String {
        filter == .locked && query.isEmpty
            ? "Choose All apps, then turn on protection for an app."
            : "Try a different search."
    }
}

private struct AppRow: View {
    @Environment(AppState.self) private var state
    let app: InstalledApp
    @State private var hovering = false

    var body: some View {
        let isLocked = Binding(
            get: { state.store.isLocked(app.id) },
            set: { state.setLocked(app.id, $0) }
        )
        let isProtected = isLocked.wrappedValue

        HStack(spacing: 13) {
            Image(nsImage: state.catalog.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(Typo.bodyMedium)
                    .lineLimit(1)
                Text(isProtected ? "Protected" : "Not protected")
                    .font(Typo.caption)
                    .foregroundStyle(isProtected ? Palette.positiveText : Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Toggle("Require authentication for \(app.name)", isOn: isLocked)
                .labelsHidden()
                .toggleStyle(GreenToggleStyle())
                .accessibilityHint("Requires Touch ID or your PIN when the app opens")
                .help(isLocked.wrappedValue ? "Stop protecting \(app.name)" : "Protect \(app.name)")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .background(hovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        // The row highlights on hover, so a click anywhere on it flips the switch.
        .onTapGesture { isLocked.wrappedValue.toggle() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isLocked.wrappedValue ? "Stop Protecting \(app.name)" : "Protect \(app.name)") {
                isLocked.wrappedValue.toggle()
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }
        .animation(.easeOut(duration: 0.15), value: isLocked.wrappedValue)
    }
}

/// A compact segmented selector used for app filters and PIN length.
struct SegmentedPills<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Namespace private var namespace

    init(options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Palette.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview("App list · Light") {
    AppListView().environment(AppState.preview(.unlocked))
        .frame(width: 760, height: 680).background(Palette.background).preferredColorScheme(.light)
}

#Preview("App list · Dark") {
    AppListView().environment(AppState.preview(.unlocked))
        .frame(width: 760, height: 680).background(Palette.background).preferredColorScheme(.dark)
}

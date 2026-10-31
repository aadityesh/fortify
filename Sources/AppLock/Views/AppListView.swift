import SwiftUI

/// How the app list shows apps; chosen in the list's header and remembered.
enum AppListLayout: String, CaseIterable {
    case list, cards, grid

    var title: String {
        switch self {
        case .list: "List"
        case .cards: "Cards"
        case .grid: "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .cards: "rectangle.grid.2x2"
        case .grid: "square.grid.3x3"
        }
    }
}

struct AppListView: View {
    @Environment(AppState.self) private var state

    private enum Filter: String, CaseIterable {
        case all = "All apps"
        case locked = "Protected"
    }

    @State private var query = ""
    @State private var filter = Filter.all
    @State private var confirmBulk = false
    @State private var collapsed: Set<AppCategory> = []
    @FocusState private var searchFocused: Bool

    /// One category's apps, or every app when the list isn't grouped.
    private struct AppSection: Identifiable {
        let category: AppCategory?
        let apps: [InstalledApp]
        var id: String { category?.rawValue ?? "all" }
    }

    /// Installed apps that are protected. Read once per use, not per row.
    private var protectedCount: Int {
        state.catalog.apps.reduce(0) { $0 + (state.store.isLocked($1.id) ? 1 : 0) }
    }

    /// Filters every installed app, so each view reads it once into a `let`.
    private var visibleApps: [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return state.catalog.apps.filter { app in
            (filter == .all || state.store.isLocked(app.id))
                && (trimmed.isEmpty || app.name.localizedCaseInsensitiveContains(trimmed)
                    || state.category(of: app).title.localizedCaseInsensitiveContains(trimmed))
        }
    }

    /// Categories in a fixed order (Other last), skipping empty ones.
    private func sections(_ apps: [InstalledApp]) -> [AppSection] {
        guard state.groupByCategory else { return [AppSection(category: nil, apps: apps)] }
        let grouped = Dictionary(grouping: apps) { state.category(of: $0) }
        return AppCategory.allCases.compactMap { category in
            grouped[category].map { AppSection(category: category, apps: $0) }
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
            Text(state.userName.isEmpty ? AppInfo.name : state.greeting)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
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
        @Bindable var state = state
        return HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your apps")
                    .font(.system(size: 23, weight: .semibold))
                Text(state.groupByCategory
                     ? "Choose which apps ask before opening. Right-click an app to move it."
                     : "Choose which apps ask before opening.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            ToggleChip(title: "Categories", systemImage: "square.stack.3d.up", isOn: $state.groupByCategory)
                .help(state.groupByCategory ? "Show apps in one list" : "Group apps by category")
            SegmentedPills(options: AppListLayout.allCases, selection: $state.appListLayout,
                           title: \.title, symbol: \.symbol)
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(sections(apps)) { section in
                            Section {
                                if !(section.category.map(collapsed.contains) ?? false) {
                                    sectionContent(section.apps)
                                }
                            } header: {
                                if let category = section.category {
                                    CategoryHeader(
                                        category: category,
                                        count: section.apps.count,
                                        collapsed: collapsed.contains(category),
                                        inList: isList
                                    ) {
                                        if collapsed.remove(category) == nil { collapsed.insert(category) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, isList ? 4 : 0)
                }
                .scrollIndicators(.automatic)
            }
        }
        // The filter pill slides; the rows switch in place (a live list doesn't animate).
        .animation(nil, value: filter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rows sit in one card; cards and tiles sit straight on the window.
        .modifier(ListContainer(enabled: isList))
    }

    private var isList: Bool { state.appListLayout == .list }

    @ViewBuilder
    private func sectionContent(_ apps: [InstalledApp]) -> some View {
        switch state.appListLayout {
        case .list:
            let lastID = apps.last?.id
            ForEach(apps) { app in
                AppRow(app: app)
                if app.id != lastID {
                    Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 62)
                }
            }
        case .cards:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(apps) { AppCard(app: $0) }
            }
            .padding(.bottom, 16)
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(apps) { AppTile(app: $0) }
            }
            .padding(.bottom, 16)
        }
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
        .modifier(AppActions(app: app))
        .animation(.easeOut(duration: 0.15), value: isLocked.wrappedValue)
    }
}

/// Cards layout: icon and switch on top, name and state underneath.
private struct AppCard: View {
    @Environment(AppState.self) private var state
    let app: InstalledApp
    @State private var hovering = false

    var body: some View {
        let isLocked = Binding(
            get: { state.store.isLocked(app.id) },
            set: { state.setLocked(app.id, $0) }
        )
        let isProtected = isLocked.wrappedValue
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(nsImage: state.catalog.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Toggle("Require authentication for \(app.name)", isOn: isLocked)
                    .labelsHidden()
                    .toggleStyle(GreenToggleStyle())
                    .help(isProtected ? "Stop protecting \(app.name)" : "Protect \(app.name)")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(Typo.bodyMedium)
                    .lineLimit(1)
                Text(state.groupByCategory
                     ? (isProtected ? "Protected" : "Not protected")
                     : "\(isProtected ? "Protected" : "Not protected") · \(state.category(of: app).title)")
                    .font(Typo.caption)
                    .foregroundStyle(isProtected ? Palette.positiveText : Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Palette.hover : Palette.surface, in: shape)
        .overlay(shape.strokeBorder(isProtected ? Palette.positiveText.opacity(0.35) : Palette.border))
        .contentShape(shape)
        .onTapGesture { isLocked.wrappedValue.toggle() }
        .onHover { hovering = $0 }
        .modifier(AppActions(app: app))
        .animation(.easeOut(duration: 0.15), value: isProtected)
    }
}

/// Grid layout: just the icon and name; a click protects or unprotects.
private struct AppTile: View {
    @Environment(AppState.self) private var state
    let app: InstalledApp
    @State private var hovering = false

    var body: some View {
        let isProtected = state.store.isLocked(app.id)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(spacing: 8) {
            Image(nsImage: state.catalog.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
                .overlay(alignment: .bottomTrailing) {
                    if isProtected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 20, height: 20)
                            .background(Palette.accent, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.background, lineWidth: 2))
                            .offset(x: 4, y: 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            Text(app.name)
                .font(Typo.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 30, alignment: .top)
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(isProtected ? Palette.positiveFill : (hovering ? Palette.surface : .clear), in: shape)
        .contentShape(shape)
        .onTapGesture { state.setLocked(app.id, !isProtected) }
        .onHover { hovering = $0 }
        .help(isProtected ? "Stop protecting \(app.name)" : "Protect \(app.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(isProtected ? "Protected" : "Not protected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.setLocked(app.id, !isProtected) }
        .modifier(AppActions(app: app))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isProtected)
    }
}

/// Right-click menu shared by rows, cards and tiles.
private struct AppActions: ViewModifier {
    @Environment(AppState.self) private var state
    let app: InstalledApp

    func body(content: Content) -> some View {
        content.contextMenu {
            let isProtected = state.store.isLocked(app.id)
            Button(isProtected ? "Stop Protecting \(app.name)" : "Protect \(app.name)") {
                state.setLocked(app.id, !isProtected)
            }
            Divider()
            Picker("Move to Category", selection: Binding(
                get: { state.category(of: app) },
                set: { state.setCategory($0, for: app) }
            )) {
                ForEach(AppCategory.allCases, id: \.self) { category in
                    Label(category.title, systemImage: category.symbol).tag(category)
                }
            }
            .pickerStyle(.menu)
            if state.isCategoryOverridden(app) {
                Button("Move Back to \(app.automaticCategory.title)") {
                    state.setCategory(app.automaticCategory, for: app)
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }
    }
}

/// A category's heading; click to fold the category away.
private struct CategoryHeader: View {
    let category: AppCategory
    let count: Int
    let collapsed: Bool
    /// In the list's card the header sits on the card's surface with a rule
    /// under it; in the cards and grid layouts, on the window background.
    let inList: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                Image(systemName: category.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("\(count)")
                    .font(Typo.caption)
                Spacer()
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, inList ? 15 : 4)
            .padding(.top, inList ? 10 : 6)
            .padding(.bottom, inList ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(inList ? Palette.surface : Palette.background)
            .overlay(alignment: .bottom) {
                if inList { Rectangle().fill(Palette.border).frame(height: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: collapsed)
        .accessibilityLabel("\(category.title), \(count) apps")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The list layout keeps its rows in one card.
private struct ListContainer: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .card()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            content
        }
    }
}

/// An on/off chip that matches `SegmentedPills`.
private struct ToggleChip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn ? Palette.surface : .clear)
                        .shadow(color: .black.opacity(isOn ? 0.08 : 0), radius: 2, y: 1)
                }
                .padding(3)
                .background(Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A compact segmented selector used for app filters, the list layout and PIN
/// length. With `symbol`, each option shows as an icon (its title is the tooltip).
struct SegmentedPills<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var symbol: ((Option) -> String)?
    @Namespace private var namespace

    init(options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String,
         symbol: ((Option) -> String)? = nil) {
        self.options = options
        self._selection = selection
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option }
                } label: {
                    Group {
                        if let symbol {
                            Image(systemName: symbol(option))
                                .frame(width: 16)
                                .accessibilityLabel(title(option))
                        } else {
                            Text(title(option))
                        }
                    }
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
                .help(symbol == nil ? "" : title(option))
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

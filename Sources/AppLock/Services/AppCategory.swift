import Foundation

/// The groups the app list sorts apps into. Each app starts in the category it
/// declares in its Info.plist (`LSApplicationCategoryType`, its App Store
/// category), with browsers, web apps and a few apps that declare nothing
/// filled in. The user can move any app to another category.
enum AppCategory: String, CaseIterable, Sendable {
    case browsers, webApps, social, productivity, business, developer, finance,
         entertainment, music, video, games, creative, reading, education,
         lifestyle, utilities, other

    var title: String {
        switch self {
        case .browsers: "Browsers"
        case .webApps: "Web Apps"
        case .social: "Social & Messaging"
        case .productivity: "Productivity"
        case .business: "Business"
        case .developer: "Developer Tools"
        case .finance: "Finance"
        case .entertainment: "Entertainment"
        case .music: "Music & Audio"
        case .video: "Video"
        case .games: "Games"
        case .creative: "Photo & Design"
        case .reading: "Reading & News"
        case .education: "Education"
        case .lifestyle: "Health & Lifestyle"
        case .utilities: "Utilities"
        case .other: "Other"
        }
    }

    /// SF Symbol shown next to the title.
    var symbol: String {
        switch self {
        case .browsers: "globe"
        case .webApps: "macwindow.on.rectangle"
        case .social: "bubble.left.and.bubble.right"
        case .productivity: "checklist"
        case .business: "briefcase"
        case .developer: "hammer"
        case .finance: "creditcard"
        case .entertainment: "popcorn"
        case .music: "music.note"
        case .video: "play.rectangle"
        case .games: "gamecontroller"
        case .creative: "paintpalette"
        case .reading: "book"
        case .education: "graduationcap"
        case .lifestyle: "heart"
        case .utilities: "wrench.and.screwdriver"
        case .other: "square.dashed"
        }
    }

    static func automatic(bundleID: String, declaredType: String?, isWebApp: Bool = false) -> AppCategory {
        if isWebApp { return .webApps }
        if let known = knownApps[bundleID] { return known }
        let prefix = "public.app-category."
        guard let declared = declaredType?.lowercased(), declared.hasPrefix(prefix) else { return .other }
        let name = String(declared.dropFirst(prefix.count))
        // board-games, puzzle-games, … all count as games.
        if name.hasSuffix("games") { return .games }
        return declaredTypes[name] ?? .other
    }

    private static let declaredTypes: [String: AppCategory] = [
        "social-networking": .social,
        "productivity": .productivity,
        "business": .business,
        "developer-tools": .developer,
        "finance": .finance,
        "entertainment": .entertainment,
        "music": .music,
        "video": .video,
        "graphics-design": .creative,
        "photography": .creative,
        "books": .reading,
        "news": .reading,
        "reference": .reading,
        "magazines-and-newspapers": .reading,
        "education": .education,
        "kids": .education,
        "healthcare-fitness": .lifestyle,
        "medical": .lifestyle,
        "lifestyle": .lifestyle,
        "sports": .lifestyle,
        "food-and-drink": .lifestyle,
        "travel": .lifestyle,
        "navigation": .lifestyle,
        "weather": .utilities,
        "utilities": .utilities,
    ]

    /// Apps whose declared category is missing or misleading for this list,
    /// e.g. browsers usually say Productivity or nothing at all.
    private static let knownApps: [String: AppCategory] = [
        "com.apple.Safari": .browsers,
        "com.google.Chrome": .browsers,
        "com.brave.Browser": .browsers,
        "com.microsoft.edgemac": .browsers,
        "org.mozilla.firefox": .browsers,
        "com.operasoftware.Opera": .browsers,
        "com.vivaldi.Vivaldi": .browsers,
        "company.thebrowser.Browser": .browsers,
        "app.zen-browser.zen": .browsers,
        "com.apple.mail": .social,
        "com.apple.mobilephone": .social,
        "com.tinyspeck.slackmacgap": .social,
        "ru.keepcoder.Telegram": .social,
        "com.hnc.Discord": .social,
        "us.zoom.xos": .social,
        "com.microsoft.teams2": .social,
        "com.apple.podcasts": .music,
        "com.apple.stocks": .finance,
        "com.apple.weather": .utilities,
        "com.apple.calculator": .utilities,
        "com.apple.clock": .utilities,
        "com.apple.findmy": .utilities,
        "com.apple.Home": .utilities,
        "com.apple.Passwords": .utilities,
        "com.apple.ScreenContinuity": .utilities,
    ]
}

/// "Good morning, Aadi". Without a name, a plain welcome.
enum Greeting {
    static func text(name: String, hour: Int) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Welcome back" }
        let part = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        return "\(part), \(name)"
    }
}

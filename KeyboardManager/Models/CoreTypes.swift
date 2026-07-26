import Foundation

enum InventoryItemKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case board
    case keycapSet
    case artisanSet
    case switchSet

    var id: Self { self }

    var displayName: String {
        displayName()
    }

    func displayName(language: String? = nil) -> String {
        switch self {
        case .board: L10n.text("Keyboards", language: language)
        case .keycapSet: L10n.text("Keycap-Sets", language: language)
        case .artisanSet: L10n.text("Artisans", language: language)
        case .switchSet: L10n.text("Switches", language: language)
        }
    }

    var singularName: String {
        switch self {
        case .board: L10n.text("Keyboard")
        case .keycapSet: L10n.text("Keycap-Set")
        case .artisanSet: L10n.text("Artisan")
        case .switchSet: L10n.text("Switch")
        }
    }

    var systemImage: String {
        switch self {
        case .board: "keyboard"
        case .keycapSet: "square.grid.3x3.fill"
        case .artisanSet: "sparkles"
        case .switchSet: "switch.2"
        }
    }
}

enum SwitchPins: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case three = "3"
    case five = "5"
    case hallEffect = "HE"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .three: "3 PIN"
        case .five: "5 PIN"
        case .hallEffect: "HE"
        }
    }
}

enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

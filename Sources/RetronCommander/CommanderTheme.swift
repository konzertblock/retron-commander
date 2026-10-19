import AppKit
import SwiftUI

enum RetronTheme: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case nortonCommander = "Norton Commander"

    var id: String { rawValue }
    var background: Color {
        self == .nortonCommander ? Color(red: 0, green: 0, blue: 168.0 / 255.0) : Color(nsColor: .windowBackgroundColor)
    }
    var foreground: Color { self == .nortonCommander ? Color(red: 87.0 / 255.0, green: 1, blue: 1) : Color(nsColor: .labelColor) }
    var selection: Color { self == .nortonCommander ? Color(red: 0, green: 168.0 / 255.0, blue: 168.0 / 255.0) : Color.accentColor.opacity(0.18) }
    var headerForeground: Color { self == .nortonCommander ? .yellow : foreground }
    var panelBorder: Color { self == .nortonCommander ? Color(red: 87.0 / 255.0, green: 1, blue: 1) : Color(nsColor: .separatorColor) }
    var promptBackground: Color { self == .nortonCommander ? .black : Color(nsColor: .textBackgroundColor) }
    var commandForeground: Color { self == .nortonCommander ? Color(red: 0.78, green: 0.78, blue: 0.78) : foreground }
    var toolbarBackground: Color { self == .nortonCommander ? selection : Color(nsColor: .controlBackgroundColor) }
    var font: Font { self == .nortonCommander ? .custom("Monaco", size: 14) : .system(size: 12) }
    var usesIcons: Bool { self != .nortonCommander }

    static var selected: RetronTheme {
        RetronTheme(rawValue: UserDefaults.standard.string(forKey: "retronTheme") ?? "") ?? .default
    }
}

enum FunctionKeyProfile: String, CaseIterable, Identifiable {
    case retron = "Retron"
    case norton = "Norton Commander"
    case mac = "Mac Standard"
    case compact = "Compact"
    var id: String { rawValue }
    var description: String {
        switch self {
        case .retron: "Original F1–F12 file-manager commands."
        case .norton: "Classic F1–F10 mapping: Help, User Menu, View, Edit, Copy, Move, MkDir, Delete, PullDn, Quit."
        case .mac: "Mac-friendly F1–F12 mapping with Help, Rename, Quick Look, Open, Copy and Move."
        case .compact: "Show the core F1–F8 actions for a less crowded footer."
        }
    }
}

import Foundation

enum FileAssociationIntent: String, Codable {
    case view
    case edit
}

struct FileAssociationRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var extensionName: String
    var viewerApplicationPath = ""
    var editorApplicationPath = ""

    func applicationPath(for intent: FileAssociationIntent) -> String? {
        let value = intent == .view ? viewerApplicationPath : editorApplicationPath
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : NSString(string: cleaned).expandingTildeInPath
    }
}

enum FileAssociationService {
    static let storageKey = "fileAssociations"

    static func load(defaults: UserDefaults = .standard) -> [FileAssociationRule] {
        guard let data = defaults.data(forKey: storageKey),
              let rules = try? JSONDecoder().decode([FileAssociationRule].self, from: data) else { return [] }
        return rules
    }

    static func save(_ rules: [FileAssociationRule], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func applicationPath(for file: URL, intent: FileAssociationIntent, rules: [FileAssociationRule]) -> String? {
        rules.first(where: { matches(file, mask: $0.extensionName) })?.applicationPath(for: intent)
    }

    static func normalizedExtension(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func matches(_ file: URL, mask: String) -> Bool {
        let groups = mask.components(separatedBy: "|")
        let included = splitMasks(groups.first ?? "")
        let excluded = groups.dropFirst().flatMap(splitMasks)
        guard !included.isEmpty, included.contains(where: { matches(file, pattern: $0) }),
              !excluded.contains(where: { matches(file, pattern: $0) }) else { return false }
        return true
    }

    private static func splitMasks(_ value: String) -> [String] {
        var masks: [String] = []
        var current = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            if characters[index] == ";" {
                if index + 1 < characters.count && characters[index + 1] == ";" {
                    current.append(";")
                    index += 1
                } else {
                    let mask = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !mask.isEmpty { masks.append(mask) }
                    current = ""
                }
            } else {
                current.append(characters[index])
            }
            index += 1
        }
        let mask = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mask.isEmpty { masks.append(mask) }
        return masks
    }

    private static func matches(_ file: URL, pattern: String) -> Bool {
        let value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if !value.contains(where: { $0 == "*" || $0 == "?" }), !value.contains("/") {
            let extensionName = normalizedExtension(value)
            if !extensionName.contains(".") { return file.pathExtension.caseInsensitiveCompare(extensionName) == .orderedSame }
        }
        var expression = "^"
        for character in value {
            switch character {
            case "*": expression += ".*"
            case "?": expression += "."
            default: expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        expression += "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: file.lastPathComponent, range: NSRange(file.lastPathComponent.startIndex..., in: file.lastPathComponent)) != nil
    }
}

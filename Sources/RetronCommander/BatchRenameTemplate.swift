import Foundation

enum BatchRenameTemplate {
    enum PathMode: String, CaseIterable, Identifiable, Hashable {
        case fileName
        case relativePath
        case fullPath

        var id: String { rawValue }
        var label: String {
            switch self {
            case .fileName: "Filename"
            case .relativePath: "Relative path"
            case .fullPath: "Full path"
            }
        }
    }

    struct Item {
        let url: URL
        let name: String
        let isDirectory: Bool
        let byteSize: Int64
        let modifiedAt: Date?
    }

    static func expand(_ template: String, item: Item, index: Int, root: URL, pathMode: PathMode = .fileName) -> String {
        var output = ""
        var cursor = template.startIndex
        while cursor < template.endIndex,
              let marker = template.range(of: "$(", range: cursor..<template.endIndex) {
            output += template[cursor..<marker.lowerBound]
            guard let close = template[marker.upperBound...].firstIndex(of: ")") else {
                output += template[marker.lowerBound...]
                return output
            }
            let body = String(template[marker.upperBound..<close])
            output += evaluate(body, item: item, index: index, root: root, pathMode: pathMode)
            cursor = template.index(after: close)
        }
        if cursor < template.endIndex { output += template[cursor...] }
        return output
    }

    private static func evaluate(_ body: String, item: Item, index: Int, root: URL, pathMode: PathMode) -> String {
        let split = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(split[0]).lowercased()
        let parameters = split.count == 2
            ? split[1].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            : []
        let file = item.url.standardizedFileURL
        let stem = item.isDirectory ? item.name : file.deletingPathExtension().lastPathComponent
        let suffix = item.isDirectory ? "" : file.pathExtension

        switch key {
        case "originalname":
            switch pathMode {
            case .fileName: return transformed(item.name, parameters: parameters)
            case .relativePath: return transformed(relativeName(file, root: root, fallback: item.name), parameters: parameters)
            case .fullPath: return transformed(file.path, parameters: parameters)
            }
        case "name": return transformed(item.name, parameters: parameters)
        case "namepart": return transformed(stem, parameters: parameters)
        case "extpart": return transformed(suffix, parameters: parameters)
        case "drive":
            guard pathMode == .fullPath else { return "" }
            let volume = (try? file.resourceValues(forKeys: [.volumeURLKey]).volume) ?? URL(fileURLWithPath: "/", isDirectory: true)
            return transformed(volume.path, parameters: parameters)
        case "path": return pathMode == .fullPath ? transformed(file.deletingLastPathComponent().path, parameters: parameters) : ""
        case "relativepath": return pathMode == .fileName ? "" : transformed(relativeName(file, root: root, fallback: item.name), parameters: parameters)
        case "size": return item.isDirectory ? "" : String(item.byteSize)
        case "date": return dateValue(item.modifiedAt, pattern: parameters.first, dateOnly: true)
        case "time": return dateValue(item.modifiedAt, pattern: parameters.first, dateOnly: false)
        case "counter": return counterValue(parameters, index: index)
        default: return "$(\(body))"
        }
    }

    private static func relativeName(_ file: URL, root: URL, fallback: String) -> String {
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : fallback
    }

    private static func transformed(_ input: String, parameters: [String]) -> String {
        var value = input
        var startOffset: Int?
        var endOffset: Int?
        var caseStyle: String?
        for parameter in parameters {
            switch parameter.lowercased() {
            case "lower", "upper", "mixed", "stripdia": caseStyle = parameter.lowercased()
            default:
                if let number = Int(parameter) {
                    if startOffset == nil { startOffset = number } else if endOffset == nil { endOffset = number }
                }
            }
        }
        if let startOffset {
            let count = value.count
            let start = startOffset >= 0 ? min(startOffset, count) : max(0, count + startOffset)
            let end: Int
            if let endOffset { end = endOffset >= 0 ? min(endOffset, count) : max(0, count + endOffset) }
            else { end = count }
            if start <= end { value = String(value.dropFirst(start).prefix(end - start)) }
        }
        switch caseStyle {
        case "lower": value = value.lowercased()
        case "upper": value = value.uppercased()
        case "mixed": value = value.prefix(1).uppercased() + value.dropFirst().lowercased()
        case "stripdia": value = value.applyingTransform(.stripDiacritics, reverse: false) ?? value
        default: break
        }
        return value
    }

    private static func dateValue(_ date: Date?, pattern: String?, dateOnly: Bool) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        if let pattern, !pattern.isEmpty {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = foundationDatePattern(fromWindowsPattern: pattern)
        } else {
            formatter.locale = .current
            formatter.dateStyle = dateOnly ? .short : .none
            formatter.timeStyle = dateOnly ? .none : .short
        }
        return formatter.string(from: date)
    }

    static func foundationDatePattern(fromWindowsPattern pattern: String) -> String {
        let units = Array(pattern)
        var converted = ""
        var position = 0
        var insideLiteral = false
        while position < units.count {
            let current = units[position]
            if current == "'" {
                insideLiteral.toggle()
                converted.append(current)
                position += 1
                continue
            }
            if insideLiteral || !"dMyHhmt".contains(current) {
                converted.append(current)
                position += 1
                continue
            }
            var limit = position + 1
            while limit < units.count && units[limit] == current { limit += 1 }
            let run = limit - position
            if current == "d" && run >= 3 { converted += run == 3 ? "EEE" : "EEEE" }
            else if current == "M" && run == 3 { converted += "MMM" }
            else if current == "M" && run >= 4 { converted += "MMMM" }
            else if current == "t" { converted += "a" }
            else { converted += String(repeating: current, count: run) }
            position = limit
        }
        return converted
    }

    private static func counterValue(_ parameters: [String], index: Int) -> String {
        let first = Int(parameters.first ?? "0") ?? 0
        let increment = Double(parameters.count > 1 ? parameters[1] : "1") ?? 1
        let radix = parameters.count > 2 ? parameters[2] : "d"
        var leftAligned = false
        var width = 0
        var pad = " "
        for option in parameters.dropFirst(3) {
            if option.lowercased() == "l" { leftAligned = true }
            else if width == 0, let parsed = Int(option), parsed >= 0 { width = parsed }
            else if option.count == 1 { pad = option }
        }
        let number = first + Int(increment * Double(index))
        var digits: String
        if radix == "x" || radix == "X" {
            let encoded = String(number.magnitude, radix: 16)
            digits = number < 0 ? "-" + encoded : encoded
            if radix == "X" { digits = digits.uppercased() }
        } else { digits = String(number) }
        guard width > digits.count else { return digits }
        let fill = String(repeating: pad, count: width - digits.count)
        return leftAligned ? digits + fill : fill + digits
    }
}

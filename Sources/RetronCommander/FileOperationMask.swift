import Foundation

/// Applies the Copy/Move operation-mask rules documented by Retron 4.0.
/// The first dot separates the name mask from the extension mask; the source
/// filename is split at its final dot so multi-dot extensions are retained.
enum FileOperationMask {
    static func apply(_ mask: String?, to filename: String) -> String {
        guard let mask, !mask.isEmpty else { return filename }

        let source = splitFilename(filename)
        guard let separator = mask.firstIndex(of: ".") else {
            let name = expand(String(mask), from: source.name)
            return name + source.extensionWithDot
        }

        let nameMask = String(mask[..<separator])
        let extensionMask = String(mask[mask.index(after: separator)...])
        let name = expand(nameMask, from: source.name)
        let ext = expand(extensionMask, from: source.fileExtension)
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    private static func splitFilename(_ filename: String) -> (name: String, fileExtension: String, extensionWithDot: String) {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
            return (filename, "", "")
        }
        let extStart = filename.index(after: dot)
        return (String(filename[..<dot]), String(filename[extStart...]), String(filename[dot...]))
    }

    private static func expand(_ mask: String, from source: String) -> String {
        let sourceCharacters = Array(source)
        var sourceIndex = 0
        var result = String()
        for character in mask {
            switch character {
            case "*":
                if sourceIndex < sourceCharacters.count {
                    result.append(contentsOf: sourceCharacters[sourceIndex...])
                    sourceIndex = sourceCharacters.count
                }
            case "?":
                if sourceIndex < sourceCharacters.count {
                    result.append(sourceCharacters[sourceIndex])
                    sourceIndex += 1
                }
            default:
                result.append(character)
            }
        }
        return result
    }
}

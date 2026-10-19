import Foundation

@main
struct VerifyPEInspection {
    static func main() throws {
        let targetPath = CommandLine.arguments.dropFirst().first ?? "/Users/maik/Downloads/as40x64/salamand.exe"
        let targetURL = URL(fileURLWithPath: targetPath)
        let inspection = try PEParser(data: Data(contentsOf: targetURL, options: [.mappedIfSafe])).inspect()
        precondition(inspection.bitness == "PE32+ (64-bit)", "Expected the supplied x64 PE image")
        precondition(!inspection.sections.isEmpty, "Expected section records")
        precondition(!inspection.resources.isEmpty, "Expected resource directory entries")
        print("PE inspection passed: \(inspection.sections.count) sections, \(inspection.imports.count) imported DLLs, \(inspection.exports.count) exports, \(inspection.debugEntries.count) debug records, \(inspection.resources.count) resources.")
        if let codeView = inspection.debugEntries.first(where: { $0.type == "CodeView" }) {
            print("CodeView: \(codeView.details)")
        }
    }
}

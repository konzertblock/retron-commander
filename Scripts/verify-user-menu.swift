import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct VerifyUserMenu {
    static func main() {
        let root = URL(fileURLWithPath: "/tmp/retron user menu", isDirectory: true)
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        let first = left.appendingPathComponent("a file's.txt")
        let second = left.appendingPathComponent("second.txt")
        let target = right.appendingPathComponent("target.txt")
        let env = ["USER_MENU_FIXTURE": "value with spaces"]

        let perItem = UserMenuCommand.expand(
    "printf %s $(FullName)", selectedItems: [first, second], activeDirectory: left,
    inactiveDirectory: right, leftItems: [first], rightItems: [target],
    leftDirectory: left, rightDirectory: right, environment: env
)
        require(perItem.count == 2, "current-file variable executes once per selected item")
        require(perItem[0] == "printf %s '\(first.path.replacingOccurrences(of: "'", with: "'\\''"))'", "shell-safe current-file expansion")

        let selected = UserMenuCommand.expand(
    "tool $(ListOfSelectedNames) $[USER_MENU_FIXTURE] $(FullPathLeft) $(FileToCompareRight)",
    selectedItems: [first, second], activeDirectory: left, inactiveDirectory: right,
    leftItems: [first], rightItems: [target], leftDirectory: left, rightDirectory: right,
    environment: env
)
        require(selected.count == 1, "list and compare variables execute one command")
        require(selected[0].contains("'\(first.path.replacingOccurrences(of: "'", with: "'\\''"))' '\(second.path)'"), "selected names are individually shell quoted")
        require(selected[0].contains("'value with spaces'"), "environment variable expansion preserves spaces")
        require(selected[0].contains("'\(left.path)'"), "left panel variable expansion")
        require(selected[0].contains("'\(target.path)'"), "opposite-panel compare variable expansion")

        print("User Menu expansion passed: per-item, selected-list, panel, compare, environment, and shell quoting.")
    }
}

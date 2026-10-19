import SwiftUI

struct SelectionMaskDialog: View {
    let selecting: Bool
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mask = "*"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selecting ? "Select Using Masks" : "Unselect Using Masks").font(.headline)
            Text("Use * and ? wildcards. Separate masks with semicolons; place excluded masks after |.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("File masks", text: $mask).textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Text("Examples: *.txt;*.doc    |*.tmp;*.bak")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selecting ? "Select" : "Unselect") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func commit() { apply(mask); dismiss() }
}

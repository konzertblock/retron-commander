import CryptoKit
import AppKit
import SwiftUI

struct EncryptionDialog: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isDecrypting = false
    @State private var isWorking = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isDecrypting ? "Decrypt File" : "Encrypt File").font(.headline)
            Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !isDecrypting {
                Text("AES-256-GCM encrypted file format. The password is not saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            if !isDecrypting { SecureField("Confirm password", text: $confirmation).textFieldStyle(.roundedBorder) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Toggle("Decrypt", isOn: $isDecrypting).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isDecrypting ? "Decrypt…" : "Encrypt…") { perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || password.isEmpty || (!isDecrypting && password != confirmation))
            }
        }
        .padding(16)
        .frame(width: 520)
        .overlay { if isWorking { ProgressView("Processing file…").padding(18).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 8)) } }
    }

    private func perform() {
        isWorking = true
        status = nil
        error = nil
        Task {
            do {
                let output = try await EncryptionService.transform(file, password: password, decrypt: isDecrypting)
                status = "Saved \(output.lastPathComponent)"
                password = ""
                confirmation = ""
                isWorking = false
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}

private enum EncryptionService {
    private static let magic = Data("OSALENC1".utf8)
    private static let iterations: UInt32 = 250_000
    private static let maximumInputSize: Int64 = 256 * 1024 * 1024

    static func transform(_ file: URL, password: String, decrypt: Bool) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let maximumSize = decrypt ? maximumInputSize + 64 : maximumInputSize
            guard size <= maximumSize else { throw EncryptionError.tooLarge }
            let input = try Data(contentsOf: file, options: [.mappedIfSafe])
            let outputData = try decrypt ? decryptData(input, password: password) : encryptData(input, password: password)
            let output = await MainActor.run { () -> URL? in
                let panel = NSSavePanel()
                panel.nameFieldStringValue = outputName(for: file, decrypting: decrypt)
                guard panel.runModal() == .OK else { return nil }
                return panel.url
            }
            guard let output else { throw EncryptionError.cancelled }
            try outputData.write(to: output, options: .atomic)
            return output
        }.value
    }

    private static func encryptData(_ data: Data, password: String) throws -> Data {
        guard password.count >= 8 else { throw EncryptionError.weakPassword }
        let salt = randomData(count: 16)
        let key = deriveKey(password: password, salt: salt, rounds: iterations)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw EncryptionError.invalidData }
        var result = magic
        result.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian, Array.init))
        result.append(salt)
        result.append(combined)
        return result
    }

    private static func decryptData(_ data: Data, password: String) throws -> Data {
        guard data.count >= 8 + 4 + 16 + 12 + 16, data.prefix(8) == magic else { throw EncryptionError.invalidData }
        let rounds = data[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (100_000...1_000_000).contains(rounds) else { throw EncryptionError.invalidData }
        let salt = Data(data[12..<28])
        let combined = Data(data.dropFirst(28))
        let key = deriveKey(password: password, salt: salt, rounds: rounds)
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealed, using: key)
        } catch { throw EncryptionError.authenticationFailed }
    }

    private static func deriveKey(password: String, salt: Data, rounds: UInt32) -> SymmetricKey {
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
        var result = u
        if rounds > 1 {
            for _ in 2...rounds {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                for index in result.indices { result[index] ^= u[index] }
            }
        }
        return SymmetricKey(data: result.prefix(32))
    }

    private static func randomData(count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    private static func outputName(for file: URL, decrypting: Bool) -> String {
        if decrypting, file.pathExtension == "salamac" { return file.deletingPathExtension().lastPathComponent }
        return file.lastPathComponent + (decrypting ? ".decrypted" : ".salamac")
    }
}

private enum EncryptionError: LocalizedError {
    case tooLarge, weakPassword, invalidData, authenticationFailed, cancelled
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Files larger than 256 MB are not processed by this dialog."
        case .weakPassword: "Use a password with at least eight characters."
        case .invalidData: "The file is not a supported encrypted file."
        case .authenticationFailed: "The password is incorrect or the encrypted file is damaged."
        case .cancelled: "Save was cancelled."
        }
    }
}

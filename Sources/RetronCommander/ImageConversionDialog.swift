import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ImageConversionFormat: String, CaseIterable, Identifiable {
    case jpeg, png, tiff, bmp, gif

    var id: String { rawValue }
    var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }
    var title: String { rawValue.uppercased() }

    var typeIdentifier: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        case .bmp: UTType("com.microsoft.bmp") ?? .data
        case .gif: .gif
        }
    }

    static func suggested(for url: URL) -> ImageConversionFormat {
        switch url.pathExtension.lowercased() {
        case "png": .png
        case "tif", "tiff": .tiff
        case "bmp", "dib": .bmp
        case "gif": .gif
        default: .jpeg
        }
    }
}

enum ImageConversionError: LocalizedError {
    case sourceUnavailable
    case invalidImage
    case destinationUnavailable
    case sameSourceAndDestination
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "The source image could not be opened."
        case .invalidImage: "The source file does not contain a decodable image."
        case .destinationUnavailable: "The selected output format could not be created."
        case .sameSourceAndDestination: "Choose a destination different from the source image."
        case .writeFailed: "The converted image could not be written."
        }
    }
}

enum ImageConversionService {
    static func convert(source: URL, destination: URL, format: ImageConversionFormat, quality: Double) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw ImageConversionError.sameSourceAndDestination
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ImageConversionError.sourceUnavailable
        }
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ImageConversionError.invalidImage
        }
        guard let imageDestination = CGImageDestinationCreateWithURL(
            destination as CFURL,
            format.typeIdentifier.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageConversionError.destinationUnavailable
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.05, quality))
        }
        CGImageDestinationAddImage(imageDestination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ImageConversionError.writeFailed
        }
    }
}

struct ImageConversionDialog: View {
    let source: URL
    @Environment(\.dismiss) private var dismiss
    @State private var format: ImageConversionFormat
    @State private var quality = 0.9
    @State private var isSaving = false
    @State private var error: String?

    init(source: URL) {
        self.source = source
        _format = State(initialValue: .suggested(for: source))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Image As").font(.headline)
            Text(source.lastPathComponent).font(.system(size: 12, design: .monospaced)).lineLimit(1)

            Picker("File type", selection: $format) {
                ForEach(ImageConversionFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: format) { _, _ in error = nil }

            if format == .jpeg {
                HStack {
                    Text("JPEG quality")
                    Slider(value: $quality, in: 0.05...1, step: 0.05)
                    Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }

            Text("ImageIO supports this format according to the installed macOS codecs. Original metadata is retained when the target format supports it.")
                .font(.caption).foregroundStyle(.secondary)

            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isSaving ? "Saving…" : "Save As…", action: saveAs)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(18)
        .frame(width: 470)
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.typeIdentifier]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        panel.directoryURL = source.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isSaving = true
        error = nil
        let selectedFormat = format
        let selectedQuality = quality
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ImageConversionService.convert(
                        source: source,
                        destination: destination,
                        format: selectedFormat,
                        quality: selectedQuality
                    )
                }.value
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                self.error = error.localizedDescription
            }
        }
    }
}

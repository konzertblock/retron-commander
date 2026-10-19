import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct VerifyImageConversion {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("retron-image-conversion-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let source = root.appendingPathComponent("fixture.png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Could not create the source fixture.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "Could not write the PNG source fixture.")

        for format in ImageConversionFormat.allCases {
            let output = root.appendingPathComponent("converted.\(format.fileExtension)")
            try ImageConversionService.convert(source: source, destination: output, format: format, quality: 0.82)
            guard let imageSource = CGImageSourceCreateWithURL(output as CFURL, nil),
                  let converted = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                fatalError("ImageIO could not read the generated \(format.title) file.")
            }
            precondition(converted.width == 24 && converted.height == 16, "\(format.title) dimensions changed.")
            print("\(format.title): round-trip passed (24×16)")
        }

        do {
            try ImageConversionService.convert(source: source, destination: source, format: .png, quality: 1)
            fatalError("The service allowed overwriting the source image.")
        } catch ImageConversionError.sameSourceAndDestination {
            print("Source overwrite guard: passed")
        }
    }
}

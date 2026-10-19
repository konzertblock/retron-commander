import Foundation

@main
struct RetronID3Harness {
    static func main() async throws {
        let v2Frames = frame("TIT2", "ID3 Title") + frame("TPE1", "Example Artist")
        var tag = Data("ID3".utf8) + Data([3, 0, 0]) + syncsafe(v2Frames.count) + v2Frames
        tag.append(contentsOf: [0xFF, 0xFB, 0x90, 0x64])

        var v1 = Data("TAG".utf8)
        v1.append(padded("Legacy Title", to: 30))
        v1.append(padded("Legacy Artist", to: 30))
        v1.append(padded("Legacy Album", to: 30))
        v1.append(contentsOf: "1999".utf8)
        v1.append(padded("Legacy comment", to: 28))
        v1.append(contentsOf: [0, 9, 17])
        tag.append(v1)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("retron-multimedia-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("retron-id3-fixture.mp3")
        try tag.write(to: file)
        let rows = try ID3TagReader.read(file)
        let map = Dictionary(rows, uniquingKeysWith: { first, _ in first })
        precondition(map["ID3v2 Title"] == "ID3 Title")
        precondition(map["ID3v2 Artist"] == "Example Artist")
        precondition(map["ID3v1 Title"] == "Legacy Title")
        precondition(map["ID3v1 Track"] == "9")
        precondition(map["ID3v1 Genre ID"] == "17")
        precondition(map["MPEG Version"] == "MPEG 1 Layer III")
        precondition(map["Bitrate"] == "128 kbps")
        precondition(map["Sampling Frequency"] == "44100 Hz")
        precondition(map["Channel Mode"] == "Joint stereo")

        let secondFile = temp.appendingPathComponent("second&file.wav")
        try Data([0, 1, 2, 3]).write(to: secondFile)
        let firstReport = MultimediaInfoReport(file: file, rows: try await MultimediaInfoReader.read(file))
        let secondReport = MultimediaInfoReport(file: secondFile, rows: try await MultimediaInfoReader.read(secondFile))
        let html = MultimediaInfoReader.html(for: [firstReport, secondReport])
        precondition(html.contains("retron-id3-fixture.mp3"))
        precondition(html.contains("second&amp;file.wav"))
        precondition(html.contains("ID3 Title"))
        print("ID3v2.3/v1.1, MPEG header, metadata loading, and two-file escaped HTML report verified")
    }

    private static func frame(_ id: String, _ text: String) -> Data {
        let body = Data([0]) + Data(text.utf8)
        var frame = Data(id.utf8)
        frame.append(contentsOf: [UInt8((body.count >> 24) & 255), UInt8((body.count >> 16) & 255), UInt8((body.count >> 8) & 255), UInt8(body.count & 255), 0, 0])
        frame.append(body)
        return frame
    }

    private static func syncsafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }

    private static func padded(_ string: String, to count: Int) -> Data {
        var bytes = Data(string.utf8.prefix(count))
        bytes.append(contentsOf: repeatElement(0, count: count - bytes.count))
        return bytes
    }
}

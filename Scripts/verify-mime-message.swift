import Foundation

@main
enum VerifyMIMEMessage {
    static func main() throws {
        let message = """
        From: sender@example.test
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer-boundary"

        Message text, not an attachment.
        --outer-boundary
        Content-Type: multipart/alternative; boundary=inner-boundary

        --inner-boundary
        Content-Type: text/plain; charset=utf-8

        This is the plain message body.
        --inner-boundary
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*=UTF-8''caf%C3%A9.txt
        Content-Transfer-Encoding: base64

        QmluYXJ5IGF0dGFjaG1lbnQgAA==
        --inner-boundary--
        --outer-boundary
        Content-Type: text/plain
        Content-Disposition: attachment; filename="notes.txt"
        Content-Transfer-Encoding: quoted-printable

        A=00B=3D
        --outer-boundary
        Content-Type: text/plain
        Content-Disposition: attachment; filename="=?UTF-8?B?5pel5pysLnR4dA==?="
        Content-Transfer-Encoding: 7bit

        ok
        --outer-boundary
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*0*=UTF-8''continued%20; filename*1*=name; filename*2=.txt
        Content-Transfer-Encoding: base64

        Y29udGludWVk
        --outer-boundary
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*0*=ISO-8859-1''caf%E9; filename*1=.txt
        Content-Transfer-Encoding: 7bit

        x
        --outer-boundary--
        """

        let attachments = try MIMEMessageParser.parse(Data(message.utf8))
        precondition(attachments.count == 5, "nested MIME body/attachment classification failed")
        precondition(attachments[0].fileName == "café.txt", "RFC 2231 attachment filename was not decoded")
        precondition(attachments[0].decoded.data == Data([0x42, 0x69, 0x6e, 0x61, 0x72, 0x79, 0x20, 0x61, 0x74, 0x74, 0x61, 0x63, 0x68, 0x6d, 0x65, 0x6e, 0x74, 0x20, 0x00]), "nested Base64 attachment was corrupted")
        precondition(attachments[1].fileName == "notes.txt", "quoted-printable filename was lost")
        precondition(attachments[1].decoded.data == Data([0x41, 0x00, 0x42, 0x3d]), "quoted-printable attachment was corrupted")
        precondition(attachments[2].fileName == "日本.txt", "RFC 2047 attachment filename was not decoded")
        precondition(attachments[2].decoded.data == Data("ok".utf8), "7bit attachment body was changed")
        precondition(attachments[3].fileName == "continued name.txt", "RFC 2231 continuation parameters were not joined")
        precondition(attachments[4].fileName == "café.txt", "RFC 2231 continuation charset was not decoded")

        let noAttachments = try MIMEMessageParser.parse(Data("From: a@example.test\r\nContent-Type: text/plain\r\n\r\nHello".utf8))
        precondition(noAttachments.isEmpty, "plain message body was reported as an attachment")

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retron-mime-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let exportFiles = attachments + [
            MIMEAttachment(id: "duplicate", fileName: "notes.txt", contentType: "text/plain", decoded: DecodedMIMEFile(data: Data("second copy".utf8))),
            MIMEAttachment(id: "unsafe", fileName: "../../escape.txt", contentType: "text/plain", decoded: DecodedMIMEFile(data: Data("safe path".utf8)))
        ]
        let exported = try MIMEAttachmentExportService.export(exportFiles, to: outputDirectory)
        let duplicateData = try Data(contentsOf: exported[5])
        precondition(exported.map(\.lastPathComponent) == ["café.txt", "notes.txt", "日本.txt", "continued name.txt", "café (2).txt", "notes (2).txt", ".._.._escape.txt"], "attachment export did not uniquify or sanitize filenames")
        precondition(duplicateData == Data("second copy".utf8), "duplicate attachment export changed data")
        precondition(exported.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == outputDirectory.standardizedFileURL }, "attachment escaped the chosen directory")

        let broken = "Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\n\r\nbody\r\n"
        var malformedBoundaryRejected = false
        do { _ = try MIMEMessageParser.parse(Data(broken.utf8)) } catch { malformedBoundaryRejected = true }
        precondition(malformedBoundaryRejected, "unterminated multipart message was accepted")
        print("Nested multipart parsing, RFC 2231 single and continuation filenames across UTF-8/Latin-1, RFC 2047 filenames, transfer decoding, body filtering, safe unique extraction, and malformed-boundary rejection verified")
    }
}

import SwiftUI

private struct PluginStatus: Identifiable {
    let id: String
    let status: String
    let summary: String
}

struct PluginInventoryDialog: View {
    @Environment(\.dismiss) private var dismiss

    private let plugins: [PluginStatus] = [
        .init(id: "7zip", status: "Partial", summary: "7-Zip-backed list, password and header-encrypted creation, password-based open/extract/test, common-format creation, compression levels, 7z volume splitting, and panel move/rename/delete; ZIP spanning, advanced methods, and plugin-specific dialogs are missing."),
        .init(id: "automation", status: "Partial", summary: "JavaScriptCore scripts from a repository, run-focused-script, source/target panel path and item snapshots, select/deselect/store selection, path/mask helpers, prompts, persistent string values, and viewing files. WSH/VBScript, Forms, progress/wait windows, abort/debug, overwrite dialog, and the complete API are missing."),
        .init(id: "checksum", status: "Partial", summary: "CRC32, MD5, SHA-1, SHA-256, and SHA-512 calculation; SFV and hash-manifest creation and verification; plugin-specific configuration remains missing."),
        .init(id: "checkver", status: "Missing", summary: "Update checks and notifications are not ported."),
        .init(id: "dbviewer", status: "Partial", summary: "DBF field/record browser with search, bookmarks, deleted-row markers, and TSV copy; code-page and memo support are limited."),
        .init(id: "diskmap", status: "Partial", summary: "Immediate-child weighted treemap and folder size table; deeper navigation and Retron's exact layout/options remain missing."),
        .init(id: "encrypt", status: "Partial", summary: "AES-256-GCM password encryption for files up to 256 MB; key files, compatibility, secure wipe, and free-space cleaning are missing."),
        .init(id: "filecomp", status: "Partial", summary: "Aligned text/hex comparison with changed rows and next/previous difference navigation; color rules and full comparison options are missing."),
        .init(id: "ftp", status: "Partial", summary: "FTP/FTPS listing, multi-file upload/download with sequential queueing, pause/resume/cancel, curl resume, HTTP/SOCKS proxies, and Keychain-backed saved profiles; remote twin-panel integration, byte progress/speed limits, permissions, and richer directory listings are missing."),
        .init(id: "ieviewer", status: "Partial", summary: "Internal WebKit view for HTML, XHTML, and XML; MHT/webarchive files, plugin settings, and Retron's IE behavior are missing."),
        .init(id: "mmviewer", status: "Partial", summary: "AVFoundation metadata plus ID3v1/v2 tags and selected-file HTML export; exact variable-bitrate analysis and legacy VQF/tracker parsers remain missing."),
        .init(id: "nethood", status: "Partial", summary: "Bonjour SMB discovery and macOS mount handoff; share enumeration, cached visits, and panel integration are missing."),
        .init(id: "pak", status: "Partial", summary: "Native Quake PAK listing, data/structure test, safe extraction, creation, member rename, move, and delete; optimize workflow is missing."),
        .init(id: "peviewer", status: "Partial", summary: "PE headers, sections, imports/exports, CodeView PDB identity, and resource directory type/name/language/data-RVA listings are shown; resource payload extraction and decoded version fields remain missing."),
        .init(id: "pictview", status: "Partial", summary: "macOS image preview/zoom and Save As conversion to JPEG, PNG, TIFF, BMP, and GIF with JPEG quality; PictView's 60+ codecs, full-screen viewer, thumbnail mode/update, EXIF details, and remaining save options are missing."),
        .init(id: "regedt", status: "Partial", summary: "Mac-native property-list editor reads XML/binary PLISTs and validates XML edits on Save As; Windows Registry hives are not supported."),
        .init(id: "renamer", status: "Partial", summary: "Live preview, Retron-style name/path/size/date/time/counter template variables, filename/relative/full-path modes, masked recursive inclusion of files, emptied source-folder cleanup, case transforms, literal or regular-expression replacement, and manual name-list editing; undo, preview sorting/filtering, full error validation, and per-plugin presets remain missing."),
        .init(id: "splitcbn", status: "Partial", summary: "Split by size or count, .001 numbering, optional extension removal, native macOS .command join script with SHA-256 verification, CRC32 metadata, and legacy .bat/.part joins; removable-drive prompts and configuration are missing."),
        .init(id: "tar", status: "Partial", summary: "7-Zip-backed common formats; dedicated options and RPM metadata are missing."),
        .init(id: "unarj", status: "Partial", summary: "External backend may support ARJ; dedicated dialog and behavior are missing."),
        .init(id: "uncab", status: "Partial", summary: "External backend may support CAB; dedicated dialog and behavior are missing."),
        .init(id: "unchm", status: "Partial", summary: "External backend may support CHM; dedicated dialog and behavior are missing."),
        .init(id: "undelete", status: "Partial", summary: "Native macOS restore from user and mounted-volume Trash with conflict-safe restoration; recovery of permanently deleted files and NTFS/FAT disk scanning are not implemented."),
        .init(id: "diskimage", status: "Partial", summary: "macOS-mounted disk image browsing, recursive listing, and streamed extraction with progress and cancellation; mount options and multi-volume image selection are not yet available."),
        .init(id: "uniso", status: "Partial", summary: "External archive backend may read ISO; UDF and multi-session support are missing."),
        .init(id: "unlha", status: "Partial", summary: "External backend may support LZH; dedicated dialog and behavior are missing."),
        .init(id: "unmime", status: "Partial", summary: "Base64, quoted-printable, UUEncode, XXEncode, yEnc, BinHex with fork metadata/CRCs, and multipart .eml attachment extraction; MIME edge cases and full charset handling remain missing."),
        .init(id: "unrar", status: "Partial", summary: "External backend may list/extract RAR; full plugin workflows and options are missing."),
        .init(id: "wmobile", status: "Missing", summary: "Windows Mobile device support is not ported."),
        .init(id: "zip", status: "Partial", summary: "ZIP creation with AES-256 encryption, browsing, password-based extraction and integrity test, and panel member operations; legacy ZIP encryption, AES-128, and spanning are missing.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plugin Coverage — Retron Commander 1.0").font(.headline)
            Text("Status reflects the current macOS implementation.")
                .font(.caption).foregroundStyle(.secondary)
            Table(plugins) {
                TableColumn("Plugin", value: \.id).width(min: 90, ideal: 110)
                TableColumn("Status", value: \.status).width(min: 75, ideal: 90)
                TableColumn("Current coverage", value: \.summary)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 580)
    }
}

import AppKit

enum FileKind: Int, CaseIterable, Identifiable, Sendable {
    case video
    case image
    case audio
    case archive
    case virtualMachine
    case application
    case developer
    case document
    case data
    case other
    case smallFiles
    case unseen
    case system

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .video: "Видео"
        case .image: "Изображения"
        case .audio: "Аудио"
        case .archive: "Архивы и образы"
        case .virtualMachine: "Виртуальные машины"
        case .application: "Программы"
        case .developer: "Разработка"
        case .document: "Документы"
        case .data: "Данные и модели"
        case .other: "Прочее"
        case .smallFiles: "Мелкие файлы"
        case .unseen: "Не видно Spotlight"
        case .system: "Системные тома"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .virtualMachine: "desktopcomputer"
        case .application: "app"
        case .developer: "hammer"
        case .document: "doc.text"
        case .data: "cylinder"
        case .other: "doc"
        case .smallFiles: "square.grid.3x3"
        case .unseen: "eye.slash"
        case .system: "internaldrive"
        }
    }

    /// System colors follow the appearance and the "Increase contrast" setting.
    var color: NSColor {
        switch self {
        case .video: .systemBlue
        case .image: .systemGreen
        case .audio: .systemOrange
        case .archive: .systemYellow
        case .virtualMachine: .systemRed
        case .application: .systemTeal
        case .developer: .systemCyan
        case .document: .systemPink
        case .data: .systemBrown
        case .other: .systemGray
        case .smallFiles: .tertiaryLabelColor
        case .unseen: .quaternaryLabelColor
        case .system: .secondaryLabelColor
        }
    }

    static func classify(name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        return byExtension[ext] ?? .other
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ list: String) {
            for ext in list.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.video, "mp4 mov m4v mkv avi webm mts m2ts wmv flv mpg mpeg 3gp braw r3d insv lrv mxf vob ts fcpbundle imovielibrary tvlibrary")
        add(.image, "jpg jpeg png heic heif gif tif tiff bmp webp cr2 cr3 nef arw dng raf orf rw2 psd psb ai svg exr hdr kra xcf afphoto photoslibrary aplibrary")
        add(.audio, "mp3 wav aiff aif flac m4a aac ogg opus caf mid midi als logicx aup3 wma band ptx musiclibrary")
        add(.archive, "zip gz tgz tar bz2 xz 7z rar zst lz4 lzma xip pkg mpkg dmg iso img sparseimage sparsebundle cpio cab deb rpm")
        add(.virtualMachine, "vmdk vdi qcow2 raw hdd hds pvm vhd vhdx utm vmem vmsn nvram vmwarevm pvmp")
        add(.application, "app framework dylib so bundle plugin appex kext component vst vst3 aaxplugin exe dll msi ipa apk aab xpc")
        add(.developer, "o a jar class pack idx pch pcm swiftmodule swiftinterface node wasm dsym xcarchive obj lib pdb bin elf hex uf2 map rlib rmeta")
        add(.document, "pdf doc docx xls xlsx ppt pptx key pages numbers txt md rtf rtfd epub djvu sketch fig indd")
        add(.data, "db sqlite sqlite3 sqlite-wal wal realm log json csv tsv parquet npy npz pt pth ckpt safetensors gguf onnx h5 hdf5 pb tflite mlmodel mlpackage mlmodelc dat cache")
        return map
    }()
}

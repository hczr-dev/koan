import Foundation

/// Downloads put away by what they are (Settings › General › Sort downloads
/// into folders): a picture into Images, a disk image into Installers, and
/// so on, inside the folder they were going to; anything else stays where
/// it was going.
enum DownloadSorting {
    static let key = "downloads.sort"
    /// On unless turned off; off in unit tests, which check where a file lands on its own.
    static var on: Bool { Store.settings.object(forKey: key) as? Bool ?? !Store.unitTests }

    static let kinds: [(folder: String, extensions: Set<String>)] = [
        ("Images", ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "svg", "tif", "tiff", "bmp", "ico", "raw", "dng", "psd"]),
        ("Videos", ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"]),
        ("Audio", ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff", "aif", "alac", "mid", "midi"]),
        ("Documents", ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "rtf", "md", "csv", "epub", "odt", "ods", "odp", "tex"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4"]),
        ("Installers", ["dmg", "pkg", "mpkg", "iso", "exe", "msi", "appimage", "deb", "rpm", "apk", "ipa"]),
        ("Code", ["json", "xml", "yaml", "yml", "js", "ts", "py", "swift", "rb", "go", "rs", "c", "cpp", "h", "java", "kt", "sh", "ipynb", "sql", "html", "css"]),
        ("Fonts", ["ttf", "otf", "woff", "woff2"]),
        ("Torrents", ["torrent"]),
    ]

    static func folder(for name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return kinds.first { $0.extensions.contains(ext) }?.folder
    }

    /// Where a file of this name goes inside `folder`, the subfolder made
    /// if it isn't there; `folder` itself when sorting is off or can't be done.
    static func place(_ name: String, in folder: URL) -> URL {
        guard on, let sub = self.folder(for: name) else { return folder }
        return ensure(folder.appendingPathComponent(sub, isDirectory: true)) ?? folder
    }

    static func ensure(_ dir: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }
}

import Foundation
import ZIPFoundation

/// On first launch, unzip the bundled `seed-data.zip` into the sandbox so the
/// app can demo the full lesson loop *with audio* without hitting GitHub Releases.
///
/// The zip is built by `scripts/build-seed-zip.sh` and contains:
///
///     data/books/<id>/...      → unzipped under `cstf/data/books/<id>/`
///     audio/<xx>/<sha>.m4a     → unzipped under `cstf/audio/<xx>/<sha>.m4a`
///
/// Both subtrees are siblings of `cstf/`, matching what AssetDownloader writes
/// for downloaded books. Already-downloaded books overlay the seed without
/// collision because the seed only ships a single book + the audio for one
/// of its lessons.
///
/// ⚠️ Seed refresh must never destroy user data. An earlier implementation
/// wiped the whole `cstf/audio` directory before re-extracting, which deleted
/// every book the user had downloaded from the manifest (and the
/// `audio/.downloaded` markers with it). The current implementation unzips to a
/// staging directory and merges **additive only**: missing files are copied,
/// existing files are kept, nothing is ever deleted.
enum SeedInstaller {
    /// The single book shipped inside `seed-data.zip`.
    private static let seedBookId = "g1up"

    static func installIfNeeded() {
        guard let zipURL = Bundle.main.url(forResource: "seed-data", withExtension: "zip") else {
            return
        }
        // Parent of `data/` and `audio/` — i.e. `Application Support/cstf/`.
        let cstfRoot = DataLoader.shared.sandboxDataRoot.deletingLastPathComponent()
        let booksDir = DataLoader.shared.sandboxDataRoot.appendingPathComponent("books", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: cstfRoot, withIntermediateDirectories: true)

        // Skip if the seed has already been installed at the current bundled
        // version. The version stamp lives in `cstf/seed-version.txt` so seed
        // upgrades (e.g. swapping the bundled book or re-encoding audio) take
        // effect on the next launch without needing the user to wipe the app.
        let stampURL = cstfRoot.appendingPathComponent("seed-version.txt")
        let bundledVersion = Self.currentBundledVersion(zipURL: zipURL)
        if let stamped = try? String(contentsOf: stampURL, encoding: .utf8),
           stamped.trimmingCharacters(in: .whitespacesAndNewlines) == bundledVersion {
            return
        }

        // `audio/.downloaded/<bookId>` 只在「按 manifest 校验通过并安装完成」后写入。
        // 标记存在 = 磁盘上是用户下载的、可能比 seed 更新的资源，seed 不得覆盖。
        let seedBookMarker = cstfRoot
            .appendingPathComponent("audio/.downloaded", isDirectory: true)
            .appendingPathComponent(seedBookId)
        let userOwnsSeedBook = fm.fileExists(atPath: seedBookMarker.path)

        let staging = fm.temporaryDirectory
            .appendingPathComponent("cstf-seed-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }

            try fm.unzipItem(at: zipURL, to: staging)

            if !userOwnsSeedBook {
                // 用户没下载过这本书：清掉 seed 书的旧数据，让新版 seed 完整落地。
                // 只动这一个目录，其它教材（用户下载的）一律不碰。
                try? fm.removeItem(at: booksDir.appendingPathComponent(seedBookId, isDirectory: true))
            }

            try merge(
                staging: staging,
                into: cstfRoot,
                skipBookId: userOwnsSeedBook ? seedBookId : nil
            )
            try? bundledVersion.write(to: stampURL, atomically: true, encoding: .utf8)
        } catch {
            // Non-fatal: the user can still download books normally.
            print("[SeedInstaller] unzip failed: \(error)")
        }
    }

    /// 把 seed 内容合并进沙盒：只补缺失文件，不覆盖已有文件，不删除任何东西。
    ///
    /// 音频按 sha256 命名（`audio/<xx>/<sha>.m4a`），新 seed 换了编码只会出现
    /// 新文件名，旧文件留着也不影响播放，所以「只补不删」是安全的。
    private static func merge(staging: URL, into root: URL, skipBookId: String?) throws {
        let fm = FileManager.default
        // 统一解析符号链接 /private 前缀，避免相对路径全部算丢。
        let stagingResolved = staging.resolvingSymlinksInPath()
        let rootResolved = root.resolvingSymlinksInPath()

        guard let enumerator = fm.enumerator(
            at: stagingResolved,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let skipPrefix = skipBookId.map { "books/\($0)/" }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }

            guard let relative = relativePath(from: stagingResolved, to: fileURL.resolvingSymlinksInPath()),
                  !relative.isEmpty else { continue }

            // 用户自己下载过 seed 书 → 跳过它的数据，避免被旧 seed 覆盖。
            if let skipPrefix, relative.hasPrefix(skipPrefix) { continue }

            let target = rootResolved.appendingPathComponent(relative)
            guard !fm.fileExists(atPath: target.path) else { continue }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: fileURL, to: target)
        }
    }

    /// 安全计算相对路径，兼容 /var 与 /private/var。
    private static func relativePath(from base: URL, to file: URL) -> String? {
        let baseComponents = base.pathComponents
        let fileComponents = file.pathComponents
        guard fileComponents.count >= baseComponents.count else { return nil }
        for (i, c) in baseComponents.enumerated() where fileComponents[i] != c {
            return nil
        }
        let rel = fileComponents.dropFirst(baseComponents.count)
        return rel.isEmpty ? nil : rel.joined(separator: "/")
    }

    /// Version derived from the bundled zip's mtime. Re-runs trigger a refresh
    /// whenever the developer rebuilds the seed via `scripts/build-seed-zip.sh`.
    private static func currentBundledVersion(zipURL: URL) -> String {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: zipURL.path),
           let date = attrs[.modificationDate] as? Date {
            return "\(Int(date.timeIntervalSince1970))"
        }
        return "unknown"
    }
}

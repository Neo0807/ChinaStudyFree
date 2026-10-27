import Foundation
import CryptoKit
import ZIPFoundation

// MARK: - Manifest models

struct ManifestBundle: Codable, Hashable {
    let name: String
    let bytes: Int64
    let sha256: String
}

struct ManifestEntry: Codable, Hashable, Identifiable {
    let bookId: String
    let audioRefCount: Int
    let data: ManifestBundle
    let audio: ManifestBundle
    var id: String { bookId }
}

struct IosManifest: Codable, Hashable {
    let generatedAt: String
    let aacBitrate: String
    let books: [ManifestEntry]
}

// MARK: - Errors

enum AssetDownloadError: Error, LocalizedError {
    case manifestUnavailable
    case sha256Mismatch(expected: String, actual: String, file: String)
    case unzipFailed(String)
    case httpStatus(Int)
    case audioNotReady

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable:
            return "无法获取资源 manifest，请检查网络后重试"
        case .sha256Mismatch(let exp, let act, let file):
            return "校验失败 \(file)：期望 \(exp.prefix(12))…，实际 \(act.prefix(12))…"
        case .unzipFailed(let msg):
            return "解压失败：\(msg)"
        case .httpStatus(let code):
            return "下载失败 HTTP \(code)"
        case .audioNotReady:
            return "音频未正确解压到播放目录，请重试下载"
        }
    }
}

// MARK: - Downloader

@MainActor
final class AssetDownloader: ObservableObject {
    static let shared = AssetDownloader()

    var releaseBaseURL = URL(string: "https://github.com/wuwangzhang1216/ChinaTextbookStudyFree/releases/download/v1.7.3-ios-resources")!

    @Published private(set) var manifest: IosManifest?
    @Published private(set) var bookProgress: [String: Double] = [:]
    @Published private(set) var inFlight: Set<String> = []
    @Published private(set) var lastError: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: cfg)
    }()

    private var dataRoot: URL { DataLoader.shared.sandboxDataRoot }
    private var audioRoot: URL { DataLoader.shared.sandboxAudioRoot }
    private var audioReadyCache: [String: Bool] = [:]

    // MARK: - Manifest

    @discardableResult
    func loadManifest() async throws -> IosManifest {
        let url = releaseBaseURL.appendingPathComponent("ios-manifest.json")
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AssetDownloadError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let manifest = try JSONDecoder().decode(IosManifest.self, from: data)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? data.write(to: cacheRoot.appendingPathComponent("ios-manifest.json"))
        self.manifest = manifest
        audioReadyCache.removeAll()
        return manifest
    }

    func loadCachedManifest() -> IosManifest? {
        let url = cacheRoot.appendingPathComponent("ios-manifest.json")
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(IosManifest.self, from: data) else {
            return nil
        }
        for entry in m.books where hasBookData(entry.bookId) {
            let marker = audioMarkerURL(entry.bookId)
            if let old = try? String(contentsOf: marker, encoding: .utf8),
               old.trimmingCharacters(in: .whitespacesAndNewlines) == entry.audio.sha256 {
                try? Self.bundleFingerprint(entry).write(to: marker, atomically: true, encoding: .utf8)
            }
        }
        self.manifest = m
        audioReadyCache.removeAll()
        return m
    }

    // MARK: - Status

    func isBookDownloaded(_ bookId: String) -> Bool {
        hasBookData(bookId) && hasBookAudio(bookId)
    }

    func hasBookData(_ bookId: String) -> Bool {
        let outline = dataRoot
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookId, isDirectory: true)
            .appendingPathComponent("outline.json")
        return FileManager.default.fileExists(atPath: outline.path)
    }

    func hasBookAudio(_ bookId: String) -> Bool {
        if let cached = audioReadyCache[bookId] { return cached }

        // 无音频引用的书（部分数学书）直接视为音频就绪
        if let entry = manifest?.books.first(where: { $0.bookId == bookId }),
           entry.audioRefCount == 0 || entry.audio.bytes <= 0 || entry.audio.sha256.isEmpty {
            audioReadyCache[bookId] = true
            return true
        }

        let filesOk = probeBookAudio(bookId)
        let hasMarker = FileManager.default.fileExists(atPath: audioMarkerURL(bookId).path)

        if hasMarker && !filesOk {
            try? FileManager.default.removeItem(at: audioMarkerURL(bookId))
        }

        audioReadyCache[bookId] = filesOk
        return filesOk
    }

    private var audioMarkerDir: URL {
        audioRoot.appendingPathComponent(".downloaded", isDirectory: true)
    }

    private func audioMarkerURL(_ bookId: String) -> URL {
        audioMarkerDir.appendingPathComponent(bookId)
    }

    nonisolated static func bundleFingerprint(_ entry: ManifestEntry) -> String {
        "\(entry.data.sha256)\n\(entry.audio.sha256)"
    }

    private func writeAudioMarker(_ entry: ManifestEntry) {
        try? FileManager.default.createDirectory(at: audioMarkerDir, withIntermediateDirectories: true)
        try? Self.bundleFingerprint(entry).write(to: audioMarkerURL(entry.bookId), atomically: true, encoding: .utf8)
    }

    private func probeBookAudio(_ bookId: String) -> Bool {
        let refs = sampleAudioRefs(bookId, limit: 8)
        guard !refs.isEmpty else { return true }
        return refs.allSatisfy { AudioPlayer.shared.resolve($0) != nil }
    }

    private func sampleAudioRefs(_ bookId: String, limit: Int) -> [String] {
        var refs: [String] = []
        func collect(_ path: String?) {
            guard refs.count < limit, let path, !path.isEmpty else { return }
            refs.append(path)
        }
        if let passages = (try? DataLoader.shared.loadPassages(bookId: bookId))?.passages {
            outer: for p in passages {
                for s in p.sentences {
                    collect(s.audio)
                    if refs.count >= limit { break outer }
                }
            }
        }
        if refs.count < limit, let stories = (try? DataLoader.shared.loadStories(bookId: bookId))?.stories {
            outer: for s in stories {
                for sentence in s.sentences {
                    collect(sentence.audio)
                    if refs.count >= limit { break outer }
                }
            }
        }
        if refs.count < limit, let lesson = firstLesson(bookId) {
            for q in lesson.questions {
                collect(q.audio?.question)
                collect(q.audio?.explanation)
                if refs.count >= limit { break }
            }
        }
        return refs
    }

    private func firstLesson(_ bookId: String) -> Lesson? {
        let dir = dataRoot
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookId, isDirectory: true)
            .appendingPathComponent("lessons", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        guard let first = names.filter({ $0.hasSuffix(".json") }).sorted().first else { return nil }
        let lessonId = String(first.dropLast(".json".count))
        return try? DataLoader.shared.loadLesson(bookId: bookId, lessonId: lessonId)
    }

    // MARK: - Download

    func ensureBookDownloaded(_ entry: ManifestEntry) async throws {
        if inFlight.contains(entry.bookId) { return }
        inFlight.insert(entry.bookId)
        defer { inFlight.remove(entry.bookId) }
        bookProgress[entry.bookId] = 0
        lastError = nil
        audioReadyCache.removeAll()

        do {
            // 数据包 0 → 0.2
            try await downloadBundle(
                bundle: entry.data,
                extractTo: dataRoot,
                weight: 0.2,
                phaseBase: 0.0,
                bookId: entry.bookId
            )
            bookProgress[entry.bookId] = 0.2

            // 无音频的书直接跳过音频下载
            let needAudio = entry.audioRefCount > 0
                && entry.audio.bytes > 0
                && !entry.audio.sha256.isEmpty

            if needAudio {
                try await downloadBundle(
                    bundle: entry.audio,
                    extractTo: audioRoot.deletingLastPathComponent(),
                    weight: 0.8,
                    phaseBase: 0.2,
                    bookId: entry.bookId
                )
                audioReadyCache.removeAll()
                if !probeBookAudio(entry.bookId) {
                    throw AssetDownloadError.audioNotReady
                }
            }

            writeAudioMarker(entry)
            audioReadyCache.removeAll()
            bookProgress[entry.bookId] = 1
            try? markExcludedFromBackup(dataRoot)
            try? markExcludedFromBackup(audioRoot)
        } catch {
            audioReadyCache.removeAll()
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw error
        }
    }

    private func downloadBundle(
        bundle: ManifestBundle,
        extractTo destination: URL,
        weight: Double,
        phaseBase: Double,
        bookId: String
    ) async throws {
        let url = releaseBaseURL.appendingPathComponent(bundle.name)

        let (tempURL, resp) = try await session.download(from: url) { [weak self] received, expected in
            guard let self else { return }
            let total = expected > 0 ? Double(expected) : Double(bundle.bytes)
            let frac = total > 0 ? min(1.0, Double(received) / total) : 0
            Task { @MainActor in
                self.bookProgress[bookId] = phaseBase + frac * weight
            }
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw AssetDownloadError.httpStatus(http.statusCode)
        }

        let actualSha = try sha256Hex(of: tempURL)
        guard actualSha == bundle.sha256 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AssetDownloadError.sha256Mismatch(expected: bundle.sha256, actual: actualSha, file: bundle.name)
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try Self.installArchive(tempURL, destination: destination)
        } catch {
            throw AssetDownloadError.unzipFailed(String(describing: error))
        }
        try? FileManager.default.removeItem(at: tempURL)
    }

    /// 先解压到空临时目录，再逐文件原子写入目标（可覆盖已存在文件）
    nonisolated static func installArchive(_ archive: URL, destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("cstf-install-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try fm.unzipItem(at: archive, to: staging)

        guard let entries = fm.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            throw AssetDownloadError.unzipFailed("无法读取解压资源")
        }

        var files: [(URL, URL)] = []
        let stagingPath = staging.standardizedFileURL.path
        for case let source as URL in entries {
            let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if attributes.isSymbolicLink == true {
                throw AssetDownloadError.unzipFailed("资源包含符号链接")
            }
            guard attributes.isRegularFile == true else { continue }

            let sourcePath = source.standardizedFileURL.path
            guard sourcePath.hasPrefix(stagingPath) else { continue }
            var relative = String(sourcePath.dropFirst(stagingPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            files.append((source, destination.appendingPathComponent(relative)))
        }

        for (source, target) in files {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: source)
            if (try? Data(contentsOf: target)) != data {
                try data.write(to: target, options: .atomic)
            }
        }
    }

    // MARK: - Story images

    nonisolated static func storyImageURL(bookId: String, storyId: String, imagePath: String? = nil) -> URL? {
        let root = DataLoader.shared.sandboxDataRoot
        var candidates: [URL] = []
        if let imagePath, !imagePath.isEmpty {
            var rel = imagePath
            if rel.hasPrefix("/") { rel.removeFirst() }
            candidates.append(root.appendingPathComponent(rel))
        }
        candidates.append(
            root.appendingPathComponent("story-images", isDirectory: true)
                .appendingPathComponent(bookId, isDirectory: true)
                .appendingPathComponent("\(storyId).jpg")
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Helpers

    private var cacheRoot: URL {
        dataRoot.deletingLastPathComponent()
    }

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func markExcludedFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try u.setResourceValues(values)
    }
}

// MARK: - URLSession progress download

private extension URLSession {
    func download(
        from url: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = self.downloadTask(with: url) { tmp, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let tmp, let resp else {
                    cont.resume(throwing: URLError(.badServerResponse)); return
                }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cstf-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: (dest, resp))
                } catch {
                    cont.resume(throwing: error)
                }
            }
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                progress(Int64(p.completedUnitCount), Int64(p.totalUnitCount))
            }
            objc_setAssociatedObject(task, &progressObservationKey, observation, .OBJC_ASSOCIATION_RETAIN)
            task.resume()
        }
    }
}

private var progressObservationKey: UInt8 = 0

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
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60  // 语文音频可达 60～100MB，给足时间
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

        if let entry = manifest?.books.first(where: { $0.bookId == bookId }),
           entry.audioRefCount == 0 || entry.audio.bytes <= 0 || entry.audio.sha256.isEmpty {
            audioReadyCache[bookId] = true
            return true
        }

        let filesOk = probeBookAudio(bookId)
        if FileManager.default.fileExists(atPath: audioMarkerURL(bookId).path), !filesOk {
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
            try await downloadBundle(
                bundle: entry.data,
                extractTo: dataRoot,
                weight: 0.2,
                phaseBase: 0.0,
                bookId: entry.bookId
            )
            bookProgress[entry.bookId] = 0.2

            let needAudio = entry.audioRefCount > 0
                && entry.audio.bytes > 0
                && !entry.audio.sha256.isEmpty

            if needAudio {
                try await downloadBundle(
                    bundle: entry.audio,
                    extractTo: audioRoot.deletingLastPathComponent(), // zip 内已有 audio/ 前缀
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
            let written = try Self.installArchive(tempURL, destination: destination)
            if written == 0 {
                throw AssetDownloadError.unzipFailed("解压结果为空（路径解析失败）")
            }
        } catch let e as AssetDownloadError {
            throw e
        } catch {
            throw AssetDownloadError.unzipFailed(String(describing: error))
        }
        try? FileManager.default.removeItem(at: tempURL)
    }

    /// 解压到临时目录后逐文件写入目标。
    /// 返回实际写入的文件数。关键：用 resolvingSymlinksInPath 消除 iOS /private 前缀差异。
    @discardableResult
    nonisolated static func installArchive(_ archive: URL, destination: URL) throws -> Int {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("cstf-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try fm.unzipItem(at: archive, to: staging)

        // 统一解析符号链接 /private 前缀，避免相对路径全部算丢
        let stagingResolved = staging.resolvingSymlinksInPath()
        let destResolved = destination.resolvingSymlinksInPath()

        guard let enumerator = fm.enumerator(
            at: stagingResolved,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AssetDownloadError.unzipFailed("无法枚举解压目录")
        }

        var written = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw AssetDownloadError.unzipFailed("资源包含符号链接")
            }
            guard values.isRegularFile == true else { continue }

            guard let relative = relativePath(from: stagingResolved, to: fileURL.resolvingSymlinksInPath()) else {
                continue
            }
            guard !relative.isEmpty else { continue }

            let target = destResolved.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            // 覆盖写入（不整文件读进内存比对，大音频包更稳）
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: fileURL, to: target)
            written += 1
        }

        if written == 0 {
            throw AssetDownloadError.unzipFailed("解压后未写入任何文件（路径前缀不匹配）")
        }
        return written
    }

    /// 安全计算相对路径，兼容 /var 与 /private/var
    nonisolated private static func relativePath(from base: URL, to file: URL) -> String? {
        let baseComponents = base.pathComponents
        let fileComponents = file.pathComponents
        guard fileComponents.count >= baseComponents.count else { return nil }
        for (i, c) in baseComponents.enumerated() {
            if fileComponents[i] != c { return nil }
        }
        let rel = fileComponents.dropFirst(baseComponents.count)
        return rel.isEmpty ? nil : rel.joined(separator: "/")
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
                    try? FileManager.default.removeItem(at: dest)
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

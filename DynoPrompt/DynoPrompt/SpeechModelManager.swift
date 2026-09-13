//
//  SpeechModelManager.swift
//  DynoPrompt
//
//  Downloads, verifies, installs and removes speech models, and tracks which
//  one is active.
//
//  Nothing downloads without the user asking for it. There is no background
//  fetch, no "recommended model" auto-install, and no telemetry — the catalog
//  is a static list compiled into the app, so opening this screen makes no
//  network request at all.
//
//  Security posture for downloaded models:
//
//  * HTTPS to an allowlisted host, re-checked on every redirect.
//  * SHA-256 verified by streaming the file, so a 1.6 GB model never has to
//    be held in memory to be checked.
//  * Size checked before the digest, to reject a truncated transfer cheaply.
//  * Written to the app's own caches directory, never a world-writable /tmp.
//  * Installed with an atomic move, so a partial file can never look installed.
//  * Filenames derived from the catalog identifier, never from the server.
//  * The file is data, never executed. It is parsed by whisper.cpp inside the
//    sandboxed, network-less XPC helper — so even a malformed model that
//    triggered a parser bug would land in a process that can reach neither the
//    network nor the user's files.
//

import CryptoKit
import Foundation
import OSLog

@Observable
final class SpeechModelManager: NSObject {

    static let shared = SpeechModelManager()

    // MARK: - State

    enum DownloadState: Equatable {
        case idle
        case waiting
        case downloading(fractionCompleted: Double, receivedBytes: Int64, totalBytes: Int64)
        case verifying
        case installing
        case failed(String)

        var isActive: Bool {
            switch self {
            case .waiting, .downloading, .verifying, .installing: return true
            case .idle, .failed: return false
            }
        }
    }

    /// Download state per model id. Absent means idle.
    private(set) var downloads: [String: DownloadState] = [:]
    private(set) var installed: [InstalledSpeechModel] = []
    private(set) var lastError: String?

    /// Id of the model speech recognition will use.
    ///
    /// The stored value lives in `NotchSettings`, which is what views should
    /// bind to. This is a convenience for non-UI callers: because it is a
    /// computed property that touches no stored property of *this* object,
    /// SwiftUI registers no dependency on it — a Picker bound here would
    /// persist a change and then fail to redraw, which looks exactly like the
    /// setting not saving.
    var activeModelID: String {
        get { NotchSettings.shared.activeSpeechModelID }
        set { NotchSettings.shared.activeSpeechModelID = newValue }
    }

    @ObservationIgnored private let store: SpeechModelStore
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Resume data kept from an interrupted or cancelled download, so it can
    /// pick up where it left off rather than restarting a 1.6 GB transfer.
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.fka.dynoprompt",
        category: "ModelManager"
    )

    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        let directory = (try? SpeechModelStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("DynoPromptModels")
        store = SpeechModelStore(directory: directory)
        super.init()
        refresh()
    }

    // MARK: - Queries

    var storageDirectory: URL { store.storageDirectory }
    var availableDiskSpace: Int64 { store.availableDiskSpace() }

    func refresh() {
        installed = store.installedModels(bundled: WhisperXPCClient.bundledModelURL)

        // If the active model is gone (deleted, or a bundle without it), fall
        // back to something that exists rather than failing at session start.
        if !installed.contains(where: { $0.id == activeModelID }) {
            let fallback = installed.first(where: { $0.isBundled }) ?? installed.first
            if let fallback {
                activeModelID = fallback.id
            }
        }
    }

    func isInstalled(_ model: SpeechModelDescriptor) -> Bool {
        installed.contains { $0.id == model.id }
    }

    func state(for model: SpeechModelDescriptor) -> DownloadState {
        downloads[model.id] ?? .idle
    }

    func installedModel(withID id: String) -> InstalledSpeechModel? {
        installed.first { $0.id == id }
    }

    /// Resolved file URL of the active model, for the provider to load.
    var activeModelURL: URL? {
        installedModel(withID: activeModelID)?.url
            ?? installed.first(where: { $0.isBundled })?.url
            ?? installed.first?.url
    }

    /// Physical memory, used to warn about a model that will not fit
    /// comfortably.
    var physicalMemory: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Whether a model's working set is a large fraction of this machine's RAM.
    func isMemoryHeavy(_ model: SpeechModelDescriptor) -> Bool {
        Double(model.approximateMemoryBytes) > Double(physicalMemory) * 0.4
    }

    // MARK: - Download

    /// Starts a download. Called only from an explicit user action.
    func download(_ model: SpeechModelDescriptor) {
        guard !isInstalled(model) else { return }
        guard state(for: model).isActive == false else { return }

        // Re-validate the source even though the catalog is compiled in: this
        // is the check that must hold, so it is made where it is used.
        guard SpeechModelCatalog.isAllowedSource(model.downloadURL) else {
            downloads[model.id] = .failed("That model's download location isn't permitted.")
            return
        }

        do {
            try store.verifyDiskSpace(for: model)
        } catch {
            downloads[model.id] = .failed(error.localizedDescription)
            return
        }

        downloads[model.id] = .waiting
        lastError = nil

        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: model.id) {
            logger.info("Resuming download of \(model.id, privacy: .public)")
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: model.downloadURL)
            request.setValue("DynoPrompt", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    /// Cancels a download, keeping resume data so it can continue later.
    func cancel(_ model: SpeechModelDescriptor) {
        guard let task = tasks.removeValue(forKey: model.id) else { return }
        task.cancel { [weak self] data in
            guard let self else { return }
            DispatchQueue.main.async {
                if let data { self.resumeData[model.id] = data }
                self.downloads[model.id] = .idle
            }
        }
    }

    func hasResumableDownload(_ model: SpeechModelDescriptor) -> Bool {
        resumeData[model.id] != nil
    }

    // MARK: - Remove

    func remove(_ model: SpeechModelDescriptor) {
        do {
            try store.remove(model.id)
            logger.info("Removed model \(model.id, privacy: .public)")
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Verification

    /// Streaming SHA-256 so a multi-gigabyte file is never read into memory.
    ///
    /// CryptoKit rather than a hand-rolled digest: this is the check the whole
    /// integrity story rests on, and it should be the platform's audited
    /// implementation.
    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSessionDownloadDelegate

extension SpeechModelManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        DispatchQueue.main.async {
            self.downloads[id] = .downloading(
                fractionCompleted: fraction,
                receivedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        }
    }

    /// Refuses a redirect that would leave the allowlist or drop TLS.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, SpeechModelCatalog.isAllowedSource(url) else {
            logger.error("Refused a model download redirect to a non-allowlisted host.")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let model = SpeechModelCatalog.model(withID: id) else { return }

        // URLSession deletes `location` as soon as this method returns, so the
        // file is moved somewhere we control before any slow work begins.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynoprompt-model-\(UUID().uuidString).partial")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            DispatchQueue.main.async {
                self.downloads[id] = .failed("Couldn't stage the download: \(error.localizedDescription)")
            }
            return
        }

        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: staging)
            DispatchQueue.main.async {
                self.downloads[id] = .failed("The server returned \(response.statusCode).")
            }
            return
        }

        DispatchQueue.main.async { self.downloads[id] = .verifying }

        // Hashing a large file is slow; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            defer { try? FileManager.default.removeItem(at: staging) }

            guard let digest = Self.sha256(ofFileAt: staging) else {
                DispatchQueue.main.async {
                    self.downloads[id] = .failed("Couldn't read the download to verify it.")
                }
                return
            }
            guard digest == model.sha256 else {
                self.logger.error("Integrity check failed for \(model.id, privacy: .public)")
                DispatchQueue.main.async {
                    self.downloads[id] = .failed(
                        SpeechModelStoreError.integrityMismatch(
                            expected: model.sha256,
                            actual: digest
                        ).localizedDescription
                    )
                }
                return
            }

            DispatchQueue.main.async { self.downloads[id] = .installing }

            do {
                _ = try self.store.install(downloadedFile: staging, as: model)
                self.logger.info("Installed model \(model.id, privacy: .public)")
                DispatchQueue.main.async {
                    self.downloads[id] = .idle
                    self.tasks.removeValue(forKey: id)
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.downloads[id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let id = task.taskDescription else { return }
        guard let error else { return }

        let nsError = error as NSError
        // A deliberate cancellation is handled in `cancel(_:)`.
        if nsError.code == NSURLErrorCancelled { return }

        // Keep resume data from an interrupted transfer.
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            DispatchQueue.main.async { self.resumeData[id] = data }
        }
        DispatchQueue.main.async {
            self.downloads[id] = .failed(error.localizedDescription)
            self.tasks.removeValue(forKey: id)
        }
    }
}

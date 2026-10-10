import AppKit
import CryptoKit
import Foundation

/// Online update service for BenchPilot Studio (the family pattern — see
/// taskly's UpdateService). Feed: the single self-contained signed manifest
/// wrapper (update-manifest.json — schema + base64 payload + Ed25519
/// signature block, the format rivet/distribution writes and the Studio
/// backend verifies); install: zip → sha256 → ditto → atomic in-place swap
/// of the running bundle.
///
/// Only a copy under /Applications (or ~/Applications) can self-update —
/// debug builds and random folders get the "not installed" answer.
@MainActor
public final class UpdateService {
    /// Ed25519 public key (base64, raw 32 bytes) — pair of the
    /// UPDATE_ED25519_PRIVATE_KEY GitHub secret that signs release
    /// manifests (generate: scripts/update-keys.sh).
    nonisolated public static let publicKeyBase64 = "Y9XFtUw8xo5RkiaAFoDQaI+AoyEmfy3NDJaUTCdfcCk="

    /// The manifest must carry this key id — rotation ships a build that
    /// trusts the next key before releases stop being signed with this one.
    nonisolated public static let expectedKeyID = "benchpilot-2026-10"

    public static let manifestURL = URL(string:
        "https://github.com/turinglambdaai/benchpilot/releases/latest/download/update-manifest.json")!
    public static let releasesPage = "https://github.com/turinglambdaai/benchpilot/releases/latest"

    public enum UpdateError: LocalizedError {
        case notInstalled
        case badPublicKey
        case manifestMissing
        case signatureInvalid
        case checksumMismatch
        case versionMismatch(expected: String, got: String)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "not an installed app bundle"
            case .badPublicKey: return "embedded public key is invalid"
            case .manifestMissing: return "release has no update manifest"
            case .signatureInvalid: return "manifest signature check failed"
            case .checksumMismatch: return "downloaded archive failed the sha256 check"
            case .versionMismatch(let expected, let got): return "bundle version \(got) ≠ manifest \(expected)"
            case .network(let message): return message
            }
        }
    }

    /// The signed wrapper: the inner manifest travels base64-encoded so the
    /// Ed25519 signature covers the exact bytes every client verifies
    /// (rivet/distribution's signed-wrapper format).
    struct SignedWrapper: Decodable {
        struct SignatureBlock: Decodable {
            let algorithm: String
            let keyId: String
            let value: String
        }
        let schema: Int
        let payload: String
        let signature: SignatureBlock
    }

    public struct Manifest: Decodable, Sendable {
        public struct Artifact: Decodable, Sendable {
            let platform: String
            let architecture: String
            let url: URL
            let sha256: String
            let size: Int
        }
        let version: String
        let artifacts: [Artifact]

        /// The release feed carries one artifact per platform × architecture;
        /// each built host targets exactly one architecture, so the match is
        /// compile-time ("x64" on Intel builds, "arm64" on Apple silicon).
        nonisolated static let hostArchitecture: String = {
            #if arch(x86_64)
            return "x64"
            #elseif arch(arm64)
            return "arm64"
            #else
            #error("unsupported macOS architecture")
            #endif
        }()

        func artifact(forPlatform platform: String) -> Artifact? {
            artifacts.first { $0.platform == platform
                && $0.architecture == Self.hostArchitecture }
        }
    }

    private var session: URLSession
    /// Manifest endpoint; injectable only for tests (URLProtocol stubs)
    /// — production callers use the default.
    private let feedURL: URL
    /// Test seams for the runtime environment; nil = derive from Bundle.main.
    private let injectedBundleURL: URL?
    private let injectedCurrentVersion: String?
    /// Test-only embedded-key override (release env signs with the real key).
    nonisolated private let injectedKeyBase64: String?

    init(feedURL: URL? = nil,
         bundleURL: URL? = nil,
         currentVersion: String? = nil,
         sessionConfiguration: URLSessionConfiguration? = nil,
         keyOverride: String? = nil) {
        let config = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
        self.feedURL = feedURL ?? Self.manifestURL
        self.injectedBundleURL = bundleURL
        self.injectedCurrentVersion = currentVersion
        self.injectedKeyBase64 = keyOverride
    }

    // MARK: - Environment

    /// The installed bundle this copy can update in place, or nil for
    /// development copies (not under /Applications or ~/Applications).
    public var installedBundleURL: URL? {
        if let injectedBundleURL { return injectedBundleURL }
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app"), path.hasPrefix("/Applications/")
            || path.hasPrefix("/Users/") && path.contains("/Applications/") else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    public var canUpdate: Bool { installedBundleURL != nil }

    private var currentVersion: String {
        injectedCurrentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0"
    }

    // MARK: - Check

    /// Result of a completed check.
    public enum CheckResult {
        case upToDate
        case available(Manifest)
    }

    /// Fetches the latest release manifest, verifies its Ed25519 signature
    /// and compares versions. Throws with a precise reason otherwise
    /// (presentation — silent swallow vs error dialog — is the caller's job).
    public func check() async throws -> CheckResult {
        guard installedBundleURL != nil else {
            throw UpdateError.notInstalled
        }
        let manifest = try await fetchSignedManifest()
        if Self.isVersion(manifest.version, greaterThan: currentVersion) {
            return .available(manifest)
        }
        return .upToDate
    }

    private func fetchSignedManifest() async throws -> Manifest {
        guard let (data, response) = try? await session.data(from: feedURL) else {
            throw UpdateError.network("update check failed")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try Self.verifyManifest(data, keyBase64: injectedKeyBase64)
    }

    // MARK: - Pure steps (unit-tested)

    /// Verifies the signed wrapper (schema, key id, Ed25519 over the exact
    /// payload bytes) and decodes the inner manifest.
    nonisolated static func verifyManifest(_ wrapperBytes: Data,
                                           keyBase64: String? = nil) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wrapper: SignedWrapper
        do {
            wrapper = try decoder.decode(SignedWrapper.self, from: wrapperBytes)
        } catch {
            throw UpdateError.manifestMissing
        }
        guard wrapper.schema == 1 else { throw UpdateError.manifestMissing }
        guard wrapper.signature.algorithm == "ed25519",
              wrapper.signature.keyId == expectedKeyID else {
            throw UpdateError.signatureInvalid
        }
        guard let payload = Data(base64Encoded: wrapper.payload),
              let signature = Data(base64Encoded: wrapper.signature.value) else {
            throw UpdateError.signatureInvalid
        }
        guard signature.count == 64 else { throw UpdateError.signatureInvalid }
        guard let keyData = Data(base64Encoded: keyBase64 ?? publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw UpdateError.badPublicKey
        }
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw UpdateError.signatureInvalid
        }
        do {
            return try decoder.decode(Manifest.self, from: payload)
        } catch {
            throw UpdateError.network("manifest unparsable")
        }
    }

    // MARK: - Download + install

    /// Downloads, verifies (sha256, then unpacked bundle version), swaps the
    /// bundle in place and relaunches. Throws before touching the running
    /// install when anything is off. `onProgress` reports download percent
    /// (0…100) on the main actor for the update sheet.
    public func downloadAndInstall(_ manifest: Manifest,
                                   onProgress: (@Sendable (Int) -> Void)? = nil) async throws {
        guard let bundleURL = installedBundleURL else { throw UpdateError.notInstalled }
        guard let artifact = manifest.artifact(forPlatform: "macos") else {
            throw UpdateError.manifestMissing
        }
        try await Self.downloadAndSwap(artifact: artifact,
                                       bundleURL: bundleURL,
                                       expectedVersion: manifest.version,
                                       onProgress: onProgress ?? { _ in })
    }

    /// The whole download → verify → swap sequence, deliberately off the
    /// main actor: consuming AsyncBytes on the main actor starves the
    /// transfer (every element hops through the main executor, the
    /// connection stalls and URLSession times out — the taskly family
    /// observed this live against the GitHub CDN). The work itself is a
    /// static @Sendable function touching no UI state; progress hops back
    /// through the @Sendable callback the caller provided.
    nonisolated private static func downloadAndSwap(
        artifact: Manifest.Artifact,
        bundleURL: URL,
        expectedVersion: String,
        onProgress: @Sendable (Int) -> Void
    ) async throws {
        // Download to a temp directory.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchpilot-studio-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let zipURL = workDir.appendingPathComponent("benchpilot-studio-update.zip")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)

        do {
            let (bytes, response) = try await session.bytes(from: artifact.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.network("artifact download failed")
            }
            var hasher = SHA256()
            var data = Data()
            data.reserveCapacity(artifact.size)
            let total = max(artifact.size, 1)
            var lastPercent = -1
            // Consume AsyncBytes through a 64 KiB buffer: hashing/appending
            // per byte (tens of millions of CryptoKit calls) is far slower
            // than the wire.
            var buffer = [UInt8]()
            buffer.reserveCapacity(65_536)
            func absorb(_ chunk: [UInt8]) {
                hasher.update(data: chunk)
                data.append(contentsOf: chunk)
                let percent = min(100, data.count * 100 / total)
                if percent != lastPercent {
                    lastPercent = percent
                    onProgress(percent)
                }
            }
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == buffer.capacity
                    || data.count + buffer.count >= total {
                    absorb(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                // The signed manifest pins the exact size — stop as soon as
                // we have it. Waiting for the stream's own EOF can hang
                // forever on responses whose end-of-stream flag never
                // surfaces to AsyncBytes.
                if data.count >= total { break }
            }
            if !buffer.isEmpty { absorb(buffer) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == artifact.sha256.lowercased() else {
                throw UpdateError.checksumMismatch
            }
            try data.write(to: zipURL)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }

        // Unzip and verify the payload really is the promised version.
        let unpacked = workDir.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.checksumMismatch }

        let newBundle = unpacked.appendingPathComponent("benchpilot-studio.app")
        guard let newVersion = Bundle(url: newBundle)?
            .infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw UpdateError.versionMismatch(expected: expectedVersion, got: "missing")
        }
        guard newVersion == expectedVersion else {
            throw UpdateError.versionMismatch(expected: expectedVersion, got: newVersion)
        }

        // Swap: the shell script survives our exit; it also restores the
        // old bundle if the new one fails to move in. The resident
        // benchpilotd and ~/.benchpilot are never touched — Studio is only
        // its own bundle.
        let old = bundleURL.path + ".old"
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf \(q(old))
        if mv \(q(bundleURL.path)) \(q(old)); then
          if mv \(q(newBundle.path)) \(q(bundleURL.path)); then
            open \(q(bundleURL.path))
            rm -rf \(q(old))
            exit 0
          fi
          mv \(q(old)) \(q(bundleURL.path))
        fi
        exit 1
        """
        let swapPath = workDir.appendingPathComponent("swap.sh")
        try script.write(to: swapPath, atomically: true, encoding: .utf8)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", swapPath.path]
        try chmod.run()
        chmod.waitUntilExit()

        // Launch the swap, then leave through the normal exit path so
        // AppKit tears the app down cleanly; the script's sleep 1 gives us
        // time to quit before it moves the bundle.
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = [swapPath.path]
        try bash.run()
        await MainActor.run { NSApplication.shared.terminate(nil) }
    }

    nonisolated private static func q(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Version compare (numeric per segment; 0.10 > 0.9)

    nonisolated public static func isVersion(_ a: String, greaterThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        let length = max(av.count, bv.count)
        for i in 0..<length {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

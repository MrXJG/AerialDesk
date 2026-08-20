import AppKit
import AVFoundation
import Foundation

enum AerialPreviewSource: String {
    case apple = "Apple 系统预览图"
    case generated = "从本地视频生成"
    case unavailable = "暂无预览图"
}

@MainActor
final class AerialPreviewProvider {
    static let shared = AerialPreviewProvider()

    private let imageCache = NSCache<NSString, NSImage>()
    private var pendingCallbacks: [String: [(NSImage?, AerialPreviewSource) -> Void]] = [:]

    private var thumbnailDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AERIALDESK_THUMBNAIL_DIR"],
           !override.isEmpty {
            return URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            )
        }
        return aerialDeskSupportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private init() {
        imageCache.countLimit = 180
    }

    func loadPreview(
        for item: AerialCatalogItem,
        completion: @escaping (NSImage?, AerialPreviewSource) -> Void
    ) {
        let appleURL = systemManifestDirectory.appendingPathComponent("\(item.id).png")
        let appleKey = "apple:\(item.id)"
        if let cached = imageCache.object(forKey: appleKey as NSString) {
            completion(cached, .apple)
            return
        }
        if let image = NSImage(contentsOf: appleURL) {
            imageCache.setObject(image, forKey: appleKey as NSString)
            completion(image, .apple)
            return
        }

        guard let videoURL = AerialCatalog.shared.videoURL(forID: item.id) else {
            completion(nil, .unavailable)
            return
        }

        let modificationDate = (try? videoURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let cacheKey = "video:\(item.id):\(Int(modificationDate))"
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            completion(cached, .generated)
            return
        }

        let cacheURL = cachedThumbnailURL(for: item.id)
        if isThumbnailCurrent(cacheURL: cacheURL, videoURL: videoURL),
           let image = NSImage(contentsOf: cacheURL) {
            imageCache.setObject(image, forKey: cacheKey as NSString)
            completion(image, .generated)
            return
        }

        if pendingCallbacks[cacheKey] != nil {
            pendingCallbacks[cacheKey]?.append(completion)
            return
        }
        pendingCallbacks[cacheKey] = [completion]

        let thumbnailDirectory = thumbnailDirectory
        Task.detached(priority: .utility) {
            let generated = await Self.generateThumbnail(
                videoURL: videoURL,
                cacheURL: cacheURL,
                thumbnailDirectory: thumbnailDirectory
            )
            await MainActor.run {
                let provider = AerialPreviewProvider.shared
                let image = generated ? NSImage(contentsOf: cacheURL) : nil
                if let image {
                    provider.imageCache.setObject(image, forKey: cacheKey as NSString)
                }
                let callbacks = provider.pendingCallbacks.removeValue(forKey: cacheKey) ?? []
                for callback in callbacks {
                    callback(image, image == nil ? .unavailable : .generated)
                }
            }
        }
    }

    private func cachedThumbnailURL(for id: String) -> URL {
        let allowed = CharacterSet.alphanumerics
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? "video"
        return thumbnailDirectory.appendingPathComponent("\(encoded.prefix(180)).jpg")
    }

    private func isThumbnailCurrent(cacheURL: URL, videoURL: URL) -> Bool {
        guard let cacheDate = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
              let videoDate = (try? videoURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else {
            return false
        }
        return cacheDate >= videoDate
    }

    private nonisolated static func generateThumbnail(
        videoURL: URL,
        cacheURL: URL,
        thumbnailDirectory: URL
    ) async -> Bool {
        let asset = AVURLAsset(url: videoURL)
        let loadedDuration = try? await asset.load(.duration)
        let duration = loadedDuration.map(CMTimeGetSeconds) ?? 0
        let seconds = duration.isFinite && duration > 1 ? min(max(duration * 0.2, 1), 30) : 1
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 390)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)

        do {
            let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImageAsynchronously(for: requestedTime) { image, _, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? NSError(
                            domain: "AerialDeskPreview",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "无法从视频生成预览图"]
                        ))
                    }
                }
            }
            let representation = NSBitmapImageRep(cgImage: cgImage)
            guard let data = representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.82]
            ) else {
                return false
            }
            try FileManager.default.createDirectory(
                at: thumbnailDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

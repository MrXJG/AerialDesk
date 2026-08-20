import CoreFoundation
import Foundation
import IOKit.ps

let appName = "AerialDesk"

let systemVideoDirectory = URL(
    fileURLWithPath: NSString(
        string: "~/Library/Application Support/com.apple.wallpaper/aerials/videos"
    ).expandingTildeInPath,
    isDirectory: true
)

let downloadedManifestDirectory = URL(
    fileURLWithPath: NSString(
        string: "~/Library/Application Support/com.apple.wallpaper/aerials/manifest"
    ).expandingTildeInPath,
    isDirectory: true
)

let systemManifestDirectory = URL(
    fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources",
    isDirectory: true
)

let aerialDeskSupportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/AerialDesk", isDirectory: true)

let aerialDeskVideoDirectory = aerialDeskSupportDirectory
    .appendingPathComponent("Videos", isDirectory: true)

extension Notification.Name {
    static let aerialDeskDownloadsChanged = Notification.Name("AerialDeskDownloadsChanged")
}

struct AerialName: Hashable {
    let chinese: String?
    let english: String?

    var displayName: String? {
        if let chinese, let english, chinese != english {
            return "\(chinese)（\(english)）"
        }
        return chinese ?? english
    }
}

struct AerialCatalogItem: Hashable {
    let id: String
    let name: AerialName
    let categoryID: String
    let categoryName: AerialName
    let subcategoryIDs: [String]
    let remoteURL: URL?

    var displayName: String {
        name.displayName ?? id
    }

    var categoryDisplayName: String {
        categoryName.displayName ?? "其他（Other）"
    }
}

private struct AerialManifest: Decodable {
    let assets: [AerialManifestAsset]
    let categories: [AerialManifestCategory]
}

private struct AerialManifestAsset: Decodable {
    let id: String
    let accessibilityLabel: String?
    let localizedNameKey: String?
    let categories: [String]?
    let subcategories: [String]?
    let remoteURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case accessibilityLabel
        case localizedNameKey
        case categories
        case subcategories
        case remoteURL = "url-4K-SDR-240FPS"
    }
}

private struct AerialManifestCategory: Decodable {
    let id: String
    let localizedNameKey: String?
}

final class AerialCatalog {
    static let shared = AerialCatalog()

    private(set) var items: [AerialCatalogItem] = []
    private(set) var namesByID: [String: AerialName] = [:]

    private init() {
        reload()
    }

    func reload() {
        var resolvedItems: [String: AerialCatalogItem] = [:]
        var resolvedNames: [String: AerialName] = [:]
        var resolvedCategories: [String: AerialName] = [:]

        let sources = [
            (
                manifest: systemManifestDirectory.appendingPathComponent("entries.json"),
                bundle: systemManifestDirectory.appendingPathComponent("TVIdleScreenStrings.bundle")
            ),
            (
                manifest: downloadedManifestDirectory.appendingPathComponent("entries.json"),
                bundle: downloadedManifestDirectory.appendingPathComponent("TVIdleScreenStrings.bundle")
            )
        ]

        for source in sources {
            guard let data = try? Data(contentsOf: source.manifest),
                  let manifest = try? JSONDecoder().decode(AerialManifest.self, from: data) else {
                continue
            }

            let localizationBundle = CFBundleCreate(kCFAllocatorDefault, source.bundle as CFURL)

            for category in manifest.categories {
                let previous = resolvedCategories[category.id]
                let localized = resolveName(
                    key: category.localizedNameKey,
                    englishFallback: previous?.english,
                    bundle: localizationBundle
                )
                resolvedCategories[category.id] = AerialName(
                    chinese: localized.chinese ?? previous?.chinese,
                    english: localized.english ?? previous?.english
                )
            }

            for asset in manifest.assets {
                let previousName = resolvedNames[asset.id]
                let localized = resolveName(
                    key: asset.localizedNameKey,
                    englishFallback: asset.accessibilityLabel ?? previousName?.english,
                    bundle: localizationBundle
                )
                let name = AerialName(
                    chinese: localized.chinese ?? previousName?.chinese,
                    english: localized.english ?? previousName?.english
                )
                resolvedNames[asset.id] = name

                guard let remoteURL = asset.remoteURL ?? resolvedItems[asset.id]?.remoteURL else {
                    continue
                }

                let categoryID = asset.categories?.first
                    ?? resolvedItems[asset.id]?.categoryID
                    ?? "other"
                let categoryName = resolvedCategories[categoryID]
                    ?? resolvedItems[asset.id]?.categoryName
                    ?? AerialName(chinese: "其他", english: "Other")

                resolvedItems[asset.id] = AerialCatalogItem(
                    id: asset.id,
                    name: name,
                    categoryID: categoryID,
                    categoryName: categoryName,
                    subcategoryIDs: asset.subcategories ?? resolvedItems[asset.id]?.subcategoryIDs ?? [],
                    remoteURL: remoteURL
                )
            }
        }

        let localCategory = AerialName(chinese: "本地视频", english: "Local Videos")
        for video in videoFiles() {
            let id = video.deletingPathExtension().lastPathComponent
            guard resolvedItems[id] == nil else { continue }
            let name = AerialName(chinese: id, english: nil)
            resolvedNames[id] = name
            resolvedItems[id] = AerialCatalogItem(
                id: id,
                name: name,
                categoryID: "local-videos",
                categoryName: localCategory,
                subcategoryIDs: [],
                remoteURL: nil
            )
        }

        namesByID = resolvedNames
        items = resolvedItems.values.sorted {
            if $0.categoryDisplayName != $1.categoryDisplayName {
                return $0.categoryDisplayName.localizedStandardCompare($1.categoryDisplayName) == .orderedAscending
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func name(for video: URL?) -> AerialName? {
        guard let id = video?.deletingPathExtension().lastPathComponent else { return nil }
        return namesByID[id]
    }

    func displayName(for video: URL?) -> String {
        if let name = name(for: video)?.displayName {
            return name
        }
        return video?.deletingPathExtension().lastPathComponent ?? "无视频"
    }

    func videoFiles() -> [URL] {
        if let override = ProcessInfo.processInfo.environment["AERIALDESK_VIDEO_DIR"], !override.isEmpty {
            return videoFiles(in: [
                URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
            ])
        }
        return videoFiles(in: [systemVideoDirectory, aerialDeskVideoDirectory])
    }

    func downloadedIDs() -> Set<String> {
        Set(videoFiles().map { $0.deletingPathExtension().lastPathComponent })
    }

    func videoURL(forID id: String) -> URL? {
        videoFiles().first { $0.deletingPathExtension().lastPathComponent == id }
    }

    func averageDownloadedVideoBytes() -> Int64? {
        let sizes: [Int64] = videoFiles().compactMap { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return Int64(size)
        }
        guard !sizes.isEmpty else { return nil }
        return sizes.reduce(0, +) / Int64(sizes.count)
    }

    private func videoFiles(in directories: [URL]) -> [URL] {
        let supported = Set(["mov", "mp4", "m4v"])
        var byID: [String: URL] = [:]

        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in files {
                guard supported.contains(url.pathExtension.lowercased()) else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                if byID[id] == nil {
                    byID[id] = url
                }
            }
        }

        return byID.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func resolveName(
        key: String?,
        englishFallback: String?,
        bundle: CFBundle?
    ) -> AerialName {
        guard #available(macOS 15.4, *), let key, let bundle else {
            return AerialName(chinese: nil, english: englishFallback)
        }
        return AerialName(
            chinese: localizedString(key: key, localization: "zh_CN", bundle: bundle),
            english: localizedString(key: key, localization: "en", bundle: bundle) ?? englishFallback
        )
    }

    @available(macOS 15.4, *)
    private func localizedString(key: String, localization: String, bundle: CFBundle) -> String? {
        let value = CFBundleCopyLocalizedStringForLocalizations(
            bundle,
            key as CFString,
            key as CFString,
            "Localizable.nocache" as CFString,
            [localization] as CFArray
        ) as String
        return value == key || value.isEmpty ? nil : value
    }
}

func currentPowerSourceName() -> String {
    if let forced = ProcessInfo.processInfo.environment["AERIALDESK_FORCE_POWER"] {
        if forced.caseInsensitiveCompare("AC") == .orderedSame { return "AC Power" }
        if forced.caseInsensitiveCompare("Battery") == .orderedSame { return "Battery Power" }
    }

    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
        return "Unknown"
    }
    return source
}

func isOnACPower() -> Bool {
    currentPowerSourceName() == (kIOPSACPowerValue as String)
}

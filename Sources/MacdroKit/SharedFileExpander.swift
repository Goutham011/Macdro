import Foundation

public enum SharedFileExpander {
    public static func expand(urls: [URL]) -> [SharedFile] {
        var results: [SharedFile] = []
        let fileManager = FileManager.default

        for url in urls {
            let normalized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalized.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                results.append(contentsOf: expandDirectory(normalized, fileManager: fileManager))
            } else if let file = makeFile(url: normalized, relativePath: normalized.lastPathComponent) {
                results.append(file)
            }
        }

        return results
    }

    public static func makeFile(url: URL, relativePath: String) -> SharedFile? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return nil
        }

        let size = UInt64(max(0, values.fileSize ?? 0))
        return SharedFile(
            sourcePath: url.path,
            relativePath: relativePath,
            size: size,
            modifiedAt: values.contentModificationDate ?? Date()
        )
    }

    private static func expandDirectory(_ directory: URL, fileManager: FileManager) -> [SharedFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let rootPrefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let rootName = directory.lastPathComponent
        var files: [SharedFile] = []

        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                continue
            }

            let childPath = child.standardizedFileURL.path
            guard childPath.hasPrefix(rootPrefix) else { continue }
            let relative = String(childPath.dropFirst(rootPrefix.count))
            let displayPath = rootName.isEmpty ? relative : rootName + "/" + relative
            if let file = makeFile(url: child, relativePath: displayPath) {
                files.append(file)
            }
        }

        return files
    }
}

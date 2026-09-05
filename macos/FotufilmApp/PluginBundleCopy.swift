import Foundation

/// Stages signed bundles and Motion templates with ditto before replacing an installation.
enum PluginBundleCopy {
    static func install(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".fotufilm-install-\(UUID().uuidString)")
        var existingParent = parent
        while !manager.fileExists(atPath: existingParent.path),
              existingParent.path != "/" {
            existingParent.deleteLastPathComponent()
        }

        if manager.isWritableFile(atPath: existingParent.path) {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staged) }
            try run("/usr/bin/ditto", [source.path, staged.path])
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: staged, to: destination)
        } else {
            let script = """
            on run argv
                set sourcePath to quoted form of item 1 of argv
                set destinationPath to quoted form of item 2 of argv
                set parentPath to quoted form of item 3 of argv
                set stagedPath to quoted form of item 4 of argv
                set command to "/bin/mkdir -p " & parentPath & " && /usr/bin/ditto " & sourcePath & " " & stagedPath & " && /bin/rm -rf " & destinationPath & " && /bin/mv " & stagedPath & " " & destinationPath & "; result=$?; /bin/rm -rf " & stagedPath & "; exit $result"
                do shell script command with administrator privileges
            end run
            """
            try run("/usr/bin/osascript",
                    ["-e", script, source.path, destination.path, parent.path, staged.path])
        }
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        throw Failure(detail: String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? {
            detail.isEmpty ? "The plug-in could not be installed." : detail
        }
    }
}

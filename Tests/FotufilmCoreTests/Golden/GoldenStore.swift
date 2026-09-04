import Foundation

enum GoldenStore {
    enum Visibility: String {
        case published
        case calibrated
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
    }

    static func url(visibility: Visibility, chart: String,
                    stock: String) -> URL {
        root.appendingPathComponent(visibility.rawValue, isDirectory: true)
            .appendingPathComponent(chart, isDirectory: true)
            .appendingPathComponent("\(stock).png")
    }

    enum Mode {
        case check
        case update

        static var current: Mode {
            ProcessInfo.processInfo.environment["FOTUFILM_GOLDEN"] == "update"
                ? .update : .check
        }
    }

    static func read(visibility: Visibility, chart: String,
                     stock: String) throws -> RGBAImage? {
        let url = url(visibility: visibility, chart: chart, stock: stock)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try RGBAImage.read(url)
    }

    static func write(_ image: RGBAImage, visibility: Visibility,
                      chart: String, stock: String) throws {
        let url = url(visibility: visibility, chart: chart, stock: stock)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try image.pngData().write(to: url)
    }

    static var reviewDirectory: URL {
        if let path = ProcessInfo.processInfo
            .environment["FOTUFILM_GOLDEN_REVIEW"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/golden-review", isDirectory: true)
    }
}

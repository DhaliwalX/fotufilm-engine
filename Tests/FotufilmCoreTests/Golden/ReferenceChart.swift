import Foundation
@testable import FotufilmCore

struct ReferenceChart {
    let name: String
    let width: Int
    let height: Int
    let image: ImageBuffer
    let zones: [String]
    let purpose: String

    static var all: [ReferenceChart] {
        [colorChecker, stepWedge, gamut, spatial] + userSupplied()
    }

    static var colorChecker: ReferenceChart {
        let patches: [(UInt8, UInt8, UInt8)] = [
            (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67),
            (133, 128, 177), (103, 189, 170),
            (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108),
            (157, 188, 64), (224, 163, 46),
            (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31),
            (187, 86, 149), (8, 133, 161),
            (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121),
            (85, 85, 85), (52, 52, 52),
        ]
        let names = [
            "dark skin", "light skin", "blue sky", "foliage", "blue flower",
            "bluish green", "orange", "purplish blue", "moderate red", "purple",
            "yellow green", "orange yellow", "blue", "green", "red", "yellow",
            "magenta", "cyan", "white", "neutral 8", "neutral 6.5", "neutral 5",
            "neutral 3.5", "black",
        ]
        return grid(name: "colorchecker", columns: 6, rows: 4, cell: 24,
                    purpose: "ColorChecker Classic 24 — skin, foliage, sky, "
                    + "primaries and the grey axis") { index in
            let p = patches[index]
            return (linear(p.0), linear(p.1), linear(p.2),
                    zone(names[index], index: index))
        }
    }

    static var stepWedge: ReferenceChart {
        let brightest: Float = 4.0
        return grid(name: "stepwedge", columns: 7, rows: 3, cell: 24,
                    purpose: "21-step wedge, 0.15 density per step (Stouffer "
                    + "T2115 geometry) — the D-logE sweep, ~10 stops") { index in
            let density = 0.15 * Float(index)
            let value = brightest * pow(10, -density)
            let label = String(format: "D %.2f", density)
            return (value, value, value, zone(label, index: index))
        }
    }

    static var gamut: ReferenceChart {
        let rows: [[(Float, Float, Float)]] = [
            [(0.92, 0.04, 0.04), (0.04, 0.92, 0.04), (0.04, 0.04, 0.92),
             (0.04, 0.84, 0.84), (0.84, 0.04, 0.84), (0.84, 0.84, 0.04),
             (0.92, 0.30, 0.04), (0.30, 0.04, 0.92)],
            [(0.23, 0.01, 0.01), (0.01, 0.23, 0.01), (0.01, 0.01, 0.23),
             (0.01, 0.21, 0.21), (0.21, 0.01, 0.21), (0.21, 0.21, 0.01),
             (0.23, 0.08, 0.01), (0.08, 0.01, 0.23)],
            [(0.88, 0.67, 0.58), (0.73, 0.50, 0.41), (0.52, 0.32, 0.24),
             (0.31, 0.18, 0.14), (0.79, 0.58, 0.46), (0.61, 0.40, 0.31),
             (0.43, 0.26, 0.20), (0.21, 0.12, 0.09)],
            [(3.90, 3.90, 3.90), (2.20, 2.20, 2.20), (3.90, 3.10, 1.90),
             (1.90, 3.10, 3.90), (3.90, 1.20, 0.40), (0.40, 3.90, 1.20),
             (1.20, 0.40, 3.90), (1.40, 1.40, 1.40)],
        ]
        let labels = ["saturated", "saturated dim", "skin", "specular"]
        return grid(name: "gamut", columns: 8, rows: 4, cell: 24,
                    purpose: "Saturated fields, a skin ladder and speculars — "
                    + "couplers, adjacency, shoulder and halation") { index in
            let row = index / 8, column = index % 8
            let p = rows[row][column]
            return (p.0, p.1, p.2, zone(labels[row], index: row))
        }
    }

    static var spatial: ReferenceChart {
        let side = 128
        var buffer = ImageBuffer(width: side, height: side)
        var zones = [String](repeating: "", count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let index = y * side + x
                var rgb: (Float, Float, Float)
                var zone: String
                switch y / 32 {
                case 0:
                    zone = "hard edge"
                    let bright = x >= side / 2
                    let value: Float = bright ? 6.0 : 0.02
                    rgb = (value, value, value)
                case 1:
                    zone = "colour edge"
                    rgb = x >= side / 2 ? (5.0, 0.6, 0.1) : (0.03, 0.05, 0.12)
                case 2:
                    zone = "detail"
                    let period = max(1, 16 - (x * 15) / (side - 1))
                    let on = ((x / period) % 2) == 0
                    let value: Float = on ? 0.85 : 0.06
                    rgb = (value, value, value)
                default:
                    zone = "specular point"
                    let cx = (x % 32) - 16, cy = (y % 32) - 16
                    let radius = (Float(cx * cx + cy * cy)).squareRoot()
                    let value: Float = radius < 3 ? 12.0 : 0.28
                    rgb = (value, value, value)
                }
                buffer.planes[0][index] = rgb.0
                buffer.planes[1][index] = rgb.1
                buffer.planes[2][index] = rgb.2
                zones[index] = zone
            }
        }
        return ReferenceChart(
            name: "spatial", width: side, height: side, image: buffer,
            zones: zones,
            purpose: "Edges, a resolution sweep and isolated speculars — "
            + "halation, adjacency and the modulation transfer")
    }

    static var referencesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("References", isDirectory: true)
    }

    static func userSupplied() -> [ReferenceChart] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: referencesDirectory,
            includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let image = try? RGBAImage.read(url) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return ReferenceChart(
                    name: name, width: image.width, height: image.height,
                    image: image.sceneLinear,
                    zones: [String](repeating: "whole frame",
                                    count: image.width * image.height),
                    purpose: "Supplied reference picture")
            }
    }

    private static func linear(_ code: UInt8) -> Float {
        ColorScience.srgbToLinear(Float(code) / 255)
    }

    private static func zone(_ label: String, index: Int) -> String {
        String(format: "%02d %@", index, label)
    }

    private static func grid(
        name: String, columns: Int, rows: Int, cell: Int, purpose: String,
        patch: (Int) -> (Float, Float, Float, String)
    ) -> ReferenceChart {
        let width = columns * cell, height = rows * cell
        var buffer = ImageBuffer(width: width, height: height)
        var zones = [String](repeating: "", count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y / cell) * columns + (x / cell)
                let (r, g, b, label) = patch(index)
                let offset = y * width + x
                buffer.planes[0][offset] = r
                buffer.planes[1][offset] = g
                buffer.planes[2][offset] = b
                zones[offset] = label
            }
        }
        return ReferenceChart(name: name, width: width, height: height,
                              image: buffer, zones: zones, purpose: purpose)
    }
}

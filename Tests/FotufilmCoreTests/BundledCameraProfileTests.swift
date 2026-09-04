import XCTest
@testable import FotufilmCore

final class BundledCameraProfileTests: XCTestCase {
    // MARK: Loading

    func testBundledProfilesLoadWithUniqueIDsAndReachTheStore() {
        let profiles = CameraSpectralProfileStore.bundledProfiles
        // Pinned to the shipped dataset — rawtoaces-data e9b8503 carries 52 cameras. A drop
        // means files stopped parsing or the resource directory fell out of the bundle; a rise
        // means the dataset was refreshed and this pin should move with it.
        XCTAssertEqual(profiles.count, 52)
        XCTAssertEqual(Set(profiles.map(\.id)).count, profiles.count, "ids must be unique")
        for profile in profiles {
            XCTAssertNotNil(profile.make, profile.id)
            XCTAssertNotNil(profile.model, profile.id)
            // Lazy loading means plain lookup must find every bundled id with no app-side
            // registration ceremony.
            XCTAssertEqual(CameraSpectralProfileStore.profile(id: profile.id)?.id, profile.id)
        }
    }

    func testSonyProfileResolvesThroughCameraIdentity() {
        // The A7 III ships as make "Sony", model "ILCE-7M3" — the exact strings a raw file's
        // metadata carries — so identity resolution is the path real photographs take.
        let resolved = CameraSpectralProfileStore.resolve(
            CameraIdentity(make: "Sony", model: "ILCE-7M3"))
        XCTAssertEqual(resolved?.id, "sony-ilce-7m3")
        XCTAssertEqual(resolved?.make, "Sony")
        XCTAssertEqual(resolved?.model, "ILCE-7M3")
        // Metadata casing varies by writer; resolution must not care.
        XCTAssertEqual(CameraSpectralProfileStore.resolve(
            CameraIdentity(make: "SONY", model: "ilce-7m3"))?.id, "sony-ilce-7m3")
        // And the explicit-id path finds the same profile.
        XCTAssertEqual(CameraSpectralProfileStore.profile(id: "sony-ilce-7m3")?.model,
                       "ILCE-7M3")
    }

    func testVendorPaddedIdentitiesResolve() {
        // What raw files actually carry differs from the dataset headers: a D5100 records
        // make "NIKON CORPORATION" and model "NIKON D5100", where the Academy header says
        // "Nikon" / "D5100". Resolution must see through the legalese and the repeated brand.
        XCTAssertEqual(CameraSpectralProfileStore.resolve(
            CameraIdentity(make: "NIKON CORPORATION", model: "NIKON D5100"))?.id,
                       "nikon-d5100")
        // Canon repeats the brand in the model while the make is already bare.
        XCTAssertEqual(CameraSpectralProfileStore.resolve(
            CameraIdentity(make: "Canon", model: "Canon EOS 5DS"))?.id,
                       "canon-eos-5ds")
        // A brand with no model beyond the brand itself still resolves to nothing.
        XCTAssertNil(CameraSpectralProfileStore.resolve(
            CameraIdentity(make: "NIKON CORPORATION", model: "NIKON")))
    }

    // MARK: Physical sanity of every shipped curve

    func testEveryBundledProfileHasPositiveSensitivityIntegrals() {
        let profiles = CameraSpectralProfileStore.bundledProfiles
        XCTAssertFalse(profiles.isEmpty)
        for profile in profiles {
            for (channel, name) in ["red", "green", "blue"].enumerated() {
                let integral = profile.sensitivity[channel].reduce(0, +)
                XCTAssertGreaterThan(integral, 0, "\(profile.id) \(name)")
            }
        }
    }

    func testEveryBundledProfilePeaksInSpectralOrder() {
        for profile in CameraSpectralProfileStore.bundledProfiles {
            func peak(_ channel: Int) -> Float {
                var best = 0
                for i in 1..<SpectralGrid.count
                where profile.sensitivity[channel][i] > profile.sensitivity[channel][best] {
                    best = i
                }
                return SpectralGrid.wavelengths[best]
            }
            let red = peak(0), green = peak(1), blue = peak(2)
            XCTAssertGreaterThan(red, green, "\(profile.id): red \(red), green \(green)")
            XCTAssertGreaterThan(green, blue, "\(profile.id): green \(green), blue \(blue)")
        }
    }

    // MARK: Matrix derivation on every shipped curve

    func testEveryBundledProfileDualIlluminantAnchorsAreSoundAndDistinct() {
        var smallestGap = Float.greatestFiniteMagnitude
        var largestGap: Float = 0
        var smallestID = "", largestID = ""
        for profile in CameraSpectralProfileStore.bundledProfiles {
            let anchors = profile.dualIlluminantMatrices()
            // Each anchor solve pins its rows to sum 1, so camera white must land on P3
            // white to within ulps of that division — under both lights.
            for (matrix, name) in [(anchors.tungsten, "tungsten"),
                                   (anchors.daylight, "daylight")] {
                for row in 0..<3 {
                    let sum = matrix[row].x + matrix[row].y + matrix[row].z
                    XCTAssertEqual(sum, 1, accuracy: 1e-6, "\(profile.id) \(name) row \(row)")
                }
            }
            // The anchors must genuinely differ: a real camera's correction shifts between
            // 2856 K and 6504 K, and identical anchors would mean the illuminant never
            // reached the solve. Measured over the shipped dataset the largest-element gap
            // runs 0.251 (Nikon D200) to 0.778 (ARRI D21); 0.05 sits 5x under the measured
            // floor, so it fails on a collapse without flaking on a legitimate refresh.
            var gap: Float = 0
            for row in 0..<3 {
                for column in 0..<3 {
                    gap = max(gap, abs(anchors.tungsten[row][column]
                                       - anchors.daylight[row][column]))
                }
            }
            XCTAssertGreaterThan(gap, 0.05, "\(profile.id) anchors nearly identical")
            if gap < smallestGap { smallestGap = gap; smallestID = profile.id }
            if gap > largestGap { largestGap = gap; largestID = profile.id }
        }
        print("bundled camera anchor gaps: min \(smallestGap) (\(smallestID)), "
              + "max \(largestGap) (\(largestID))")
    }
}

import AppKit

/// `--verify-update-feed`: the rules a feed document is judged by, against fabricated ones, and
/// — with an argument — one real document read and judged against this build.
///
///   --verify-update-feed                     the rules only
///   --verify-update-feed=<file or URL>       the rules, then the document at that path
///
/// The Mac app has no test target — `macos/build.sh` compiles it flat — so this is the shape a
/// check takes here, the same as `--verify-plugin-install`: do the thing, read the answer back,
/// print PASS or FAIL, exit. Release day can point it at the uploaded permalink and see what
/// every installed app will decide about it.
enum VerifyUpdateFeed {
    static func runIfRequested() {
        guard let argument = CommandLine.arguments.first(
            where: { $0.hasPrefix("--verify-update-feed") }) else { return }

        var failures = 0
        func expect(_ condition: Bool, _ what: String) {
            print("\(condition ? "  ok  " : "  FAIL") \(what)")
            if !condition { failures += 1 }
        }

        let digest64 = String(repeating: "a", count: 64)
        let pkg = "https://github.com/DhaliwalX/fotufilm-downloads/releases/latest/download/Fotufilm-macOS.pkg"

        // The rules. Validation refuses a document the app must not act on; the comparison is
        // the decision of whether the feed names a release worth walking the user to.
        print("the feed rules")
        func decode(_ json: String) -> UpdateManifest? {
            try? JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        }
        let good = """
        {"version": "1.7", "build": "9", "downloadURL": "\(pkg)", "sha256": "\(digest64)"}
        """
        func validates(_ json: String) -> Bool {
            guard let manifest = decode(json) else { return false }
            return (try? manifest.validate()) != nil
        }
        expect(validates(good), "a complete document validates")
        expect(decode(good)?.releaseNotes == nil, "release notes stay optional")

        func rejects(_ json: String, _ what: String) {
            guard let manifest = decode(json) else {
                expect(false, "\(what) is refused")
                return
            }
            expect((try? manifest.validate()) == nil, "\(what) is refused")
        }
        rejects(good.replacingOccurrences(of: "\"1.7\"", with: "\"\""), "an empty version")
        rejects(good.replacingOccurrences(of: "\"9\"", with: "\"\""), "an empty build")
        rejects(good.replacingOccurrences(of: pkg, with: "Fotufilm-macOS.pkg"),
                "a relative download address")
        rejects(good.replacingOccurrences(
            of: digest64, with: String(repeating: "a", count: 63)), "a short digest")
        rejects(good.replacingOccurrences(
            of: digest64, with: String(repeating: "g", count: 64)), "a non-hex digest")

        expect(decode(good)?.isNewer(thanVersion: "1.5", build: "99") == true,
               "a newer release is an update even from a higher build")
        expect(decode(good)?.isNewer(thanVersion: "1.7", build: "9") == false,
               "the same release is not an update")
        expect(decode(good.replacingOccurrences(of: "\"1.7\"", with: "\"1.4\""))?
            .isNewer(thanVersion: "1.5", build: "1") == false,
               "an older release is never an update")

        // A real document, if one was named. A local path is read; anything with a scheme is
        // fetched, so the uploaded permalink can be checked exactly as an installed app
        // receives it.
        let target: String? = {
            guard let index = argument.firstIndex(of: "=") else { return nil }
            return String(argument[argument.index(after: index)...])
        }()
        if let target, !target.isEmpty {
            print("the feed document")
            do {
                let data = try read(target)
                guard let manifest = decode(String(decoding: data, as: UTF8.self)) else {
                    throw UpdateCheck.UpdateCheckError.unreadableFeed
                }
                try manifest.validate()
                expect(true, "the document decodes and validates")
                let newer = manifest.isNewer(
                    thanVersion: UpdateCheck.currentVersion, build: UpdateCheck.currentBuild)
                print("       feed names \(manifest.version) (build \(manifest.build)); "
                      + "this build is \(UpdateCheck.currentRelease)")
                print("       this build would be told an update is available: "
                      + "\(newer ? "yes" : "no")")

                // The package itself, if `--download` was asked: the same download the app's
                // "Download and Install" performs, judged byte for byte against the digest the
                // document publishes. Release day can check a feed and its package before any
                // installed app ever sees them.
                if CommandLine.arguments.contains("--download") {
                    print("the package")
                    let semaphore = DispatchSemaphore(value: 0)
                    var downloadError: Error?
                    var digestMatches = false
                    Task {
                        defer { semaphore.signal() }
                        do {
                            let file = try await UpdateCheck.downloadPackage(
                                from: manifest.download!,
                                onProgress: { _, _ in })
                            defer { try? FileManager.default.removeItem(at: file) }
                            let digest = try UpdateCheck.sha256Hex(of: file)
                            digestMatches = digest == manifest.normalizedSHA256
                        } catch {
                            downloadError = error
                        }
                    }
                    semaphore.wait()
                    expect(downloadError == nil,
                           "the package downloads (\(downloadError.map(String.init(describing:)) ?? "ok"))")
                    expect(digestMatches,
                           "the downloaded package matches the published digest")
                }
            } catch {
                print("  FAIL \(error)")
                failures += 1
            }
        }

        print(failures == 0 ? "PASS" : "FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    private static func read(_ target: String) throws -> Data {
        if FileManager.default.fileExists(atPath: target) {
            return try Data(contentsOf: URL(fileURLWithPath: target))
        }
        guard let url = URL(string: target), url.scheme != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        var data: Data?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { fetched, _, error in
            data = fetched
            failure = error
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let data { return data }
        throw failure ?? UpdateCheck.UpdateCheckError.unreadableFeed
    }
}

import AppKit

/// `--verify-plugin-install`: checks what the app is prepared to install and the rule it installs
/// by. Copies are made only under a temporary directory.
///
/// The Mac app has no test target — `macos/build.sh` compiles it flat — so this is the shape a
/// check takes here, the same as `--verify-parity` and `--verify-peek`: do the thing, read the
/// answer back, print PASS or FAIL, exit.
///
/// It deliberately does not install into `/Applications` or `/Library`. Authorization does not
/// belong in a build-machine check, so the copy path is exercised under a writable temporary root.
enum VerifyPluginInstall {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--verify-plugin-install") else { return }

        var failures = 0
        func expect(_ condition: Bool, _ what: String) {
            print("\(condition ? "  ok  " : "  FAIL") \(what)")
            if !condition { failures += 1 }
        }

        // The rule, against fabricated versions. This is the part with a decision in it, and the
        // only part that can be asked a question it has not already been given the answer to.
        print("the install rule")
        expect(PluginVersion.needsInstall(bundled: nil, installed: nil) == false,
               "a build carrying no plug-in installs nothing")
        expect(PluginVersion.needsInstall(bundled: nil, installed: "6") == false,
               "a build carrying no plug-in leaves an installed one alone")
        expect(PluginVersion.needsInstall(bundled: "6", installed: nil),
               "nothing installed wants installing")
        expect(PluginVersion.needsInstall(bundled: "6", installed: "6") == false,
               "the same version is left alone")
        expect(PluginVersion.needsInstall(bundled: "7", installed: "6"),
               "an older installed plug-in is replaced")
        // The one worth spelling out: a plug-in newer than the app is as wrong as one older, and
        // the answer is to put this build's plug-in back rather than to leave the newer one.
        expect(PluginVersion.needsInstall(bundled: "6", installed: "7"),
               "a newer installed plug-in is replaced too")

        // What this copy of the app actually carries, and whether it is stamped in step with the
        // app itself. A plug-in stamped with a different number from the app that ships it would
        // make every launch offer an update that changes nothing.
        print("this build")
        let appVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        expect(appVersion != nil, "the app knows its own version")

        for (name, bundled, installed) in [
            ("DaVinci Resolve", OFXPluginInstaller.bundledURL, OFXPluginInstaller.installedURL),
            ("Final Cut Pro", FxPlugInstaller.bundledURL, FxPlugInstaller.installedURL),
        ] {
            guard let bundled else {
                // Not a failure. A build made without the FxPlug SDK carries no Final Cut plug-in
                // by design, and `macos/build.sh` reports it when it happens.
                print("  --   \(name): this build carries no plug-in")
                continue
            }
            let version = PluginVersion.of(bundled)
            expect(version != nil, "\(name): the bundled plug-in is stamped with a version")
            expect(version == appVersion,
                   "\(name): the bundled plug-in is stamped with the app's own version")
            print("       \(name): bundled \(version ?? "—"), "
                   + "installed \(PluginVersion.of(installed) ?? "none")")
        }

        // Resolve's system directory is normally writable by administrator accounts. This is the
        // no-prompt path: replace an existing copy and preserve the bundle.
        if let source = OFXPluginInstaller.bundledURL {
            print("installing Resolve plug-in")
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("fotufilm-ofx-install-\(UUID().uuidString)",
                                        isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appendingPathComponent(OFXPluginInstaller.bundleName,
                                                              isDirectory: true)
                try FileManager.default.createDirectory(at: destination,
                                                        withIntermediateDirectories: true)
                let stale = destination.appendingPathComponent("stale-file")
                try Data("old installation".utf8).write(to: stale)
                try OFXPluginInstaller.install(from: source, to: destination)
                expect(Bundle(url: destination)?.bundleIdentifier
                           == OFXPluginInstaller.bundleIdentifier,
                       "the Resolve plug-in arrived intact")
                expect(PluginVersion.of(destination) == PluginVersion.of(source),
                       "the Resolve plug-in kept the bundled version")
                expect(!FileManager.default.fileExists(atPath: stale.path),
                       "the previous installation was replaced")
                let leftovers = (try? FileManager.default.contentsOfDirectory(
                    atPath: root.path))?.filter { $0.hasPrefix(".") } ?? []
                expect(leftovers.isEmpty, "the Resolve install left no staging directory")
            } catch {
                print("  FAIL Resolve install: \(error.localizedDescription)")
                failures += 1
            }
        }

        // The install itself, if a wrapper to install was named. Everything above decides whether
        // to install; this is the part that does it — the copy, the atomic move onto the
        // destination, the verification, and the launch that registers the extension with macOS.
        // It runs against a temporary directory rather than /Applications, so it needs no password
        // and leaves nothing behind.
        if let index = CommandLine.arguments.firstIndex(of: "--with-wrapper"),
           index + 1 < CommandLine.arguments.count {
            let source = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            print("installing")
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("fotufilm-install-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appendingPathComponent(FxPlugInstaller.appName,
                                                              isDirectory: true)
                try FxPlugInstaller.install(from: source, to: destination)
                expect(FileManager.default.fileExists(atPath: destination.path),
                       "the wrapper arrived at the destination")
                expect(Bundle(url: destination)?.bundleIdentifier
                           == FxPlugInstaller.bundleIdentifier,
                       "the installed wrapper reads back as the wrapper")
                expect(PluginVersion.of(destination) == PluginVersion.of(source),
                       "the installed wrapper carries the version it was built with")
                if let bundledTemplate = FxPlugInstaller.motionTemplateURL(in: destination) {
                    let templateDestination = root
                        .appendingPathComponent("Movies", isDirectory: true)
                        .appendingPathComponent("Motion Templates.localized", isDirectory: true)
                        .appendingPathComponent("Effects.localized", isDirectory: true)
                        .appendingPathComponent("Fotufilm.localized", isDirectory: true)
                        .appendingPathComponent("Fotufilm.localized", isDirectory: true)
                    try FxPlugInstaller.installMotionTemplate(
                        from: bundledTemplate, to: templateDestination)
                    expect(FileManager.default.fileExists(atPath: templateDestination
                        .appendingPathComponent("Fotufilm.moef").path),
                           "the Final Cut Motion template was installed")
                    expect(FileManager.default.fileExists(atPath: templateDestination
                        .appendingPathComponent("small.png").path),
                           "the Final Cut browser preview was installed")
                } else {
                    expect(false, "the wrapper carries a complete Motion template")
                }
                // Nothing staged is left over: a half-copy under a dot-name would be invisible in
                // Finder and would accumulate one per failed install.
                let leftovers = (try? FileManager.default.contentsOfDirectory(
                    atPath: root.path))?.filter { $0.hasPrefix(".") } ?? []
                expect(leftovers.isEmpty, "no staging directory is left behind")
                // install() launches the wrapper with --register and waits for it to exit. It
                // throws if registration or termination fails.
                expect(true, "the wrapper registered with macOS and quit again")
            } catch {
                print("  FAIL install: \(error.localizedDescription)")
                failures += 1
            }
        }

        print(failures == 0 ? "PASS" : "FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}

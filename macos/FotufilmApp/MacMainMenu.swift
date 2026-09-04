import AppKit

/// The menu bar, built by hand.
///
/// Every item here targets nil, which sends it down the responder chain to whichever object is
/// prepared to answer — the editor for the edit, the app delegate for the plug-in. That is also
/// what greys them out: an object that does not implement an action never receives it, and an
/// object that does gets asked in `validateMenuItem` whether it can do it right now.
///
/// Two submenus are not written down here at all. The films and the recent files are both lists
/// that change while the app is running, so each has a delegate that builds it the moment it is
/// pulled down — the alternative is a menu that is right at launch and wrong by lunchtime.
enum MainMenu {
    static func build(isActivated: Bool) -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenu(isActivated: isActivated))
        guard isActivated else {
            main.addItem(windowMenu())
            main.addItem(helpMenu())
            return main
        }
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(filmMenu())
        main.addItem(viewMenu())
        main.addItem(pluginsMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        return main
    }

    private static func submenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    /// One item, with the modifiers spelled out rather than inferred.
    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                            key: String = "",
                            modifiers: NSEvent.ModifierFlags = .command,
                            tag: Int = 0) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action,
                                keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.tag = tag
        return item
    }

    private static func applicationMenu(isActivated: Bool) -> NSMenuItem {
        let (item, menu) = submenu("Fotufilm")
        menu.addItem(withTitle: "About Fotufilm",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        // Available before activation too: an unactivated copy is an installed copy, and it is
        // the one most likely to be behind.
        add(menu, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        add(menu, "Check for Updates Automatically",
            #selector(AppDelegate.toggleAutomaticUpdateChecks(_:)))
        menu.addItem(.separator())
        if isActivated {
            add(menu, "Settings…",
                #selector(DesktopEditorViewController.openSettings(_:)), key: ",")
            add(menu, "License…", #selector(AppDelegate.openLicense(_:)))
        } else {
            add(menu, "Activate Fotufilm…", #selector(AppDelegate.openLicense(_:)))
        }
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil,
                                      keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide Fotufilm",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Fotufilm",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let (item, menu) = submenu("File")
        add(menu, "Open…", #selector(DesktopEditorViewController.openDocument(_:)),
            key: "o")

        let (recentItem, recentMenu) = submenu("Open Recent")
        recentMenu.delegate = recentDocuments
        menu.addItem(recentItem)

        add(menu, "Use Sample Photo",
            #selector(DesktopEditorViewController.loadSamplePhoto(_:)))
        menu.addItem(.separator())
        add(menu, "Import Film Pack…", #selector(AppDelegate.importFilmPack(_:)),
            key: "i", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Export…",
            #selector(DesktopEditorViewController.exportDocument(_:)), key: "e")
        menu.addItem(.separator())
        add(menu, "Close Photo",
            #selector(DesktopEditorViewController.closePhoto(_:)),
            key: "w", modifiers: [.command, .shift])
        add(menu, "Close Window", #selector(NSWindow.performClose(_:)), key: "w")
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu("Edit")
        add(menu, "Undo", #selector(DesktopEditorViewController.performUndo(_:)),
            key: "z")
        add(menu, "Redo", #selector(DesktopEditorViewController.performRedo(_:)),
            key: "z", modifiers: [.command, .shift])
        let (historyItem, history) = submenu("Edit History")
        history.delegate = editHistory
        menu.addItem(historyItem)
        menu.addItem(.separator())
        add(menu, "Auto Adjust",
            #selector(DesktopEditorViewController.toggleAutoAdjust(_:)),
            key: "a", modifiers: [.command, .shift])
        add(menu, "Sample a Selection",
            #selector(DesktopEditorViewController.sampleSelection(_:)),
            key: "s", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), key: "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), key: "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), key: "v")
        add(menu, "Select All", #selector(NSText.selectAll(_:)), key: "a")
        menu.addItem(.separator())
        add(menu, "Copy Photo",
            #selector(DesktopEditorViewController.copyPhoto(_:)),
            key: "c", modifiers: [.command, .shift])
        return item
    }

    private static func filmMenu() -> NSMenuItem {
        let (item, menu) = submenu("Film")

        let (choose, films) = submenu("Choose Film")
        films.delegate = filmList
        menu.addItem(choose)
        menu.addItem(.separator())

        add(menu, "New Grain Pattern",
            #selector(DesktopEditorViewController.rerollGrain(_:)),
            key: "g", modifiers: [.command, .shift])
        add(menu, "Disc Grain (Advanced)",
            #selector(DesktopEditorViewController.toggleDiscGrain(_:)))
        add(menu, "Estimated Halation Shape (Advanced)",
            #selector(DesktopEditorViewController.toggleEstimatedHalation(_:)))
        menu.addItem(.separator())
        add(menu, "Film Workshop…",
            #selector(DesktopEditorViewController.openFilmWorkshop(_:)),
            key: "n", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Choose Film Per Photo",
            #selector(DesktopEditorViewController.toggleAutoStock(_:)))
        add(menu, "Forget What I've Taught It",
            #selector(DesktopEditorViewController.forgetLearning(_:)))
        menu.addItem(.separator())
        add(menu, "Reset All Edits",
            #selector(DesktopEditorViewController.resetAllEdits(_:)),
            key: "r", modifiers: [.command, .shift])
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu("View")
        // Use ⌘+ because the menu displays characters and AppKit does not remap an unhandled ⌘=.
        add(menu, "Zoom In", #selector(DesktopEditorViewController.zoomIn(_:)),
            key: "+")
        add(menu, "Zoom Out", #selector(DesktopEditorViewController.zoomOut(_:)),
            key: "-")
        add(menu, "Zoom to Fit",
            #selector(DesktopEditorViewController.zoomToFit(_:)), key: "0")
        menu.addItem(.separator())
        add(menu, "Show Original",
            #selector(DesktopEditorViewController.toggleShowOriginal(_:)),
            key: "\\")
        // ⌥⌘N rather than ⇧⌘N, which the Film Workshop already has.
        add(menu, "Show Negative",
            #selector(DesktopEditorViewController.toggleShowNegative(_:)),
            key: "n", modifiers: [.command, .option])
        add(menu, "Show Histogram",
            #selector(DesktopEditorViewController.toggleHistogram(_:)),
            key: "h", modifiers: [.command, .control])
        // Named "Play" here and renamed on the way down by the editor, which is the only object
        // that knows whether the clip is running.
        add(menu, "Play", #selector(DesktopEditorViewController.togglePlayback(_:)))
        menu.addItem(.separator())
        add(menu, "Film Stocks",
            #selector(DesktopEditorViewController.toggleStockSidebar(_:)),
            key: "s", modifiers: [.command, .control])
        add(menu, "Inspector",
            #selector(DesktopEditorViewController.toggleInspectorPanel(_:)),
            key: "i", modifiers: [.command, .option])
        // The tabs, numbered the way they are stacked, in a group of their own — "Film Stocks"
        // above is the left-hand column, and "Film" here is a tab in the right-hand one. The tag is
        // the panel's place in `InspectorPanel.allCases`: a menu item cannot carry an enumeration,
        // and it can carry an integer.
        menu.addItem(.separator())
        for (index, panel) in InspectorPanel.allCases.enumerated() {
            add(menu, panel.title,
                #selector(DesktopEditorViewController.chooseInspectorPanel(_:)),
                key: String(index + 1), tag: index)
        }
        menu.addItem(.separator())
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)),
            key: "f", modifiers: [.command, .control])
        return item
    }

    private static func pluginsMenu() -> NSMenuItem {
        let (item, menu) = submenu("Plugins")
        menu.addItem(resolveMenu())
        menu.addItem(finalCutMenu())
        return item
    }

    private static func resolveMenu() -> NSMenuItem {
        let (item, menu) = submenu("DaVinci Resolve")
        menu.addItem(withTitle: "Install Fotufilm Plug-in…",
                     action: #selector(AppDelegate.installOFXPlugin(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Show Installed Plug-in in Finder",
                     action: #selector(AppDelegate.showOFXPluginInFinder(_:)),
                     keyEquivalent: "")
        return item
    }

    private static func finalCutMenu() -> NSMenuItem {
        let (item, menu) = submenu("Final Cut Pro")
        menu.addItem(withTitle: "Install Fotufilm Plug-in…",
                     action: #selector(AppDelegate.installFxPlugPlugin(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Show Installed Plug-in in Finder",
                     action: #selector(AppDelegate.showFxPlugPluginInFinder(_:)),
                     keyEquivalent: "")
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu("Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let (item, menu) = submenu("Help")
        add(menu, "Fotufilm Help", #selector(AppDelegate.openHelp(_:)), key: "?")
        menu.addItem(.separator())
        add(menu, "Third-Party Notices", #selector(AppDelegate.openNotices(_:)))
        add(menu, "Terms of Use", #selector(AppDelegate.openTerms(_:)))
        add(menu, "Privacy Policy", #selector(AppDelegate.openPrivacy(_:)))
        NSApp.helpMenu = menu
        return item
    }

    private static let filmList = FilmListDelegate()
    private static let recentDocuments = RecentDocumentsDelegate()
    private static let editHistory = EditHistoryMenuDelegate()
}

/// Builds the phone's selectable edit timeline as a native desktop submenu. Undo and redo remain
/// the fast path; this is the way to inspect the whole session and jump more than one step.
private final class EditHistoryMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let editor = activeEditor, editor.model.isOpen else {
            let empty = menu.addItem(withTitle: "No Open Edit", action: nil,
                                     keyEquivalent: "")
            empty.isEnabled = false
            return
        }

        let states = editor.model.history
        for (index, state) in states.enumerated() {
            let title = index == 0 ? "Opened"
                : Self.title(from: states[index - 1], to: state)
            let item = menu.addItem(
                withTitle: title,
                action: #selector(DesktopEditorViewController.goToEditHistory(_:)),
                keyEquivalent: "")
            item.target = editor
            item.representedObject = index
            item.state = index == editor.model.historyIndex ? .on : .off
        }
    }

    private var activeEditor: DesktopEditorViewController? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            + NSApp.windows
        return windows.lazy.compactMap {
            $0.contentViewController as? DesktopEditorViewController
        }.first
    }

    private static func title(from old: EditState, to new: EditState) -> String {
        if new.stockID != old.stockID {
            return FilmChoice.name(for: new.stockID)
        }
        if new.chosenFormatID != old.chosenFormatID { return "Film Format" }
        if new.crop != old.crop || new.rotation != old.rotation
            || new.flipH != old.flipH || new.straighten != old.straighten
            || new.perspectiveV != old.perspectiveV
            || new.perspectiveH != old.perspectiveH {
            return "Crop & Rotate"
        }
        if new.lensFilterIDs != old.lensFilterIDs
            || new.lensFilterMetering != old.lensFilterMetering {
            return "Lens Filters"
        }
        if new.lensSettings != old.lensSettings { return "Lens Correction" }
        if new.sourceInterpretation != old.sourceInterpretation {
            return "Source Interpretation"
        }
        if new.exposure != old.exposure || new.highlights != old.highlights
            || new.shadows != old.shadows || new.localTone != old.localTone {
            return "Light"
        }
        if new.temperatureMired != old.temperatureMired || new.tint != old.tint {
            return "Undertone"
        }
        if new.saturation != old.saturation || new.vibrance != old.vibrance {
            return "Color"
        }
        if new.grain != old.grain || new.grainMottleShare != old.grainMottleShare
            || new.discGrain != old.discGrain {
            return "Grain"
        }
        if new.halation != old.halation
            || new.halationColour != old.halationColour
            || new.halationSpectrum != old.halationSpectrum {
            return "Halation"
        }
        if new.couplers != old.couplers
            || new.couplerGapReach != old.couplerGapReach
            || new.couplerSelf != old.couplerSelf {
            return "Couplers"
        }
        if new.push != old.push || new.bleach != old.bleach
            || new.expiredYears != old.expiredYears
            || new.shutterSeconds != old.shutterSeconds {
            return "Lab"
        }
        if new.grade != old.grade || new.encodedGrade != old.encodedGrade {
            return "Grade"
        }
        if new.paper != old.paper || new.paperFollowsStock != old.paperFollowsStock {
            return "Output Medium"
        }
        if new.printLightKelvin != old.printLightKelvin {
            return "Viewing Illuminant"
        }
        if new.printCorrection != old.printCorrection {
            return "Channel Contrast Match"
        }
        return "Edit"
    }
}

/// Builds the film list on the way down.
///
/// The films are not fixed: a pack imported or a film saved in the workshop changes what the list
/// should say, and the menu is the one surface with no view to reload.
private final class FilmListDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for choice in FilmChoice.editorWall {
            let item = menu.addItem(
                withTitle: choice.name,
                action: #selector(DesktopEditorViewController.chooseFilm(_:)),
                keyEquivalent: "")
            // The id, not the name: two packs may name a film the same thing, and the editor
            // stores the id.
            item.representedObject = choice.id
            if !choice.subtitle.isEmpty { item.toolTip = choice.subtitle }
        }
    }
}

/// The files opened lately, kept by the app itself.
///
/// `NSDocumentController` keeps this list for document apps and would also put it in the Dock's
/// menu, but reaching for it installs a document controller in the responder chain, and a document
/// controller answers `openDocument:` — which this app already answers for itself, differently.
/// The list is small enough to keep by hand and worth the independence.
enum RecentFiles {
    private static let key = "RecentDocuments"
    private static let limit = 10

    static var urls: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        // Filtered on the way out rather than on the way in: a file is renamed or thrown away long
        // after it was opened, and a menu should not offer what is no longer there.
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func note(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Builds the recent files on the way down, from the list above.
private final class RecentDocumentsDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentFiles.urls
        for url in urls {
            let item = menu.addItem(
                withTitle: url.lastPathComponent,
                action: #selector(AppDelegate.openRecentDocument(_:)),
                keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        if urls.isEmpty {
            let empty = menu.addItem(withTitle: "No Recent Files", action: nil,
                                     keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu",
                     action: #selector(AppDelegate.clearRecentDocuments(_:)),
                     keyEquivalent: "")
    }
}

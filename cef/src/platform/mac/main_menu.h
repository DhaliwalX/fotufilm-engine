// The menu bar: the native Mac app's (macos/FotufilmApp/MacMainMenu.swift), item for item where the
// web editor has the action. Items target nil, so each reaches whichever object answers it: the
// host view for text editing, the host window for the editor's commands (validated against the
// state the editor reports), the application delegate for files and help.
#pragma once

#import <Cocoa/Cocoa.h>

// Actions the menu sends down the responder chain.
@protocol FotufilmMenuActions
// Runs the editor command named by the item's representedObject (web/src/editor/useNativeCommands.js).
- (void)performEditorCommand:(id)sender;
- (void)openRecentFile:(id)sender;
- (void)useSamplePhoto:(id)sender;
// File › Import Film Pack…: an open panel for .fotufilmpack files, which the editor installs.
- (void)importFilmPack:(id)sender;
- (void)clearRecentFiles:(id)sender;
// Opens the fotufilm.com page named by the item's representedObject.
- (void)openHelpPage:(id)sender;
// The items the editor lists for a submenu it fills itself ("films"), as {command, title} pairs.
- (NSArray<NSArray<NSString*>*>*)editorMenuItems:(NSString*)menu;
@end

// What the Edit menu shows of the editor's history, answered by the object that runs its
// commands. Edit History lists the steps and runs "history:<step>" to go to one.
@protocol FotufilmEditHistory
// Every step of the shown photograph's history, oldest first, named as the Mac app names them;
// empty when no photograph is open.
- (NSArray<NSString*>*)editHistoryTitles;
@end


// `plugins` are the engine's `capabilities.plugins`, `{id, name}` each: a Plugins menu lists them
// as the Mac app's does, and there is none without them.
NSMenu* FotufilmMainMenu(NSArray<NSDictionary*>* plugins);

// Files opened lately, kept by the app itself as the Mac app keeps them (`RecentFiles`).
@interface FotufilmRecentFiles : NSObject
// The files still where they were, newest first.
+ (NSArray<NSURL*>*)URLs;
// Film packs are not noted: they are installed, not opened.
+ (void)note:(NSURL*)url;
+ (void)clear;
@end

// Whether a menu item has `event` as its key equivalent, enabled or not.
BOOL FotufilmMenuHasKeyEquivalent(NSMenu* menu, NSEvent* event);

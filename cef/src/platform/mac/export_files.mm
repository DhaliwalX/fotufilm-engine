#import "platform/mac/export_files.h"

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

namespace fotufilm {
namespace {

// The files this app has saved since launch, the only ones "openExport" opens.
NSMutableSet<NSString*>* Saved() {
  static NSMutableSet<NSString*>* saved = [NSMutableSet set];
  return saved;
}

NSString* FolderKey(bool movie) {
  return movie ? @"FotufilmMovieExportFolder" : @"FotufilmPhotoExportFolder";
}

// The folder this kind of export was last saved to, while it is still there; Movies or Pictures
// otherwise.
NSURL* StartingFolder(bool movie) {
  NSString* last = [NSUserDefaults.standardUserDefaults stringForKey:FolderKey(movie)];
  BOOL directory = NO;
  if (last && [NSFileManager.defaultManager fileExistsAtPath:last isDirectory:&directory] &&
      directory)
    return [NSURL fileURLWithPath:last isDirectory:YES];
  return [NSFileManager.defaultManager
             URLsForDirectory:movie ? NSMoviesDirectory : NSPicturesDirectory
                    inDomains:NSUserDomainMask]
      .firstObject;
}

}  // namespace

void ChooseExportDestination(const std::string& filename, const std::string& type,
                             const std::string& fixed_directory,
                             std::function<void(const std::string&)> done) {
  auto chosen = [done](NSString* path) {
    if (path.length) [Saved() addObject:path.stringByStandardizingPath];
    done(path.length ? path.UTF8String : "");
  };
  if (!fixed_directory.empty())
    return chosen(@((fixed_directory + "/" + filename).c_str()));
  const bool movie = type.rfind("video/", 0) == 0;
  NSSavePanel* panel = [NSSavePanel savePanel];
  panel.nameFieldStringValue = @(filename.c_str());
  panel.directoryURL = StartingFolder(movie);
  if (UTType* uti = [UTType typeWithMIMEType:@(type.c_str())])
    panel.allowedContentTypes = @[ uti ];
  auto finish = ^(NSModalResponse response) {
    NSURL* url = response == NSModalResponseOK ? panel.URL : nil;
    if (url)
      [NSUserDefaults.standardUserDefaults
          setObject:url.URLByDeletingLastPathComponent.path
             forKey:FolderKey(movie)];
    chosen(url.path);
  };
  if (NSWindow* window = NSApp.mainWindow)
    [panel beginSheetModalForWindow:window completionHandler:finish];
  else
    finish([panel runModal]);
}

void RegisterExportFiles(Dispatcher& dispatcher) {
  dispatcher.Register(
      "openExport", Dispatcher::Thread::kUi, [](const Call& call, std::shared_ptr<Reply> reply) {
        CefRefPtr<CefDictionaryValue> fields =
            call.params && call.params->GetType() == VTYPE_DICTIONARY
                ? call.params->GetDictionary()
                : nullptr;
        NSString* path = fields ? @(fields->GetString("path").ToString().c_str()) : @"";
        path = path.stringByStandardizingPath;
        if (![Saved() containsObject:path])
          return reply->Reject("Only a file this app saved can be opened.");
        if (![NSFileManager.defaultManager fileExistsAtPath:path])
          return reply->Reject("The file is no longer where it was saved.");
        NSURL* url = [NSURL fileURLWithPath:path];
        if (fields->GetBool("reveal"))
          [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ url ]];
        else
          [NSWorkspace.sharedWorkspace openURL:url];
        reply->Resolve(nullptr);
      });
}

}  // namespace fotufilm

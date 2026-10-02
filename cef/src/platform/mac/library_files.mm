#import "platform/mac/library_files.h"

#import <Cocoa/Cocoa.h>

namespace fotufilm {

LibraryFileActions MacLibraryFileActions() {
  LibraryFileActions actions;
  actions.reveal = [](const std::vector<std::string>& paths) {
    NSMutableArray<NSURL*>* urls = [NSMutableArray array];
    for (const std::string& path : paths)
      [urls addObject:[NSURL fileURLWithPath:@(path.c_str())]];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
    return true;
  };
  actions.trash = [](const std::string& path, std::string& error) {
    NSError* failure = nil;
    if ([NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:@(path.c_str())]
                                    resultingItemURL:nil
                                               error:&failure])
      return true;
    error = failure.localizedDescription.UTF8String ?: "";
    return false;
  };
  return actions;
}

}  // namespace fotufilm

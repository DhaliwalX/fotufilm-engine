#ifndef RUNNER_WINDOW_CHANNEL_H_
#define RUNNER_WINDOW_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The window's side of lib/app/host_window.dart ("fotufilm/window"), as the Mac runner's
// WindowChannel answers it: the title, the size scripted checks set, the sample photo, recent
// files, and showing, opening and trashing files through the desktop.
void window_channel_register(FlView* view, GtkWindow* window, GtkHeaderBar* header_bar);

#endif  // RUNNER_WINDOW_CHANNEL_H_

#include "window_channel.h"

#include <gio/gio.h>

#include <string>
#include <vector>

namespace {

struct Window {
  GtkWindow* window;
  GtkHeaderBar* header_bar;
};

std::vector<std::string> Strings(FlValue* arguments) {
  std::vector<std::string> strings;
  if (arguments == nullptr || fl_value_get_type(arguments) != FL_VALUE_TYPE_LIST) return strings;
  for (size_t i = 0; i < fl_value_get_length(arguments); i++) {
    FlValue* item = fl_value_get_list_value(arguments, i);
    if (fl_value_get_type(item) == FL_VALUE_TYPE_STRING) strings.emplace_back(fl_value_get_string(item));
  }
  return strings;
}

const char* String(FlValue* arguments) {
  return arguments != nullptr && fl_value_get_type(arguments) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(arguments)
             : nullptr;
}

std::string Uri(const std::string& path) {
  g_autoptr(GFile) file = g_file_new_for_path(path.c_str());
  g_autofree char* uri = g_file_get_uri(file);
  return uri;
}

double Number(FlValue* value) {
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_FLOAT: return fl_value_get_float(value);
    case FL_VALUE_TYPE_INT: return static_cast<double>(fl_value_get_int(value));
    default: return 0;
  }
}

bool Launch(const char* uri) {
  return uri != nullptr && g_app_info_launch_default_for_uri(uri, nullptr, nullptr);
}

// The file manager selects the files (org.freedesktop.FileManager1, which Nautilus, Dolphin,
// Nemo and Thunar answer); without one, their folder opens.
void Reveal(const std::vector<std::string>& paths) {
  if (paths.empty()) return;
  g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (bus != nullptr) {
    GVariantBuilder uris;
    g_variant_builder_init(&uris, G_VARIANT_TYPE("as"));
    for (const auto& path : paths) g_variant_builder_add(&uris, "s", Uri(path).c_str());
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
        "org.freedesktop.FileManager1", "ShowItems", g_variant_new("(ass)", &uris, ""), nullptr,
        G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, nullptr);
    if (reply != nullptr) return;
  }
  g_autofree char* folder = g_path_get_dirname(paths.front().c_str());
  Launch(Uri(folder).c_str());
}

// The sample photo sits in the engine's resources (main.cc names the directory).
FlValue* SamplePhoto() {
  const char* resources = g_getenv("FOTUFILM_RESOURCES");
  if (resources == nullptr) return fl_value_new_null();
  g_autofree char* path = g_build_filename(resources, "sample.png", nullptr);
  return g_file_test(path, G_FILE_TEST_EXISTS) ? fl_value_new_string(path) : fl_value_new_null();
}

void Handle(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  auto* self = static_cast<Window*>(data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* arguments = fl_method_call_get_args(call);
  g_autoptr(FlValue) result = nullptr;

  if (g_strcmp0(method, "setTitle") == 0) {
    const char* title = String(arguments) ? String(arguments) : "Fotufilm";
    if (self->header_bar != nullptr) gtk_header_bar_set_title(self->header_bar, title);
    gtk_window_set_title(self->window, title);
  } else if (g_strcmp0(method, "setContentSize") == 0) {
    if (arguments != nullptr && fl_value_get_type(arguments) == FL_VALUE_TYPE_LIST &&
        fl_value_get_length(arguments) == 2) {
      gtk_window_resize(self->window, Number(fl_value_get_list_value(arguments, 0)),
                        Number(fl_value_get_list_value(arguments, 1)));
    }
  } else if (g_strcmp0(method, "takeOpenedFiles") == 0) {
    // Photographs given on the command line reach Dart as main's arguments.
    result = fl_value_new_list();
  } else if (g_strcmp0(method, "samplePhoto") == 0) {
    result = SamplePhoto();
  } else if (g_strcmp0(method, "noteRecent") == 0) {
    GtkRecentManager* recent = gtk_recent_manager_get_default();
    for (const auto& path : Strings(arguments)) gtk_recent_manager_add_item(recent, Uri(path).c_str());
  } else if (g_strcmp0(method, "reveal") == 0) {
    Reveal(Strings(arguments));
  } else if (g_strcmp0(method, "openFile") == 0) {
    const char* path = String(arguments);
    result = fl_value_new_bool(path != nullptr && Launch(Uri(path).c_str()));
  } else if (g_strcmp0(method, "openURL") == 0) {
    result = fl_value_new_bool(Launch(String(arguments)));
  } else if (g_strcmp0(method, "trash") == 0) {
    // The paths that went to the Trash; a file that could not stays where it was.
    result = fl_value_new_list();
    for (const auto& path : Strings(arguments)) {
      g_autoptr(GFile) file = g_file_new_for_path(path.c_str());
      if (g_file_trash(file, nullptr, nullptr)) fl_value_append_take(result, fl_value_new_string(path.c_str()));
    }
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void window_channel_register(FlView* view, GtkWindow* window, GtkHeaderBar* header_bar) {
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                                   "fotufilm/window", FL_METHOD_CODEC(codec));
  auto* self = new Window{window, header_bar};
  fl_method_channel_set_method_call_handler(channel, Handle, self, [](gpointer data) {
    delete static_cast<Window*>(data);
  });
  // The channel lives as long as the window.
  g_object_set_data_full(G_OBJECT(window), "fotufilm-window-channel", channel, g_object_unref);
}

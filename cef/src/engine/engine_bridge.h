// The editor's backend calls, answered by the engine behind fotufilm.h. Every call runs on the
// dispatcher's engine thread; the engine itself decides what each method means, so this only
// moves JSON and bytes between the bridge and the library.
#pragma once

#include <string>

#include "bridge/dispatcher.h"
#include "fotufilm.h"

namespace fotufilm {

class EngineBridge {
 public:
  // Asks where to save: a suggested file name and MIME type in, a path out (empty: cancelled).
  // Called and answered on the UI thread.
  using DestinationPicker =
      std::function<void(const std::string& filename, const std::string& type,
                         std::function<void(const std::string& path)> done)>;

  // What this build's engine can offer the editor, as JSON; known without creating an engine.
  static std::string Capabilities();

  explicit EngineBridge(Dispatcher& dispatcher);
  ~EngineBridge();
  EngineBridge(const EngineBridge&) = delete;
  EngineBridge& operator=(const EngineBridge&) = delete;

  void SetDestinationPicker(DestinationPicker picker) { picker_ = std::move(picker); }

 private:
  // Created on first use, on the engine thread, so launch never waits on the film tables.
  fotufilm_engine* Engine(std::string& error);
  void Handle(const Call& call, std::shared_ptr<Reply> reply);

  void Export(const Call& call, std::shared_ptr<Reply> reply);

  Dispatcher& dispatcher_;
  DestinationPicker picker_;
  fotufilm_engine* engine_ = nullptr;
  std::string failure_;
};

}  // namespace fotufilm

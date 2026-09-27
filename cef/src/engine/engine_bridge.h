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
  explicit EngineBridge(Dispatcher& dispatcher);
  ~EngineBridge();
  EngineBridge(const EngineBridge&) = delete;
  EngineBridge& operator=(const EngineBridge&) = delete;

 private:
  // Created on first use, on the engine thread, so launch never waits on the film tables.
  fotufilm_engine* Engine(std::string& error);
  void Handle(const Call& call, std::shared_ptr<Reply> reply);

  fotufilm_engine* engine_ = nullptr;
  std::string failure_;
};

}  // namespace fotufilm

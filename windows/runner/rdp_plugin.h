// Method-channel bridge between Dart and the RDP ActiveX host.
//
// Lives in the runner rather than a pub package because it needs the runner's
// own top-level HWND to parent session windows under, and there is exactly one
// app that uses it.
#ifndef RUNNER_RDP_PLUGIN_H_
#define RUNNER_RDP_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <map>
#include <memory>

#include "rdp_ax_host.h"

namespace commands {

class RdpPlugin {
 public:
  // |owner| is the app's top-level window; every session window is created as
  // a top-level window owned by it (see RdpAxHost::Create for why not a
  // child).
  RdpPlugin(flutter::BinaryMessenger* messenger, HWND owner);
  ~RdpPlugin();

  // The app window moved or was resized. Session windows are top-level, so
  // their screen position has to be recomputed; driven from the owner's own
  // WM_WINDOWPOSCHANGED rather than polled, so dragging the app window never
  // leaves a session trailing behind the pane it belongs to.
  void OnOwnerMoved();

  // The app window was minimised or restored.
  void OnOwnerMinimized(bool minimized);

  // The runner forces focus back to the Flutter view whenever the top-level
  // window is activated. That is right for every tab except an RDP one, where
  // it silently takes the keyboard away from a session the user is typing
  // into, so the runner asks here first. Returns the window that should get
  // focus, or nullptr to leave the default alone.
  HWND FocusTarget() const;

  RdpPlugin(const RdpPlugin&) = delete;
  RdpPlugin& operator=(const RdpPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  RdpAxHost* Find(int id) const;
  void SendEvent(int id, const RdpHostEvent& event);

  HWND owner_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int, RdpAxHost*> hosts_;
  int next_id_ = 1;
};

}  // namespace commands

#endif  // RUNNER_RDP_PLUGIN_H_

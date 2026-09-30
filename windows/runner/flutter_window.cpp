#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  rdp_plugin_ = std::make_unique<commands::RdpPlugin>(
      flutter_controller_->engine()->messenger(), GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Before the engine goes away: the plugin holds a channel onto its
  // messenger, and each session's teardown pumps COM calls that can still
  // report status back through it.
  rdp_plugin_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Embedded RDP sessions live in top-level windows owned by this one, so they
  // have to be told where this window went. First, and without consuming the
  // message: Flutter's own handler below may claim some of these, and a
  // session left behind at the app's old position for the length of a drag is
  // the most visible thing this could get wrong.
  if (rdp_plugin_) {
    if (message == WM_WINDOWPOSCHANGED || message == WM_MOVE) {
      rdp_plugin_->OnOwnerMoved();
    } else if (message == WM_SIZE) {
      if (wparam == SIZE_MINIMIZED) {
        rdp_plugin_->OnOwnerMinimized(true);
      } else {
        rdp_plugin_->OnOwnerMinimized(false);
        rdp_plugin_->OnOwnerMoved();
      }
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_ACTIVATE:
      // Win32Window's own handler hands focus to the Flutter view on every
      // activation. That is right for a terminal tab, but it silently takes
      // the keyboard away from an RDP session the user was typing into -- the
      // session is a separate child window, so Flutter having focus means
      // keystrokes go nowhere the remote host can see. Give focus back to the
      // visible session instead, and only then fall through to the default.
      if (wparam != WA_INACTIVE && rdp_plugin_) {
        if (const HWND target = rdp_plugin_->FocusTarget()) {
          SetFocus(target);
          return 0;
        }
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

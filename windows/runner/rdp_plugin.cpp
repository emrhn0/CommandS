#include "rdp_plugin.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <utility>

namespace commands {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const char kChannelName[] = "commands/rdp";

const EncodableValue* Lookup(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

int GetInt(const EncodableMap& map, const char* key, int fallback) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return fallback;
  if (const auto* i = std::get_if<int32_t>(value)) return *i;
  if (const auto* l = std::get_if<int64_t>(value)) return static_cast<int>(*l);
  if (const auto* d = std::get_if<double>(value)) return static_cast<int>(*d);
  return fallback;
}

bool GetBool(const EncodableMap& map, const char* key, bool fallback) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return fallback;
  if (const auto* b = std::get_if<bool>(value)) return *b;
  return fallback;
}

std::wstring GetString(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return {};
  const auto* text = std::get_if<std::string>(value);
  if (text == nullptr || text->empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, text->c_str(),
                                       static_cast<int>(text->size()), nullptr,
                                       0);
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text->c_str(),
                      static_cast<int>(text->size()), out.data(), size);
  return out;
}

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                       static_cast<int>(text.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

RECT BoundsFrom(const EncodableMap& args) {
  RECT rc;
  rc.left = GetInt(args, "x", 0);
  rc.top = GetInt(args, "y", 0);
  rc.right = rc.left + GetInt(args, "width", 1280);
  rc.bottom = rc.top + GetInt(args, "height", 800);
  return rc;
}

}  // namespace

RdpPlugin::RdpPlugin(flutter::BinaryMessenger* messenger, HWND owner)
    : owner_(owner) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

RdpPlugin::~RdpPlugin() {
  for (auto& entry : hosts_) {
    entry.second->Destroy();
    entry.second->Release();
  }
  hosts_.clear();
}

RdpAxHost* RdpPlugin::Find(int id) const {
  const auto it = hosts_.find(id);
  return it == hosts_.end() ? nullptr : it->second;
}

void RdpPlugin::OnOwnerMoved() {
  for (auto& entry : hosts_) entry.second->FollowOwner();
}

void RdpPlugin::OnOwnerMinimized(bool minimized) {
  for (auto& entry : hosts_) entry.second->SetOwnerMinimized(minimized);
}

HWND RdpPlugin::FocusTarget() const {
  for (const auto& entry : hosts_) {
    if (entry.second->wants_focus()) return entry.second->window();
  }
  return nullptr;
}

void RdpPlugin::SendEvent(int id, const RdpHostEvent& event) {
  if (channel_ == nullptr) return;
  EncodableMap payload{
      {EncodableValue("id"), EncodableValue(id)},
      {EncodableValue("type"), EncodableValue(event.type)},
      {EncodableValue("message"), EncodableValue(event.message)},
      {EncodableValue("code"), EncodableValue(event.code)},
      {EncodableValue("extendedCode"), EncodableValue(event.extended_code)},
      {EncodableValue("width"), EncodableValue(event.width)},
      {EncodableValue("height"), EncodableValue(event.height)},
  };
  channel_->InvokeMethod("event",
                         std::make_unique<EncodableValue>(std::move(payload)));
}

void RdpPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  static const EncodableMap kEmpty;
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const EncodableMap& map = args != nullptr ? *args : kEmpty;
  const std::string& method = call.method_name();

  // Applies to every session at once, and is sent while no particular session
  // is in scope, so it is handled before the per-session id lookup below.
  if (method == "setSuspended") {
    const bool suspended = GetBool(map, "suspended", false);
    for (auto& entry : hosts_) entry.second->SetSuspended(suspended);
    result->Success();
    return;
  }

  if (method == "create") {
    auto* host = new RdpAxHost();
    const int id = next_id_++;
    host->set_event_sink([this, id](const RdpHostEvent& event) {
      SendEvent(id, event);
    });
    std::wstring error;
    if (!host->Create(owner_, BoundsFrom(map), &error)) {
      host->Release();
      result->Error("rdp_create_failed", Utf8(error));
      return;
    }
    hosts_[id] = host;
    result->Success(EncodableValue(id));
    return;
  }

  const int id = GetInt(map, "id", 0);
  RdpAxHost* host = Find(id);
  if (host == nullptr) {
    // A late setBounds/setVisible from a widget that has not rebuilt yet is
    // normal on tab close; it is not worth surfacing as an error in Dart.
    result->Success();
    return;
  }

  if (method == "connect") {
    RdpConnectParams params;
    params.host = GetString(map, "host");
    params.port = GetInt(map, "port", 3389);
    params.username = GetString(map, "username");
    params.domain = GetString(map, "domain");
    params.password = GetString(map, "password");
    params.desktop_width = GetInt(map, "width", 1280);
    params.desktop_height = GetInt(map, "height", 800);
    params.dpi = GetInt(map, "dpi", 96);
    params.redirect_clipboard = GetBool(map, "clipboard", true);
    params.show_wallpaper = GetBool(map, "wallpaper", false);
    params.redirect_printers = GetBool(map, "printers", false);
    params.redirect_drives = GetBool(map, "drives", false);
    params.audio_to_client = GetBool(map, "audio", true);
    params.console_session = GetBool(map, "console", false);
    std::wstring error;
    if (!host->Connect(params, &error)) {
      result->Error("rdp_connect_failed", Utf8(error));
      return;
    }
    result->Success(EncodableValue(host->supports_dynamic_resolution()));
    return;
  }

  if (method == "setBounds") {
    host->SetBounds(BoundsFrom(map));
    result->Success();
    return;
  }

  if (method == "resizeSession") {
    const bool ok = host->ResizeSession(GetInt(map, "width", 0),
                                       GetInt(map, "height", 0),
                                       GetInt(map, "dpi", 96));
    result->Success(EncodableValue(ok));
    return;
  }

  if (method == "setVisible") {
    host->SetVisible(GetBool(map, "visible", true));
    result->Success();
    return;
  }

  if (method == "focus") {
    host->Focus();
    result->Success();
    return;
  }

  if (method == "sendCtrlAltDel") {
    host->SendCtrlAltDelete();
    result->Success();
    return;
  }

  if (method == "disconnect") {
    host->Disconnect();
    result->Success();
    return;
  }

  if (method == "destroy") {
    hosts_.erase(id);
    host->Destroy();
    host->Release();
    result->Success();
    return;
  }

  result->NotImplemented();
}

}  // namespace commands

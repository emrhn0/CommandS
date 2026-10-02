#include "rdp_ax_host.h"

#include <objbase.h>
#include <olectl.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace commands {
namespace {

// DISPIDs of the control's default source dispinterface (IMsTscAxEvents).
// These are fixed by the type library and identical on every control version.
constexpr DISPID kOnConnecting = 1;
constexpr DISPID kOnConnected = 2;
constexpr DISPID kOnLoginComplete = 3;
constexpr DISPID kOnDisconnected = 4;
constexpr DISPID kOnFatalError = 10;
constexpr DISPID kOnWarning = 11;
constexpr DISPID kOnRemoteDesktopSizeChange = 12;
constexpr DISPID kOnConfirmClose = 15;
constexpr DISPID kOnReceivedTSPublicKey = 16;
constexpr DISPID kOnAutoReconnecting = 17;
constexpr DISPID kOnLogonError = 23;
constexpr DISPID kOnAutoReconnected = 28;

// PerformanceFlags bits (TS_PERF_*), from the RDP wire protocol.
constexpr LONG kPerfDisableWallpaper = 0x00000001;
constexpr LONG kPerfDisableFullWindowDrag = 0x00000002;
constexpr LONG kPerfDisableMenuAnimations = 0x00000004;
constexpr LONG kPerfEnableFontSmoothing = 0x00000080;
constexpr LONG kPerfEnableDesktopComposition = 0x00000100;

// The control renders the session into its own child window, so the remote
// desktop can be negotiated at exactly the pane's pixel size. Both dimensions
// have to be even for the server to accept them, and RDP itself refuses
// anything under 200x200 or over 8192.
constexpr int kMinDesktop = 200;
constexpr int kMaxDesktop = 8192;

int ClampDesktop(int value) {
  value = std::max(kMinDesktop, std::min(kMaxDesktop, value));
  return value - (value % 2);
}

// UpdateSessionDisplaySettings wants the physical size in millimetres and
// rejects anything outside 10..10000, so a pane small enough to round to 0mm
// (or a nonsense DPI) has to be clamped rather than passed through.
ULONG PixelsToMillimetres(int pixels, int dpi) {
  if (dpi <= 0) dpi = 96;
  const double mm = (static_cast<double>(pixels) / dpi) * 25.4;
  return static_cast<ULONG>(std::max(10.0, std::min(10000.0, std::round(mm))));
}

const wchar_t kWindowClass[] = L"CommandSRdpAxHost";
bool g_class_registered = false;

VARIANT VarBool(bool value) {
  VARIANT v;
  VariantInit(&v);
  v.vt = VT_BOOL;
  v.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
  return v;
}

VARIANT VarLong(LONG value) {
  VARIANT v;
  VariantInit(&v);
  v.vt = VT_I4;
  v.lVal = value;
  return v;
}

// Caller owns the BSTR through the VARIANT; VariantClear frees it.
VARIANT VarStr(const std::wstring& value) {
  VARIANT v;
  VariantInit(&v);
  v.vt = VT_BSTR;
  v.bstrVal = SysAllocString(value.c_str());
  return v;
}

DISPID NameToDispId(IDispatch* target, const wchar_t* name) {
  if (target == nullptr) return DISPID_UNKNOWN;
  LPOLESTR names[1] = {const_cast<LPOLESTR>(name)};
  DISPID id = DISPID_UNKNOWN;
  if (FAILED(target->GetIDsOfNames(IID_NULL, names, 1, LOCALE_USER_DEFAULT,
                                   &id))) {
    return DISPID_UNKNOWN;
  }
  return id;
}

// Property assignment by name. Every one of these is optional as far as this
// host is concerned: the properties we set span control versions 5 through 13
// and a handful only exist on the newer ones, so a missing name is a silent
// "this build doesn't have it" rather than a failure worth aborting a
// connection over. |value| is consumed.
bool DispPut(IDispatch* target, const wchar_t* name, VARIANT value) {
  const DISPID id = NameToDispId(target, name);
  if (id == DISPID_UNKNOWN) {
    VariantClear(&value);
    return false;
  }
  DISPID put_id = DISPID_PROPERTYPUT;
  DISPPARAMS params = {};
  params.cArgs = 1;
  params.rgvarg = &value;
  params.cNamedArgs = 1;
  params.rgdispidNamedArgs = &put_id;
  const HRESULT hr =
      target->Invoke(id, IID_NULL, LOCALE_USER_DEFAULT, DISPATCH_PROPERTYPUT,
                     &params, nullptr, nullptr, nullptr);
  VariantClear(&value);
  return SUCCEEDED(hr);
}

// Returns an owned VARIANT; the caller clears it.
bool DispGet(IDispatch* target, const wchar_t* name, VARIANT* out) {
  VariantInit(out);
  const DISPID id = NameToDispId(target, name);
  if (id == DISPID_UNKNOWN) return false;
  DISPPARAMS params = {};
  return SUCCEEDED(target->Invoke(id, IID_NULL, LOCALE_USER_DEFAULT,
                                  DISPATCH_PROPERTYGET, &params, out, nullptr,
                                  nullptr));
}

// |args| is in call order; DISPPARAMS wants it reversed, which is done here so
// callers never have to think about it. Every VARIANT in |args| is consumed.
HRESULT DispCall(IDispatch* target, const wchar_t* name,
                 std::vector<VARIANT> args, VARIANT* out) {
  const DISPID id = NameToDispId(target, name);
  if (id == DISPID_UNKNOWN) {
    for (auto& a : args) VariantClear(&a);
    return DISP_E_UNKNOWNNAME;
  }
  std::reverse(args.begin(), args.end());
  DISPPARAMS params = {};
  params.cArgs = static_cast<UINT>(args.size());
  params.rgvarg = args.empty() ? nullptr : args.data();
  const HRESULT hr =
      target->Invoke(id, IID_NULL, LOCALE_USER_DEFAULT, DISPATCH_METHOD,
                     &params, out, nullptr, nullptr);
  for (auto& a : args) VariantClear(&a);
  return hr;
}

std::string Narrow(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                       static_cast<int>(text.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

LONG VariantToLong(const VARIANT& v) {
  VARIANT copy;
  VariantInit(&copy);
  if (SUCCEEDED(VariantChangeType(&copy, const_cast<VARIANT*>(&v), 0, VT_I4))) {
    const LONG value = copy.lVal;
    VariantClear(&copy);
    return value;
  }
  return 0;
}

}  // namespace

RdpAxHost::RdpAxHost() = default;

RdpAxHost::~RdpAxHost() { Destroy(); }

// ---------------------------------------------------------------------------
// Container window
// ---------------------------------------------------------------------------

void RdpAxHost::EnsureWindowClass() {
  if (g_class_registered) return;
  WNDCLASSEX wc = {};
  wc.cbSize = sizeof(wc);
  // The control paints the whole client area itself; CS_HREDRAW/CS_VREDRAW
  // would only add a full invalidate on every resize on top of that.
  wc.style = 0;
  wc.lpfnWndProc = RdpAxHost::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground =
      reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  wc.lpszClassName = kWindowClass;
  RegisterClassEx(&wc);
  g_class_registered = true;
}

LRESULT CALLBACK RdpAxHost::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  auto* host = reinterpret_cast<RdpAxHost*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (message) {
    case WM_SIZE:
      if (host != nullptr && host->in_place_object_ != nullptr) {
        RECT rc;
        GetClientRect(hwnd, &rc);
        host->in_place_object_->SetObjectRects(&rc, &rc);
      }
      return 0;
    case WM_SETFOCUS:
      // Keyboard input has to end up in the control's own child window, not
      // in this container -- the container has no input handling of its own,
      // so a focused container is a session that silently ignores typing.
      // ::GetWindow, not this class's IOleWindow::GetWindow, which the name
      // would otherwise resolve to even from a static member.
      if (const HWND child = ::GetWindow(hwnd, GW_CHILD)) {
        SetFocus(child);
        return 0;
      }
      break;
    case WM_ERASEBKGND:
      // Paint the gap black rather than letting the default white flash
      // through in the frames between a resize and the control repainting.
      {
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect(reinterpret_cast<HDC>(wparam), &rc,
                 reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
      }
      return 1;
    default:
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

bool RdpAxHost::Create(HWND owner, const RECT& bounds, std::wstring* error) {
  EnsureWindowClass();
  owner_ = owner;
  client_bounds_ = bounds;

  // A top-level window *owned* by the app window, not a child of it.
  //
  // A child window is the obvious choice and it does not work. Flutter on
  // Windows presents through DirectComposition, and DWM composites that
  // surface above the window's child HWNDs no matter what their z-order says
  // -- measured directly: with the session window sitting at z0, above
  // Flutter's view at z1, any Flutter repaint (hovering the sidebar, opening a
  // dialog) still painted the pane's black placeholder straight over the live
  // session, which came back only once Flutter stopped drawing. No amount of
  // SetWindowPos wins that, because it is not a z-order fight; the previous
  // mstsc-based implementation's 30ms timer was re-raising a window that was
  // already on top, and the "fix" was really just repainting over the
  // composited frame 33 times a second -- which is exactly the flicker it was
  // known for.
  //
  // An owned top-level window is composited by DWM as a window in its own
  // right, always above its owner and never inside the owner's composition
  // surface, so there is nothing left to fight. The costs are that its
  // position is in screen coordinates and has to track the app window (see
  // FollowOwner), and that it has to be hidden when the owner is minimised.
  // WS_EX_TOOLWINDOW keeps it out of Alt-Tab and the taskbar; it deliberately
  // stays focusable, since typing into the session is the entire point.
  hwnd_ = CreateWindowEx(WS_EX_TOOLWINDOW, kWindowClass, L"",
                         WS_POPUP | WS_CLIPCHILDREN, 0, 0,
                         bounds.right - bounds.left,
                         bounds.bottom - bounds.top, owner, nullptr,
                         GetModuleHandle(nullptr), nullptr);
  if (hwnd_ == nullptr) {
    if (error) *error = L"Could not create the RDP container window.";
    return false;
  }
  ApplyPosition();
  SetWindowLongPtr(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));

  if (!CreateControl(error)) {
    // Not just DestroyWindow: CreateControl fails at several points, and by
    // the last of them it has already created the control, given it this
    // client site and connected an event sink. Destroy unwinds whichever of
    // those actually happened.
    Destroy();
    return false;
  }

  // Not just ShowWindow: a freshly created child window's z-order relative to
  // its siblings is whatever Windows felt like, and Flutter's view is a
  // sibling covering the same area. Showing without raising leaves the session
  // behind it -- visible as a connected session that draws nothing but black.
  SetVisible(true);
  return true;
}

bool RdpAxHost::CreateControl(std::wstring* error) {
  // Newest first. Version 10 of the control is the first with
  // UpdateSessionDisplaySettings (the RDP 8.1 dynamic-resolution path), so
  // anything older gets scaling instead -- still a working session. Note that
  // a ProgID being *registered* does not mean it can be created: on Windows 11
  // 25H2, `MsTscAx.MsTscAx.13` is registered but its class factory returns
  // CLASS_E_CLASSNOTAVAILABLE, which is exactly why this walks down the list
  // instead of trusting the highest registered version.
  for (int version = 13; version >= 5; --version) {
    const std::wstring prog_id =
        L"MsTscAx.MsTscAx." + std::to_wstring(version);
    CLSID clsid;
    if (FAILED(CLSIDFromProgID(prog_id.c_str(), &clsid))) continue;
    IUnknown* unknown = nullptr;
    if (FAILED(CoCreateInstance(clsid, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&unknown)))) {
      continue;
    }
    control_ = unknown;
    control_version_ = version;
    break;
  }
  if (control_ == nullptr) {
    if (error) {
      *error =
          L"The Remote Desktop ActiveX control (mstscax.dll) could not be "
          L"created. Remote Desktop Connection may be missing or disabled on "
          L"this machine.";
    }
    return false;
  }

  if (FAILED(control_->QueryInterface(IID_PPV_ARGS(&dispatch_))) ||
      FAILED(control_->QueryInterface(IID_PPV_ARGS(&ole_object_)))) {
    if (error) *error = L"The RDP control is missing its OLE interfaces.";
    return false;
  }

  ole_object_->SetClientSite(static_cast<IOleClientSite*>(this));
  ole_object_->SetHostNames(L"CommandS", L"CommandS");
  OleSetContainedObject(control_, TRUE);

  // Events have to be wired before Connect, or the first OnConnecting /
  // OnFatalError is lost and the tab sits on a spinner.
  AdviseEvents();

  RECT rc;
  GetClientRect(hwnd_, &rc);
  const HRESULT hr =
      ole_object_->DoVerb(OLEIVERB_INPLACEACTIVATE, nullptr,
                          static_cast<IOleClientSite*>(this), 0, hwnd_, &rc);
  if (FAILED(hr)) {
    if (error) *error = L"The RDP control could not be activated in place.";
    return false;
  }
  control_->QueryInterface(IID_PPV_ARGS(&in_place_object_));
  if (in_place_object_ != nullptr) in_place_object_->SetObjectRects(&rc, &rc);

  has_client9_ =
      NameToDispId(dispatch_, L"UpdateSessionDisplaySettings") != DISPID_UNKNOWN;
  return true;
}

bool RdpAxHost::AdviseEvents() {
  if (control_ == nullptr) return false;
  // Ask the control which dispinterface its events come in on rather than
  // hardcoding IID_IMsTscAxEvents: the control is the authority on its own
  // default source interface, and this keeps one less version-specific GUID
  // in this file.
  IProvideClassInfo2* class_info = nullptr;
  IID source_iid = {};
  if (SUCCEEDED(control_->QueryInterface(IID_PPV_ARGS(&class_info)))) {
    class_info->GetGUID(GUIDKIND_DEFAULT_SOURCE_DISP_IID, &source_iid);
    class_info->Release();
  }
  IConnectionPointContainer* container = nullptr;
  if (FAILED(control_->QueryInterface(IID_PPV_ARGS(&container)))) return false;
  HRESULT hr = E_FAIL;
  if (source_iid != GUID_NULL) {
    hr = container->FindConnectionPoint(source_iid, &connection_point_);
  }
  if (FAILED(hr)) {
    // No IProvideClassInfo2 (or it named an interface the container doesn't
    // offer): fall back to whatever single source interface it does have.
    IEnumConnectionPoints* points = nullptr;
    if (SUCCEEDED(container->EnumConnectionPoints(&points))) {
      ULONG fetched = 0;
      IConnectionPoint* point = nullptr;
      if (points->Next(1, &point, &fetched) == S_OK && fetched == 1) {
        connection_point_ = point;
        hr = S_OK;
      }
      points->Release();
    }
  }
  container->Release();
  if (FAILED(hr) || connection_point_ == nullptr) return false;
  // Ask the connection point itself which interface it will call us on, rather
  // than trusting what IProvideClassInfo2 said (and covering the fallback path
  // above, where nothing said anything). QueryInterface has to answer for this
  // IID for Advise to accept the sink at all.
  connection_point_->GetConnectionInterface(&source_iid_);
  return SUCCEEDED(connection_point_->Advise(static_cast<IDispatch*>(this),
                                             &advise_cookie_));
}

void RdpAxHost::UnadviseEvents() {
  if (connection_point_ != nullptr) {
    if (advise_cookie_ != 0) connection_point_->Unadvise(advise_cookie_);
    connection_point_->Release();
    connection_point_ = nullptr;
    advise_cookie_ = 0;
  }
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

IDispatch* RdpAxHost::GetAdvancedSettings() {
  if (advanced_settings_ != nullptr) return advanced_settings_;
  if (dispatch_ == nullptr) return nullptr;
  // AdvancedSettings9 down to AdvancedSettings2 all return the same underlying
  // object through a wider interface, so the newest one present gives access
  // to every property without needing to know which version introduced which.
  static const wchar_t* kNames[] = {
      L"AdvancedSettings9", L"AdvancedSettings8", L"AdvancedSettings7",
      L"AdvancedSettings6", L"AdvancedSettings5", L"AdvancedSettings4",
      L"AdvancedSettings3", L"AdvancedSettings2", L"AdvancedSettings"};
  for (const wchar_t* name : kNames) {
    VARIANT result;
    if (DispGet(dispatch_, name, &result)) {
      if (result.vt == VT_DISPATCH && result.pdispVal != nullptr) {
        advanced_settings_ = result.pdispVal;  // ownership moves to us
        return advanced_settings_;
      }
      VariantClear(&result);
    }
  }
  return nullptr;
}

IDispatch* RdpAxHost::GetSecuredSettings() {
  if (dispatch_ == nullptr) return nullptr;
  static const wchar_t* kNames[] = {L"SecuredSettings3", L"SecuredSettings2",
                                    L"SecuredSettings"};
  for (const wchar_t* name : kNames) {
    VARIANT result;
    if (DispGet(dispatch_, name, &result)) {
      if (result.vt == VT_DISPATCH && result.pdispVal != nullptr) {
        return result.pdispVal;  // caller releases
      }
      VariantClear(&result);
    }
  }
  return nullptr;
}

bool RdpAxHost::Connect(const RdpConnectParams& params, std::wstring* error) {
  if (dispatch_ == nullptr) {
    if (error) *error = L"RDP control was not created.";
    return false;
  }
  if (connect_called_) return true;

  const int width = ClampDesktop(params.desktop_width);
  const int height = ClampDesktop(params.desktop_height);

  DispPut(dispatch_, L"Server", VarStr(params.host));
  DispPut(dispatch_, L"UserName", VarStr(params.username));
  if (!params.domain.empty()) {
    DispPut(dispatch_, L"Domain", VarStr(params.domain));
  }
  DispPut(dispatch_, L"DesktopWidth", VarLong(width));
  DispPut(dispatch_, L"DesktopHeight", VarLong(height));
  DispPut(dispatch_, L"ColorDepth", VarLong(32));

  IDispatch* advanced = GetAdvancedSettings();
  if (advanced != nullptr) {
    DispPut(advanced, L"RDPPort", VarLong(params.port));

    // The whole reason this host exists rather than another mstsc.exe: the
    // password goes straight into the control. The old path had to write it
    // into Windows Credential Manager under TERMSRV/<host> with `cmdkey`,
    // where it was visible to every process running as this user until the
    // session came up and it was deleted again -- and stayed there if the app
    // crashed in between.
    if (!params.password.empty()) {
      DispPut(advanced, L"ClearTextPassword", VarStr(params.password));
    }

    // Authenticate with NLA where the server offers it, but do not refuse a
    // server whose certificate does not verify: these are typically machines
    // on the user's own network with self-signed certificates, and mstsc's
    // answer to that is a warning dialog we have no way to show inside a tab.
    DispPut(advanced, L"AuthenticationLevel", VarLong(0));
    DispPut(advanced, L"EnableCredSspSupport", VarBool(true));
    DispPut(advanced, L"NegotiateSecurityLayer", VarBool(true));

    DispPut(advanced, L"RedirectClipboard", VarBool(params.redirect_clipboard));
    DispPut(advanced, L"RedirectPrinters", VarBool(params.redirect_printers));
    DispPut(advanced, L"RedirectDrives", VarBool(params.redirect_drives));

    LONG perf = kPerfEnableFontSmoothing | kPerfEnableDesktopComposition |
                kPerfDisableFullWindowDrag | kPerfDisableMenuAnimations;
    if (!params.show_wallpaper) perf |= kPerfDisableWallpaper;
    DispPut(advanced, L"PerformanceFlags", VarLong(perf));

    // Scaling is the fallback for servers too old for dynamic resolution
    // (pre-2012R2). Where dynamic resolution works the remote desktop is
    // renegotiated at the pane's exact pixel size, so there is nothing left to
    // scale and this never kicks in -- which is the difference between a sharp
    // session and the blurry stretched one the previous implementation was
    // stuck with after any resize.
    DispPut(advanced, L"SmartSizing", VarBool(true));

    // Reconnect through a brief network drop instead of dropping the tab.
    DispPut(advanced, L"EnableAutoReconnect", VarBool(true));
    DispPut(advanced, L"MaxReconnectAttempts", VarLong(20));

    // This control lives in a tab, so it must never take over the screen or
    // draw mstsc's floating connection bar, and must not steal focus the
    // moment a background tab finishes connecting.
    DispPut(advanced, L"ContainerHandledFullScreen", VarLong(1));
    DispPut(advanced, L"DisplayConnectionBar", VarBool(false));
    DispPut(advanced, L"GrabFocusOnConnect", VarBool(false));

    if (params.console_session) {
      DispPut(advanced, L"ConnectToAdministerServer", VarBool(true));
    }
  }

  if (IDispatch* secured = GetSecuredSettings()) {
    // 2 = route Windows key combinations to the remote session only in full
    // screen. In a tab that means Alt-Tab, Win and friends keep working on the
    // local machine, which is what a user switching between panes expects;
    // mode 1 would hand the local desktop's shortcuts to the remote host.
    DispPut(secured, L"KeyboardHookMode", VarLong(2));
    // 0 = play remote audio on this machine, 2 = leave it on the server.
    DispPut(secured, L"AudioRedirectionMode",
            VarLong(params.audio_to_client ? 0 : 2));
    secured->Release();
  }

  connect_called_ = true;
  VARIANT result;
  VariantInit(&result);
  const HRESULT hr = DispCall(dispatch_, L"Connect", {}, &result);
  VariantClear(&result);
  if (FAILED(hr)) {
    connect_called_ = false;
    if (error) *error = L"The RDP control refused to start connecting.";
    return false;
  }
  return true;
}

void RdpAxHost::Disconnect() {
  if (dispatch_ == nullptr || !connect_called_) return;
  local_disconnect_requested_ = true;
  VARIANT connected;
  if (DispGet(dispatch_, L"Connected", &connected)) {
    const LONG state = VariantToLong(connected);
    VariantClear(&connected);
    // 0 = not connected. Calling Disconnect in that state returns an error and
    // fires nothing, so there is no point.
    if (state == 0) return;
  }
  VARIANT result;
  VariantInit(&result);
  DispCall(dispatch_, L"Disconnect", {}, &result);
  VariantClear(&result);
}

void RdpAxHost::SetBounds(const RECT& bounds) {
  client_bounds_ = bounds;
  ApplyPosition();
}

void RdpAxHost::FollowOwner() { ApplyPosition(); }

void RdpAxHost::ApplyPosition() {
  if (hwnd_ == nullptr || owner_ == nullptr) return;
  // Clamp to the owner's client area. The container is a top-level window, so
  // nothing clips it on its own: a pane whose rectangle briefly overshoots
  // mid-resize would otherwise be drawn outside the app window entirely.
  RECT client;
  if (!GetClientRect(owner_, &client)) return;
  RECT rc = client_bounds_;
  rc.left = std::max(rc.left, client.left);
  rc.top = std::max(rc.top, client.top);
  rc.right = std::min(rc.right, client.right);
  rc.bottom = std::min(rc.bottom, client.bottom);
  if (rc.right <= rc.left || rc.bottom <= rc.top) {
    ShowWindow(hwnd_, SW_HIDE);
    return;
  }
  POINT origin = {rc.left, rc.top};
  ClientToScreen(owner_, &origin);
  SetWindowPos(hwnd_, nullptr, origin.x, origin.y, rc.right - rc.left,
               rc.bottom - rc.top, SWP_NOZORDER | SWP_NOACTIVATE);
  const bool should_show = visible_ && !owner_minimized_ && !suspended_;
  if (should_show && !IsWindowVisible(hwnd_)) ShowWindow(hwnd_, SW_SHOWNA);
}

void RdpAxHost::SetOwnerMinimized(bool minimized) {
  if (owner_minimized_ == minimized) return;
  owner_minimized_ = minimized;
  UpdateVisibility();
}

void RdpAxHost::SetSuspended(bool suspended) {
  if (suspended_ == suspended) return;
  suspended_ = suspended;
  UpdateVisibility();
}

void RdpAxHost::UpdateVisibility() {
  if (hwnd_ == nullptr) return;
  if (visible_ && !owner_minimized_ && !suspended_) {
    ApplyPosition();
    // SWP_NOACTIVATE so showing a session never steals the foreground from
    // whatever the user is doing -- this is an owned top-level window, and
    // activating it would take focus off the app's own UI.
    SetWindowPos(hwnd_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  } else {
    ShowWindow(hwnd_, SW_HIDE);
  }
}

bool RdpAxHost::ResizeSession(int width, int height, int dpi) {
  if (!has_client9_ || dispatch_ == nullptr || !connected_) return false;
  const int w = ClampDesktop(width);
  const int h = ClampDesktop(height);
  std::vector<VARIANT> args;
  args.push_back(VarLong(w));
  args.push_back(VarLong(h));
  args.push_back(VarLong(static_cast<LONG>(PixelsToMillimetres(w, dpi))));
  args.push_back(VarLong(static_cast<LONG>(PixelsToMillimetres(h, dpi))));
  args.push_back(VarLong(0));    // orientation, degrees
  args.push_back(VarLong(100));  // desktop scale factor, percent
  args.push_back(VarLong(100));  // device scale factor, percent
  VARIANT result;
  VariantInit(&result);
  const HRESULT hr =
      DispCall(dispatch_, L"UpdateSessionDisplaySettings", std::move(args),
               &result);
  VariantClear(&result);
  return SUCCEEDED(hr);
}

void RdpAxHost::SetVisible(bool visible) {
  visible_ = visible;
  UpdateVisibility();
}

void RdpAxHost::Focus() {
  if (hwnd_ == nullptr || !visible_ || owner_minimized_ || suspended_) return;
  // Only while this app is already the one the user is working in. The
  // session lives in a top-level window, so focusing it also activates it --
  // which, done unconditionally, meant a tab finishing its connection could
  // pull the foreground away from whatever else the user had switched to.
  const HWND foreground = GetForegroundWindow();
  if (foreground != owner_ && foreground != hwnd_) return;
  // UI-activating the control is what actually hands it the keyboard; without
  // it a click lands in the session but typing goes nowhere.
  if (ole_object_ != nullptr) {
    RECT rc;
    GetClientRect(hwnd_, &rc);
    ole_object_->DoVerb(OLEIVERB_UIACTIVATE, nullptr,
                        static_cast<IOleClientSite*>(this), 0, hwnd_, &rc);
  }
  SetFocus(hwnd_);
}

void RdpAxHost::SendCtrlAltDelete() {
  if (dispatch_ == nullptr || !connected_) return;
  // Windows intercepts the real Ctrl+Alt+Del before any application sees it,
  // so a windowed session can only get one by asking the control to inject it.
  VARIANT result;
  VariantInit(&result);
  std::vector<VARIANT> args;
  args.push_back(VarLong(0));  // RemoteActionCtrlAltDel
  if (FAILED(DispCall(dispatch_, L"SendRemoteAction", std::move(args),
                      &result))) {
    VariantClear(&result);
    // Older controls expose it only on the non-scriptable interface, which
    // this host does not reach through IDispatch; Ctrl+Alt+End typed into the
    // session does the same thing there.
    return;
  }
  VariantClear(&result);
}

std::wstring RdpAxHost::DescribeDisconnect(int reason, int* extended_out) {
  if (dispatch_ == nullptr) return {};
  LONG extended = 0;
  VARIANT ext;
  if (DispGet(dispatch_, L"ExtendedDisconnectReason", &ext)) {
    extended = VariantToLong(ext);
    VariantClear(&ext);
  }
  if (extended_out != nullptr) *extended_out = static_cast<int>(extended);
  std::vector<VARIANT> args;
  args.push_back(VarLong(reason));
  args.push_back(VarLong(extended));
  VARIANT result;
  VariantInit(&result);
  std::wstring description;
  if (SUCCEEDED(DispCall(dispatch_, L"GetErrorDescription", std::move(args),
                         &result)) &&
      result.vt == VT_BSTR && result.bstrVal != nullptr) {
    description.assign(result.bstrVal, SysStringLen(result.bstrVal));
  }
  VariantClear(&result);
  return description;
}

void RdpAxHost::Emit(const RdpHostEvent& event) {
  if (event_sink_) event_sink_(event);
}

void RdpAxHost::Destroy() {
  // Closing the control below drops the session, which fires OnDisconnected on
  // the way out; mark it as ours so nothing reports a tab the user just closed
  // as a failed connection.
  local_disconnect_requested_ = true;
  UnadviseEvents();
  if (advanced_settings_ != nullptr) {
    advanced_settings_->Release();
    advanced_settings_ = nullptr;
  }
  if (in_place_object_ != nullptr) {
    in_place_object_->Release();
    in_place_object_ = nullptr;
  }
  if (ole_object_ != nullptr) {
    // Close before dropping the client site: the control is still in place
    // activated at this point and will call back into this site while shutting
    // its session down.
    ole_object_->Close(OLECLOSE_NOSAVE);
    ole_object_->SetClientSite(nullptr);
    ole_object_->Release();
    ole_object_ = nullptr;
  }
  if (dispatch_ != nullptr) {
    dispatch_->Release();
    dispatch_ = nullptr;
  }
  if (control_ != nullptr) {
    control_->Release();
    control_ = nullptr;
  }
  if (hwnd_ != nullptr) {
    SetWindowLongPtr(hwnd_, GWLP_USERDATA, 0);
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  connected_ = false;
}

// ---------------------------------------------------------------------------
// IUnknown
// ---------------------------------------------------------------------------

HRESULT RdpAxHost::QueryInterface(REFIID riid, void** out) {
  if (out == nullptr) return E_POINTER;
  *out = nullptr;
  if (riid == IID_IUnknown || riid == IID_IOleClientSite) {
    *out = static_cast<IOleClientSite*>(this);
  } else if (riid == IID_IOleInPlaceSite) {
    *out = static_cast<IOleInPlaceSite*>(this);
  } else if (riid == IID_IOleWindow) {
    *out = static_cast<IOleWindow*>(static_cast<IOleInPlaceSite*>(this));
  } else if (riid == IID_IOleInPlaceFrame) {
    *out = static_cast<IOleInPlaceFrame*>(this);
  } else if (riid == IID_IOleInPlaceUIWindow) {
    *out = static_cast<IOleInPlaceUIWindow*>(this);
  } else if (riid == IID_IOleControlSite) {
    *out = static_cast<IOleControlSite*>(this);
  } else if (riid == IID_IDispatch ||
             (source_iid_ != GUID_NULL && riid == source_iid_)) {
    // The control's events arrive as IDispatch::Invoke calls on its own event
    // dispinterface, so both names answer with the same pointer.
    *out = static_cast<IDispatch*>(this);
  } else {
    return E_NOINTERFACE;
  }
  AddRef();
  return S_OK;
}

ULONG RdpAxHost::AddRef() { return InterlockedIncrement(&ref_count_); }

ULONG RdpAxHost::Release() {
  const LONG count = InterlockedDecrement(&ref_count_);
  if (count == 0) delete this;
  return static_cast<ULONG>(count);
}

// ---------------------------------------------------------------------------
// IOleClientSite -- nothing here needs real behaviour. The control is not a
// document being edited, so there is nothing to save, no moniker to hand out
// and no container to enumerate; the calls just have to succeed or fail
// consistently.
// ---------------------------------------------------------------------------

HRESULT RdpAxHost::SaveObject() { return S_OK; }

HRESULT RdpAxHost::GetMoniker(DWORD, DWORD, IMoniker** moniker) {
  if (moniker) *moniker = nullptr;
  return E_NOTIMPL;
}

HRESULT RdpAxHost::GetContainer(IOleContainer** container) {
  if (container) *container = nullptr;
  return E_NOINTERFACE;
}

HRESULT RdpAxHost::ShowObject() { return S_OK; }

HRESULT RdpAxHost::OnShowWindow(BOOL) { return S_OK; }

HRESULT RdpAxHost::RequestNewObjectLayout() { return E_NOTIMPL; }

// ---------------------------------------------------------------------------
// IOleWindow / IOleInPlaceSite
// ---------------------------------------------------------------------------

HRESULT RdpAxHost::GetWindow(HWND* out) {
  if (out == nullptr) return E_POINTER;
  *out = hwnd_;
  return hwnd_ != nullptr ? S_OK : E_FAIL;
}

HRESULT RdpAxHost::ContextSensitiveHelp(BOOL) { return E_NOTIMPL; }

HRESULT RdpAxHost::CanInPlaceActivate() { return S_OK; }

HRESULT RdpAxHost::OnInPlaceActivate() { return S_OK; }

HRESULT RdpAxHost::OnUIActivate() { return S_OK; }

HRESULT RdpAxHost::GetWindowContext(IOleInPlaceFrame** frame,
                                    IOleInPlaceUIWindow** ui_window,
                                    LPRECT pos_rect, LPRECT clip_rect,
                                    LPOLEINPLACEFRAMEINFO frame_info) {
  if (frame != nullptr) {
    *frame = static_cast<IOleInPlaceFrame*>(this);
    AddRef();
  }
  // No separate document window sits between the frame and the control.
  if (ui_window != nullptr) *ui_window = nullptr;
  RECT rc = {};
  if (hwnd_ != nullptr) GetClientRect(hwnd_, &rc);
  if (pos_rect != nullptr) *pos_rect = rc;
  // Clipping to the container's own client rect is what keeps the session
  // inside its pane; the container window's WS_CLIPCHILDREN does the rest.
  if (clip_rect != nullptr) *clip_rect = rc;
  if (frame_info != nullptr) {
    frame_info->cb = sizeof(OLEINPLACEFRAMEINFO);
    frame_info->fMDIApp = FALSE;
    frame_info->hwndFrame = owner_;
    frame_info->haccel = nullptr;
    frame_info->cAccelEntries = 0;
  }
  return S_OK;
}

HRESULT RdpAxHost::Scroll(SIZE) { return E_NOTIMPL; }

HRESULT RdpAxHost::OnUIDeactivate(BOOL) { return S_OK; }

HRESULT RdpAxHost::OnInPlaceDeactivate() {
  if (in_place_object_ != nullptr) {
    in_place_object_->Release();
    in_place_object_ = nullptr;
  }
  return S_OK;
}

HRESULT RdpAxHost::DiscardUndoState() { return E_NOTIMPL; }

HRESULT RdpAxHost::DeactivateAndUndo() { return E_NOTIMPL; }

HRESULT RdpAxHost::OnPosRectChange(LPCRECT pos_rect) {
  // The control asking to be resized. Its size is ours to decide (it fills the
  // pane), so the request is answered by restating the container's rect.
  if (in_place_object_ != nullptr && hwnd_ != nullptr) {
    RECT rc;
    GetClientRect(hwnd_, &rc);
    in_place_object_->SetObjectRects(&rc, &rc);
  }
  (void)pos_rect;
  return S_OK;
}

// ---------------------------------------------------------------------------
// IOleInPlaceUIWindow / IOleInPlaceFrame -- this container has no menus,
// toolbars or status bar to share, so every negotiation is declined.
// ---------------------------------------------------------------------------

HRESULT RdpAxHost::GetBorder(LPRECT border) {
  if (border == nullptr) return E_POINTER;
  *border = {};
  return INPLACE_E_NOTOOLSPACE;
}

HRESULT RdpAxHost::RequestBorderSpace(LPCBORDERWIDTHS) {
  return INPLACE_E_NOTOOLSPACE;
}

HRESULT RdpAxHost::SetBorderSpace(LPCBORDERWIDTHS) { return S_OK; }

HRESULT RdpAxHost::SetActiveObject(IOleInPlaceActiveObject*, LPCOLESTR) {
  return S_OK;
}

HRESULT RdpAxHost::InsertMenus(HMENU, LPOLEMENUGROUPWIDTHS) {
  return E_NOTIMPL;
}

HRESULT RdpAxHost::SetMenu(HMENU, HOLEMENU, HWND) { return S_OK; }

HRESULT RdpAxHost::RemoveMenus(HMENU) { return E_NOTIMPL; }

HRESULT RdpAxHost::SetStatusText(LPCOLESTR) { return S_OK; }

HRESULT RdpAxHost::EnableModeless(BOOL) { return S_OK; }

HRESULT RdpAxHost::TranslateAccelerator(LPMSG, WORD) { return S_FALSE; }

// ---------------------------------------------------------------------------
// IOleControlSite
// ---------------------------------------------------------------------------

HRESULT RdpAxHost::OnControlInfoChanged() { return S_OK; }

HRESULT RdpAxHost::LockInPlaceActive(BOOL) { return S_OK; }

HRESULT RdpAxHost::GetExtendedControl(IDispatch** out) {
  if (out) *out = nullptr;
  return E_NOTIMPL;
}

HRESULT RdpAxHost::TransformCoords(POINTL*, POINTF*, DWORD) {
  return E_NOTIMPL;
}

// S_FALSE, deliberately: the container has no accelerators of its own and must
// not consume keystrokes here. Returning S_OK would tell the control the
// keystroke was handled locally, and the remote session would never see it.
HRESULT RdpAxHost::TranslateAccelerator(LPMSG, DWORD) { return S_FALSE; }

HRESULT RdpAxHost::OnFocus(BOOL) { return S_OK; }

HRESULT RdpAxHost::ShowPropertyFrame() { return E_NOTIMPL; }

// ---------------------------------------------------------------------------
// IDispatch -- event sink
// ---------------------------------------------------------------------------

HRESULT RdpAxHost::GetTypeInfoCount(UINT* count) {
  if (count) *count = 0;
  return S_OK;
}

HRESULT RdpAxHost::GetTypeInfo(UINT, LCID, ITypeInfo** info) {
  if (info) *info = nullptr;
  return E_NOTIMPL;
}

HRESULT RdpAxHost::GetIDsOfNames(REFIID, LPOLESTR*, UINT, LCID, DISPID*) {
  return E_NOTIMPL;
}

HRESULT RdpAxHost::Invoke(DISPID dispid, REFIID, LCID, WORD,
                          DISPPARAMS* params, VARIANT* result, EXCEPINFO*,
                          UINT*) {
  const auto arg = [params](UINT index) -> LONG {
    // DISPPARAMS arrives reversed, so argument 0 is the last entry.
    if (params == nullptr || index >= params->cArgs) return 0;
    return VariantToLong(params->rgvarg[params->cArgs - 1 - index]);
  };

  switch (dispid) {
    case kOnConnecting:
      Emit({"connecting"});
      return S_OK;
    case kOnConnected:
      connected_ = true;
      Emit({"connected"});
      return S_OK;
    case kOnLoginComplete:
      Emit({"loggedIn"});
      return S_OK;
    case kOnDisconnected: {
      const int reason = static_cast<int>(arg(0));
      const bool was_connected = connected_;
      connected_ = false;
      RdpHostEvent event;
      event.code = reason;
      event.message = Narrow(DescribeDisconnect(reason, &event.extended_code));
      // "closed" means the session ended the way sessions are meant to:
      // because this app asked it to, because the user logged off or
      // disconnected from inside the session, or because the server ended it.
      // Everything else -- above all a rejected password, which arrives as
      // reason 1 with the control's famously unhelpful "An internal error has
      // occurred." -- is a failure the user needs to see, with a retry.
      //
      // exDiscReason values: 1 API-initiated disconnect, 2 API-initiated
      // logoff, 11 RPC-initiated disconnect by user, 12 logoff by user.
      const bool user_ended = event.extended_code == 1 ||
                              event.extended_code == 2 ||
                              event.extended_code == 11 ||
                              event.extended_code == 12;
      // reason 2 = remote disconnection by user, 3 = remote disconnection by
      // server; both only ever happen to a session that got as far as running.
      const bool remote_ended = was_connected && (reason == 2 || reason == 3);
      event.type = (local_disconnect_requested_ || user_ended || remote_ended)
                       ? "closed"
                       : "disconnected";
      local_disconnect_requested_ = false;
      Emit(event);
      return S_OK;
    }
    case kOnFatalError: {
      RdpHostEvent event;
      event.type = "fatal";
      event.code = static_cast<int>(arg(0));
      connected_ = false;
      Emit(event);
      return S_OK;
    }
    case kOnWarning: {
      RdpHostEvent event;
      event.type = "warning";
      event.code = static_cast<int>(arg(0));
      Emit(event);
      return S_OK;
    }
    case kOnRemoteDesktopSizeChange: {
      RdpHostEvent event;
      event.type = "sizeChanged";
      event.width = static_cast<int>(arg(0));
      event.height = static_cast<int>(arg(1));
      Emit(event);
      return S_OK;
    }
    case kOnLogonError: {
      RdpHostEvent event;
      event.type = "logonError";
      event.code = static_cast<int>(arg(0));
      Emit(event);
      return S_OK;
    }
    case kOnAutoReconnecting: {
      RdpHostEvent event;
      event.type = "reconnecting";
      event.code = static_cast<int>(arg(1));  // attempt count
      Emit(event);
      // Keep retrying (0 = ArcContinueAutomatic).
      if (result != nullptr) {
        VariantInit(result);
        result->vt = VT_I4;
        result->lVal = 0;
      }
      return S_OK;
    }
    case kOnAutoReconnected:
      connected_ = true;
      Emit({"reconnected"});
      return S_OK;
    case kOnConfirmClose:
      // Nothing to confirm -- the tab closing *is* the decision.
      if (result != nullptr) {
        VariantInit(result);
        result->vt = VT_BOOL;
        result->boolVal = VARIANT_TRUE;
      }
      return S_OK;
    case kOnReceivedTSPublicKey:
      // Accept and carry on logging in; a self-signed certificate on the
      // user's own network is the normal case here and there is no dialog to
      // show inside a tab.
      if (result != nullptr) {
        VariantInit(result);
        result->vt = VT_BOOL;
        result->boolVal = VARIANT_TRUE;
      }
      return S_OK;
    default:
      return S_OK;
  }
}

}  // namespace commands

// Hosts Microsoft's Remote Desktop ActiveX control (mstscax.dll) inside a
// Win32 child window of our own.
//
// This replaces the previous approach, which launched `mstsc.exe` as a child
// process and yanked its top-level window into ours with `SetParent`. That
// worked, but only barely: mstsc re-asserted itself as a top-level window
// behind our back, recreated its session window mid-negotiation (leaving us
// holding a dead HWND), had to be fed credentials through the *global*
// Windows Credential Manager because there was no API to hand them to,
// needed its "unknown publisher" dialog clicked by synthesising button
// messages, and could not change resolution after connecting without a full
// reconnect.
//
// The ActiveX control is the interface Microsoft actually supports for this:
// it is *designed* to be an in-place-activated child of someone else's
// window, so it never fights the container over parenting or z-order; it
// takes the password directly as a property (nothing is written to the user's
// credential store); there is no .rdp file, so no publisher warning exists to
// dismiss; and from version 10 of the control on it exposes
// `UpdateSessionDisplaySettings`, which renegotiates the remote desktop size
// on a live connection -- so a resized pane gets a genuinely re-rendered
// remote desktop instead of a stretched ("smart sized") copy of the old one.
//
// Everything on the control itself is driven through `IDispatch`
// (`GetIDsOfNames` + `Invoke`) rather than the `IMsRdpClient*` vtables. The
// Windows SDK ships no header for those interfaces -- you are expected to
// `#import` the type library -- and hand-declaring them means hand-copying a
// vtable layout that has grown over thirteen control versions, where a single
// misordered slot is a silent call to the wrong function. The dispatch names
// are stable across every version, cost nothing at the rate we use them
// (connection setup, plus one call per resize), and let the same code talk to
// whichever control version a machine happens to have. Only the OLE
// container interfaces, which *are* in the SDK, are used as real vtables.
#ifndef RUNNER_RDP_AX_HOST_H_
#define RUNNER_RDP_AX_HOST_H_

#include <windows.h>
#include <oleidl.h>
#include <ocidl.h>

#include <functional>
#include <memory>
#include <string>

namespace commands {

// What the control tells us about a session, forwarded to Dart.
struct RdpHostEvent {
  std::string type;   // "connecting", "connected", "loggedIn", "closed",
                      // "disconnected", "fatal", "warning", "sizeChanged",
                      // "reconnecting", "reconnected", "logonError"
  std::string message;
  int code = 0;
  int extended_code = 0;
  int width = 0;
  int height = 0;
};

struct RdpConnectParams {
  std::wstring host;
  int port = 3389;
  std::wstring username;
  std::wstring domain;
  std::wstring password;
  int desktop_width = 1280;
  int desktop_height = 800;
  int dpi = 96;
  bool redirect_clipboard = true;
  bool show_wallpaper = false;
  bool redirect_printers = false;
  bool redirect_drives = false;
  bool audio_to_client = true;
  bool console_session = false;
};

class RdpAxHost : public IOleClientSite,
                  public IOleInPlaceSite,
                  public IOleInPlaceFrame,
                  public IOleControlSite,
                  public IDispatch {
 public:
  using EventSink = std::function<void(const RdpHostEvent&)>;

  RdpAxHost();

  // Creates the container window owned by |owner| and in-place activates the
  // newest RDP control the machine has. |bounds| is in physical pixels
  // relative to the owner's client area. Returns false with |error| filled in
  // if either step fails.
  bool Create(HWND owner, const RECT& bounds, std::wstring* error);

  // Re-derives the container's screen position from the owner's current
  // position. Called when the app window itself moves or resizes, which does
  // not change the pane's client-relative rectangle but does change where that
  // rectangle is on screen.
  void FollowOwner();

  // The owner being minimised or restored. An owned window is not hidden
  // automatically in every case, and a session left on screen over a minimised
  // app is worse than one that waits.
  void SetOwnerMinimized(bool minimized);

  // Suspends drawing while the app has a dialog open. The session window is a
  // top-level window owned by the app, which means it is always composited
  // *above* the app -- including above anything Flutter draws, which is the
  // whole point, but also above a modal dialog that is supposed to be in
  // front of everything. Hiding it for the life of the dialog is the trade:
  // the session keeps running, it just isn't on screen while a dialog is.
  void SetSuspended(bool suspended);

  // Applies |params| and starts connecting. Safe to call once per host.
  bool Connect(const RdpConnectParams& params, std::wstring* error);

  // Asks the control to disconnect; the "disconnected" event still fires.
  void Disconnect();

  // Moves/resizes the container (physical pixels, relative to the owner's
  // client area). Does *not* renegotiate the remote resolution -- see
  // ResizeSession for that.
  void SetBounds(const RECT& bounds);

  // Renegotiates the remote desktop size on the live connection. A no-op
  // (returning false) on control versions older than 10, where the caller
  // falls back to the control's own scaling.
  bool ResizeSession(int width, int height, int dpi);

  void SetVisible(bool visible);
  void Focus();
  bool wants_focus() const { return visible_ && connected_; }

  // Ctrl+Alt+Del, which cannot be typed into a windowed session because the
  // local Secure Attention Sequence swallows it.
  void SendCtrlAltDelete();

  void set_event_sink(EventSink sink) { event_sink_ = std::move(sink); }

  HWND window() const { return hwnd_; }
  bool supports_dynamic_resolution() const { return has_client9_; }

  // False means the control's events never reached us, so status would be
  // permanently stuck on "connecting". Checked right after Create.
  bool events_connected() const { return advise_cookie_ != 0; }

  // Tears down the control and the container window.
  void Destroy();

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IOleClientSite
  HRESULT STDMETHODCALLTYPE SaveObject() override;
  HRESULT STDMETHODCALLTYPE GetMoniker(DWORD, DWORD, IMoniker**) override;
  HRESULT STDMETHODCALLTYPE GetContainer(IOleContainer**) override;
  HRESULT STDMETHODCALLTYPE ShowObject() override;
  HRESULT STDMETHODCALLTYPE OnShowWindow(BOOL) override;
  HRESULT STDMETHODCALLTYPE RequestNewObjectLayout() override;

  // IOleWindow (shared base of IOleInPlaceSite / IOleInPlaceFrame)
  HRESULT STDMETHODCALLTYPE GetWindow(HWND* out) override;
  HRESULT STDMETHODCALLTYPE ContextSensitiveHelp(BOOL) override;

  // IOleInPlaceSite
  HRESULT STDMETHODCALLTYPE CanInPlaceActivate() override;
  HRESULT STDMETHODCALLTYPE OnInPlaceActivate() override;
  HRESULT STDMETHODCALLTYPE OnUIActivate() override;
  HRESULT STDMETHODCALLTYPE GetWindowContext(IOleInPlaceFrame**,
                                             IOleInPlaceUIWindow**, LPRECT,
                                             LPRECT,
                                             LPOLEINPLACEFRAMEINFO) override;
  HRESULT STDMETHODCALLTYPE Scroll(SIZE) override;
  HRESULT STDMETHODCALLTYPE OnUIDeactivate(BOOL) override;
  HRESULT STDMETHODCALLTYPE OnInPlaceDeactivate() override;
  HRESULT STDMETHODCALLTYPE DiscardUndoState() override;
  HRESULT STDMETHODCALLTYPE DeactivateAndUndo() override;
  HRESULT STDMETHODCALLTYPE OnPosRectChange(LPCRECT) override;

  // IOleInPlaceUIWindow (base of IOleInPlaceFrame)
  HRESULT STDMETHODCALLTYPE GetBorder(LPRECT) override;
  HRESULT STDMETHODCALLTYPE RequestBorderSpace(LPCBORDERWIDTHS) override;
  HRESULT STDMETHODCALLTYPE SetBorderSpace(LPCBORDERWIDTHS) override;
  HRESULT STDMETHODCALLTYPE SetActiveObject(IOleInPlaceActiveObject*,
                                            LPCOLESTR) override;

  // IOleInPlaceFrame
  HRESULT STDMETHODCALLTYPE InsertMenus(HMENU, LPOLEMENUGROUPWIDTHS) override;
  HRESULT STDMETHODCALLTYPE SetMenu(HMENU, HOLEMENU, HWND) override;
  HRESULT STDMETHODCALLTYPE RemoveMenus(HMENU) override;
  HRESULT STDMETHODCALLTYPE SetStatusText(LPCOLESTR) override;
  HRESULT STDMETHODCALLTYPE EnableModeless(BOOL) override;
  HRESULT STDMETHODCALLTYPE TranslateAccelerator(LPMSG, WORD) override;

  // IOleControlSite
  HRESULT STDMETHODCALLTYPE OnControlInfoChanged() override;
  HRESULT STDMETHODCALLTYPE LockInPlaceActive(BOOL) override;
  HRESULT STDMETHODCALLTYPE GetExtendedControl(IDispatch**) override;
  HRESULT STDMETHODCALLTYPE TransformCoords(POINTL*, POINTF*, DWORD) override;
  HRESULT STDMETHODCALLTYPE TranslateAccelerator(LPMSG, DWORD) override;
  HRESULT STDMETHODCALLTYPE OnFocus(BOOL) override;
  HRESULT STDMETHODCALLTYPE ShowPropertyFrame() override;

  // IDispatch -- the control's event sink. Only Invoke is meaningful; the
  // control calls us by DISPID, so there is nothing to describe.
  HRESULT STDMETHODCALLTYPE GetTypeInfoCount(UINT*) override;
  HRESULT STDMETHODCALLTYPE GetTypeInfo(UINT, LCID, ITypeInfo**) override;
  HRESULT STDMETHODCALLTYPE GetIDsOfNames(REFIID, LPOLESTR*, UINT, LCID,
                                          DISPID*) override;
  HRESULT STDMETHODCALLTYPE Invoke(DISPID, REFIID, LCID, WORD, DISPPARAMS*,
                                   VARIANT*, EXCEPINFO*, UINT*) override;

 private:
  ~RdpAxHost();

  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  static void EnsureWindowClass();

  bool CreateControl(std::wstring* error);
  bool AdviseEvents();
  void UnadviseEvents();
  void Emit(const RdpHostEvent& event);

  // Walks the AdvancedSettings9..2 chain and returns the newest one present.
  // Every version exposes a superset of the last, so one dispatch pointer
  // covers every property we set.
  IDispatch* GetAdvancedSettings();
  IDispatch* GetSecuredSettings();

  std::wstring DescribeDisconnect(int reason, int* extended);

  // Applies client_bounds_ to the container's actual screen position, clamped
  // to whatever of the owner's client area is currently on screen.
  void ApplyPosition();

  LONG ref_count_ = 1;
  HWND hwnd_ = nullptr;
  HWND owner_ = nullptr;

  // The pane's rectangle in the owner's client coordinates, kept because the
  // container is a top-level window and its real position has to be recomputed
  // whenever the app window moves.
  RECT client_bounds_ = {};

  // Shows only when all three agree. Kept as separate reasons rather than one
  // flag so that, say, restoring the window while a dialog is still open does
  // not put the session back on top of the dialog.
  bool owner_minimized_ = false;
  bool suspended_ = false;

  // Applies visible_ / owner_minimized_ / suspended_ to the window.
  void UpdateVisibility();

  IUnknown* control_ = nullptr;
  IDispatch* dispatch_ = nullptr;
  IOleObject* ole_object_ = nullptr;
  IOleInPlaceObject* in_place_object_ = nullptr;
  IDispatch* advanced_settings_ = nullptr;
  IConnectionPoint* connection_point_ = nullptr;
  DWORD advise_cookie_ = 0;

  // The control's event dispinterface (IMsTscAxEvents). Connecting a sink
  // means answering QueryInterface for *this* IID with our IDispatch --
  // IConnectionPoint::Advise asks the sink for the source interface, not for
  // IID_IDispatch, and refuses to connect a sink that says it has no such
  // interface. Learnt the hard way: without this the control was created and
  // activated fine, connected fine, and reported nothing at all.
  IID source_iid_ = GUID_NULL;

  bool has_client9_ = false;  // UpdateSessionDisplaySettings available
  bool visible_ = true;
  bool connected_ = false;
  bool connect_called_ = false;

  // Whether this app asked for the disconnect. The control's own reason code
  // cannot be used to tell an intentional close from a failure: a rejected
  // password and a deliberate `Disconnect()` both arrive as reason 1 ("local
  // disconnection"), so without tracking who started it, every failed logon
  // reads as "session ended normally".
  bool local_disconnect_requested_ = false;
  int control_version_ = 0;

  EventSink event_sink_;
};

}  // namespace commands

#endif  // RUNNER_RDP_AX_HOST_H_

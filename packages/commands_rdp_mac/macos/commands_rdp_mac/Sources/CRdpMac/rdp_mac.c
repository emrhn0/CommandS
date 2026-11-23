// See include/rdp_mac.h.
#include "rdp_mac.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/error.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <freerdp/settings.h>
#include <freerdp/event.h>
#include <winpr/synch.h>
#include <winpr/string.h>

#define CF_UNICODETEXT_ID 13

typedef struct {
  rdpClientContext common;
  CmdRdpSession* session;
  DispClientContext* disp;
  CliprdrClientContext* clip;
  BOOL disp_ready;
} CmdContext;

struct CmdRdpSession {
  CmdRdpCallbacks cb;
  rdpContext* context;
  pthread_t thread;
  BOOL thread_started;
  BOOL auth_failed;
  BOOL cert_changed;
  pthread_mutex_t lock;
  char* local_text;  // offered to the server, guarded by lock
  int pending_width, pending_height;  // resize asked for before disp was ready
};

static CmdRdpSession* session_of(rdpContext* context) {
  return context ? ((CmdContext*)context)->session : NULL;
}

// ---- painting ----

static BOOL cmd_begin_paint(rdpContext* context) {
  rdpGdi* gdi = context->gdi;
  if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd &&
      gdi->primary->hdc->hwnd->invalid)
    gdi->primary->hdc->hwnd->invalid->null = TRUE;
  return TRUE;
}

static BOOL cmd_end_paint(rdpContext* context) {
  CmdRdpSession* s = session_of(context);
  rdpGdi* gdi = context->gdi;
  if (!s || !gdi || !gdi->primary || !gdi->primary->hdc) return TRUE;
  HGDI_WND hwnd = gdi->primary->hdc->hwnd;
  if (hwnd && hwnd->invalid && hwnd->invalid->null) return TRUE;
  if (s->cb.frame)
    s->cb.frame(s->cb.user, gdi->primary_buffer, gdi->width, gdi->height, (int)gdi->stride);
  return TRUE;
}

static BOOL cmd_desktop_resize(rdpContext* context) {
  CmdRdpSession* s = session_of(context);
  rdpSettings* settings = context->settings;
  UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
  UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
  if (!gdi_resize(context->gdi, w, h)) return FALSE;
  if (s && s->cb.resized) s->cb.resized(s->cb.user, (int)w, (int)h);
  return TRUE;
}

// ---- display control (dynamic resolution) ----

static void send_layout(CmdContext* ctx, int width, int height) {
  if (!ctx->disp || !ctx->disp_ready || width < 200 || height < 200) return;
  DISPLAY_CONTROL_MONITOR_LAYOUT layout = {0};
  layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
  layout.Width = (UINT32)(width & ~1);
  layout.Height = (UINT32)height;
  layout.Orientation = ORIENTATION_LANDSCAPE;
  layout.DesktopScaleFactor = 100;
  layout.DeviceScaleFactor = 100;
  layout.PhysicalWidth = 0;
  layout.PhysicalHeight = 0;
  (void)ctx->disp->SendMonitorLayout(ctx->disp, 1, &layout);
}

static UINT cmd_disp_caps(DispClientContext* disp, UINT32 maxMonitors, UINT32 a, UINT32 b) {
  WINPR_UNUSED(maxMonitors);
  WINPR_UNUSED(a);
  WINPR_UNUSED(b);
  CmdContext* ctx = (CmdContext*)disp->custom;
  if (!ctx) return CHANNEL_RC_OK;
  ctx->disp_ready = TRUE;
  CmdRdpSession* s = ctx->session;
  pthread_mutex_lock(&s->lock);
  int w = s->pending_width, h = s->pending_height;
  s->pending_width = s->pending_height = 0;
  pthread_mutex_unlock(&s->lock);
  if (w && h) send_layout(ctx, w, h);
  return CHANNEL_RC_OK;
}

// ---- clipboard (text only) ----

static UINT clip_send_format_list(CliprdrClientContext* clip, BOOL has_text) {
  CLIPRDR_FORMAT format = {.formatId = CF_UNICODETEXT_ID, .formatName = NULL};
  CLIPRDR_FORMAT_LIST list = {0};
  list.common.msgType = CB_FORMAT_LIST;
  list.numFormats = has_text ? 1 : 0;
  list.formats = has_text ? &format : NULL;
  return clip->ClientFormatList(clip, &list);
}

static UINT clip_monitor_ready(CliprdrClientContext* clip, const CLIPRDR_MONITOR_READY* ready) {
  WINPR_UNUSED(ready);
  CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
  general.capabilitySetType = CB_CAPSTYPE_GENERAL;
  general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
  general.version = CB_CAPS_VERSION_2;
  general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
  CLIPRDR_CAPABILITIES caps = {0};
  caps.cCapabilitiesSets = 1;
  caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
  UINT rc = clip->ClientCapabilities(clip, &caps);
  if (rc != CHANNEL_RC_OK) return rc;
  CmdContext* ctx = (CmdContext*)clip->custom;
  BOOL has_text = FALSE;
  if (ctx) {
    pthread_mutex_lock(&ctx->session->lock);
    has_text = ctx->session->local_text != NULL;
    pthread_mutex_unlock(&ctx->session->lock);
  }
  return clip_send_format_list(clip, has_text);
}

static UINT clip_server_caps(CliprdrClientContext* clip, const CLIPRDR_CAPABILITIES* caps) {
  WINPR_UNUSED(clip);
  WINPR_UNUSED(caps);
  return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext* clip, const CLIPRDR_FORMAT_LIST* list) {
  CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
  response.common.msgType = CB_FORMAT_LIST_RESPONSE;
  response.common.msgFlags = CB_RESPONSE_OK;
  UINT rc = clip->ClientFormatListResponse(clip, &response);
  if (rc != CHANNEL_RC_OK) return rc;
  for (UINT32 i = 0; i < list->numFormats; i++) {
    if (list->formats[i].formatId == CF_UNICODETEXT_ID) {
      CLIPRDR_FORMAT_DATA_REQUEST request = {0};
      request.common.msgType = CB_FORMAT_DATA_REQUEST;
      request.requestedFormatId = CF_UNICODETEXT_ID;
      return clip->ClientFormatDataRequest(clip, &request);
    }
  }
  return CHANNEL_RC_OK;
}

static UINT clip_server_format_list_response(CliprdrClientContext* clip,
                                             const CLIPRDR_FORMAT_LIST_RESPONSE* response) {
  WINPR_UNUSED(clip);
  WINPR_UNUSED(response);
  return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext* clip,
                                     const CLIPRDR_FORMAT_DATA_REQUEST* request) {
  CmdContext* ctx = (CmdContext*)clip->custom;
  CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
  response.common.msgType = CB_FORMAT_DATA_RESPONSE;
  response.common.msgFlags = CB_RESPONSE_FAIL;
  WCHAR* wide = NULL;
  size_t wide_len = 0;
  if (ctx && request->requestedFormatId == CF_UNICODETEXT_ID) {
    pthread_mutex_lock(&ctx->session->lock);
    if (ctx->session->local_text)
      wide = ConvertUtf8ToWCharAlloc(ctx->session->local_text, &wide_len);
    pthread_mutex_unlock(&ctx->session->lock);
  }
  if (wide) {
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = (UINT32)((wide_len + 1) * sizeof(WCHAR));
    response.requestedFormatData = (const BYTE*)wide;
  }
  UINT rc = clip->ClientFormatDataResponse(clip, &response);
  free(wide);
  return rc;
}

static UINT clip_server_data_response(CliprdrClientContext* clip,
                                      const CLIPRDR_FORMAT_DATA_RESPONSE* response) {
  CmdContext* ctx = (CmdContext*)clip->custom;
  if (!ctx || response->common.msgFlags != CB_RESPONSE_OK || !response->requestedFormatData)
    return CHANNEL_RC_OK;
  size_t chars = response->common.dataLen / sizeof(WCHAR);
  if (chars == 0) return CHANNEL_RC_OK;
  size_t len = 0;
  char* utf8 = ConvertWCharNToUtf8Alloc((const WCHAR*)response->requestedFormatData, chars, &len);
  if (utf8) {
    CmdRdpSession* s = ctx->session;
    if (s->cb.remote_text) s->cb.remote_text(s->cb.user, utf8);
    free(utf8);
  }
  return CHANNEL_RC_OK;
}

// ---- channels ----

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* e) {
  CmdContext* ctx = (CmdContext*)context;
  if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    ctx->disp = (DispClientContext*)e->pInterface;
    ctx->disp->custom = ctx;
    ctx->disp->DisplayControlCaps = cmd_disp_caps;
  } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    CliprdrClientContext* clip = (CliprdrClientContext*)e->pInterface;
    ctx->clip = clip;
    clip->custom = ctx;
    clip->MonitorReady = clip_monitor_ready;
    clip->ServerCapabilities = clip_server_caps;
    clip->ServerFormatList = clip_server_format_list;
    clip->ServerFormatListResponse = clip_server_format_list_response;
    clip->ServerFormatDataRequest = clip_server_data_request;
    clip->ServerFormatDataResponse = clip_server_data_response;
  } else {
    freerdp_client_OnChannelConnectedEventHandler(context, e);
  }
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e) {
  CmdContext* ctx = (CmdContext*)context;
  if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    if (ctx->disp) ctx->disp->custom = NULL;
    ctx->disp = NULL;
    ctx->disp_ready = FALSE;
  } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    if (ctx->clip) ctx->clip->custom = NULL;
    ctx->clip = NULL;
  } else {
    freerdp_client_OnChannelDisconnectedEventHandler(context, e);
  }
}

// ---- connection callbacks ----

static BOOL cmd_pre_connect(freerdp* instance) {
  rdpSettings* settings = instance->context->settings;
  if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH))
    return FALSE;
  if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
    return FALSE;
  if (PubSub_SubscribeChannelConnected(instance->context->pubSub, on_channel_connected) < 0)
    return FALSE;
  if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub, on_channel_disconnected) < 0)
    return FALSE;
  return TRUE;
}

static BOOL cmd_post_connect(freerdp* instance) {
  if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
  rdpUpdate* update = instance->context->update;
  update->BeginPaint = cmd_begin_paint;
  update->EndPaint = cmd_end_paint;
  update->DesktopResize = cmd_desktop_resize;
  CmdRdpSession* s = session_of(instance->context);
  if (s && s->cb.state) s->cb.state(s->cb.user, CMD_RDP_CONNECTED, NULL, 0);
  return TRUE;
}

static void cmd_post_disconnect(freerdp* instance) {
  if (!instance || !instance->context) return;
  PubSub_UnsubscribeChannelConnected(instance->context->pubSub, on_channel_connected);
  PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, on_channel_disconnected);
  gdi_free(instance);
}

// Credentials missing or refused: never prompt on a terminal. The pane asks.
static BOOL cmd_authenticate(freerdp* instance, char** username, char** password, char** domain,
                             rdp_auth_reason reason) {
  WINPR_UNUSED(username);
  WINPR_UNUSED(domain);
  CmdRdpSession* s = session_of(instance->context);
  if ((reason == AUTH_NLA || reason == AUTH_TLS || reason == AUTH_RDP || reason == AUTH_RDSTLS) &&
      password && *password && **password) {
    // A password is set; FreeRDP only asks to confirm the rest. Carry on.
    return TRUE;
  }
  if (s) s->auth_failed = TRUE;
  return FALSE;
}

// A certificate never seen before for this host: remembered without a
// question (trust on first use, like SSH's known_hosts).
static DWORD cmd_verify_certificate(freerdp* instance, const char* host, UINT16 port,
                                    const char* common_name, const char* subject,
                                    const char* issuer, const char* fingerprint, DWORD flags) {
  WINPR_UNUSED(instance);
  WINPR_UNUSED(host);
  WINPR_UNUSED(port);
  WINPR_UNUSED(common_name);
  WINPR_UNUSED(subject);
  WINPR_UNUSED(issuer);
  WINPR_UNUSED(fingerprint);
  WINPR_UNUSED(flags);
  return 1;
}

// A different certificate than the one remembered: stop rather than let
// someone in between read the session.
static DWORD cmd_verify_changed_certificate(freerdp* instance, const char* host, UINT16 port,
                                            const char* common_name, const char* subject,
                                            const char* issuer, const char* new_fingerprint,
                                            const char* old_subject, const char* old_issuer,
                                            const char* old_fingerprint, DWORD flags) {
  WINPR_UNUSED(host);
  WINPR_UNUSED(port);
  WINPR_UNUSED(common_name);
  WINPR_UNUSED(subject);
  WINPR_UNUSED(issuer);
  WINPR_UNUSED(new_fingerprint);
  WINPR_UNUSED(old_subject);
  WINPR_UNUSED(old_issuer);
  WINPR_UNUSED(old_fingerprint);
  WINPR_UNUSED(flags);
  CmdRdpSession* s = session_of(instance->context);
  if (s) s->cert_changed = TRUE;
  return 0;
}

static int cmd_logon_error_info(freerdp* instance, UINT32 data, UINT32 type) {
  WINPR_UNUSED(instance);
  WINPR_UNUSED(data);
  WINPR_UNUSED(type);
  return 1;
}

static BOOL cmd_client_new(freerdp* instance, rdpContext* context) {
  WINPR_UNUSED(context);
  instance->PreConnect = cmd_pre_connect;
  instance->PostConnect = cmd_post_connect;
  instance->PostDisconnect = cmd_post_disconnect;
  instance->AuthenticateEx = cmd_authenticate;
  instance->VerifyCertificateEx = cmd_verify_certificate;
  instance->VerifyChangedCertificateEx = cmd_verify_changed_certificate;
  instance->LogonErrorInfo = cmd_logon_error_info;
  return TRUE;
}

static void cmd_client_free(freerdp* instance, rdpContext* context) {
  WINPR_UNUSED(instance);
  WINPR_UNUSED(context);
}

static int cmd_client_start(rdpContext* context) {
  WINPR_UNUSED(context);
  return 0;
}

static int cmd_client_stop(rdpContext* context) {
  WINPR_UNUSED(context);
  return 0;
}

// ---- the session thread ----

static BOOL is_auth_error(UINT32 code) {
  switch (code) {
    case FREERDP_ERROR_AUTHENTICATION_FAILED:
    case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
    case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
    case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
      return TRUE;
    default:
      return FALSE;
  }
}

static BOOL is_normal_end(UINT32 code) {
  switch (code) {
    case FREERDP_ERROR_SUCCESS:
    case FREERDP_ERROR_RPC_INITIATED_DISCONNECT:
    case FREERDP_ERROR_RPC_INITIATED_LOGOFF:
    case FREERDP_ERROR_LOGOFF_BY_USER:
    case FREERDP_ERROR_CONNECT_CANCELLED:
      return TRUE;
    default:
      return FALSE;
  }
}

static void report_end(CmdRdpSession* s, UINT32 code, BOOL connected) {
  if (!s->cb.state) return;
  if (s->cert_changed) {
    s->cb.state(s->cb.user, CMD_RDP_ERROR,
                "The server's certificate is not the one it had before. The connection was "
                "stopped, as someone in between could be reading it.",
                0);
    return;
  }
  if (s->auth_failed || is_auth_error(code)) {
    s->cb.state(s->cb.user, CMD_RDP_ERROR, "The user name or password was not accepted.", 1);
    return;
  }
  if (connected && is_normal_end(code)) {
    s->cb.state(s->cb.user, CMD_RDP_CLOSED, NULL, 0);
    return;
  }
  if (!connected && code == FREERDP_ERROR_CONNECT_CANCELLED) {
    s->cb.state(s->cb.user, CMD_RDP_CLOSED, NULL, 0);
    return;
  }
  const char* text = freerdp_get_last_error_string(code);
  s->cb.state(s->cb.user, CMD_RDP_ERROR, text && *text ? text : "The connection failed.", 0);
}

static void* session_thread(void* arg) {
  CmdRdpSession* s = (CmdRdpSession*)arg;
  rdpContext* context = s->context;
  freerdp* instance = context->instance;
  BOOL connected = freerdp_connect(instance);
  if (connected) {
    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {0};
    while (!freerdp_shall_disconnect_context(context)) {
      DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
      if (count == 0) break;
      DWORD status = WaitForMultipleObjects(count, handles, FALSE, 250);
      if (status == WAIT_FAILED) break;
      if (!freerdp_check_event_handles(context)) {
        // Auto-reconnect if the network dropped and the server allows it.
        if (client_auto_reconnect_ex(instance, NULL)) continue;
        break;
      }
    }
  }
  UINT32 code = freerdp_get_last_error(context);
  freerdp_disconnect(instance);
  report_end(s, code, connected);
  return NULL;
}

static BOOL set_string(rdpSettings* settings, FreeRDP_Settings_Keys_String key, const char* v) {
  return freerdp_settings_set_string(settings, key, v && *v ? v : NULL);
}

CmdRdpSession* cmd_rdp_start(const CmdRdpOptions* o, const CmdRdpCallbacks* callbacks) {
  CmdRdpSession* s = calloc(1, sizeof(CmdRdpSession));
  if (!s) return NULL;
  s->cb = *callbacks;
  pthread_mutex_init(&s->lock, NULL);

  RDP_CLIENT_ENTRY_POINTS entry = {0};
  entry.Version = RDP_CLIENT_INTERFACE_VERSION;
  entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
  entry.ContextSize = sizeof(CmdContext);
  entry.ClientNew = cmd_client_new;
  entry.ClientFree = cmd_client_free;
  entry.ClientStart = cmd_client_start;
  entry.ClientStop = cmd_client_stop;
  rdpContext* context = freerdp_client_context_new(&entry);
  if (!context) goto fail;
  ((CmdContext*)context)->session = s;
  s->context = context;

  rdpSettings* st = context->settings;
  BOOL ok = set_string(st, FreeRDP_ServerHostname, o->host) &&
            freerdp_settings_set_uint32(st, FreeRDP_ServerPort, (UINT32)o->port) &&
            set_string(st, FreeRDP_Username, o->username) &&
            set_string(st, FreeRDP_Domain, o->domain) &&
            set_string(st, FreeRDP_Password, o->password) &&
            set_string(st, FreeRDP_ConfigPath, o->config_dir) &&
            freerdp_settings_set_uint32(st, FreeRDP_DesktopWidth, (UINT32)o->width) &&
            freerdp_settings_set_uint32(st, FreeRDP_DesktopHeight, (UINT32)o->height) &&
            freerdp_settings_set_uint32(st, FreeRDP_ColorDepth, 32) &&
            freerdp_settings_set_bool(st, FreeRDP_SupportDisplayControl, TRUE) &&
            freerdp_settings_set_bool(st, FreeRDP_DynamicResolutionUpdate, TRUE) &&
            freerdp_settings_set_bool(st, FreeRDP_SupportGraphicsPipeline, TRUE) &&
            freerdp_settings_set_bool(st, FreeRDP_GfxH264, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_GfxAVC444, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_GfxAVC444v2, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_RedirectClipboard, o->clipboard ? TRUE : FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_DisableWallpaper, o->wallpaper ? FALSE : TRUE) &&
            freerdp_settings_set_bool(st, FreeRDP_AllowFontSmoothing, TRUE) &&
            freerdp_settings_set_bool(st, FreeRDP_AutoReconnectionEnabled, TRUE) &&
            // A dropped network is retried a few times, not the default 20: each
            // try logs in again, and a password changed meanwhile would lock the
            // account.
            freerdp_settings_set_uint32(st, FreeRDP_AutoReconnectMaxRetries, 3) &&
            // Nothing of the Mac's is redirected (drives, ports, smart cards,
            // printers); only the clipboard, when the connection allows it.
            freerdp_settings_set_bool(st, FreeRDP_RedirectDrives, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_RedirectHomeDrive, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_RedirectSerialPorts, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_RedirectParallelPorts, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_RedirectSmartCards, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_RedirectPrinters, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_AudioCapture, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_AudioPlayback, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_RemoteConsoleAudio, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_IgnoreCertificate, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_AutoAcceptCertificate, FALSE) &&
            freerdp_settings_set_bool(st, FreeRDP_CertificateCallbackPreferPEM, FALSE) &&
            freerdp_set_connection_type(st, CONNECTION_TYPE_AUTODETECT);
  if (!ok) goto fail;

  if (pthread_create(&s->thread, NULL, session_thread, s) != 0) goto fail;
  s->thread_started = TRUE;
  return s;

fail:
  if (s->context) freerdp_client_context_free(s->context);
  pthread_mutex_destroy(&s->lock);
  free(s);
  return NULL;
}

static rdpInput* input_of(CmdRdpSession* s) {
  return (s && s->context) ? s->context->input : NULL;
}

void cmd_rdp_key(CmdRdpSession* s, int down, int repeat, uint32_t scancode) {
  rdpInput* input = input_of(s);
  if (!input) return;
  UINT32 code = MAKE_RDP_SCANCODE(scancode & 0xFF, (scancode & 0x100) ? TRUE : FALSE);
  (void)freerdp_input_send_keyboard_event_ex(input, down ? TRUE : FALSE, repeat ? TRUE : FALSE, code);
}

void cmd_rdp_mouse(CmdRdpSession* s, uint16_t flags, uint16_t x, uint16_t y) {
  rdpInput* input = input_of(s);
  if (!input) return;
  (void)freerdp_input_send_mouse_event(input, flags, x, y);
}

void cmd_rdp_ctrl_alt_del(CmdRdpSession* s) {
  rdpInput* input = input_of(s);
  if (!input) return;
  (void)freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, RDP_SCANCODE_LCONTROL);
  (void)freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, RDP_SCANCODE_LMENU);
  (void)freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, RDP_SCANCODE_DELETE);
  (void)freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, RDP_SCANCODE_DELETE);
  (void)freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, RDP_SCANCODE_LMENU);
  (void)freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, RDP_SCANCODE_LCONTROL);
}

void cmd_rdp_resize(CmdRdpSession* s, int width, int height) {
  if (!s || !s->context) return;
  CmdContext* ctx = (CmdContext*)s->context;
  if (!ctx->disp || !ctx->disp_ready) {
    pthread_mutex_lock(&s->lock);
    s->pending_width = width;
    s->pending_height = height;
    pthread_mutex_unlock(&s->lock);
    return;
  }
  send_layout(ctx, width, height);
}

void cmd_rdp_set_local_text(CmdRdpSession* s, const char* utf8) {
  if (!s || !s->context) return;
  pthread_mutex_lock(&s->lock);
  free(s->local_text);
  s->local_text = (utf8 && *utf8) ? strdup(utf8) : NULL;
  BOOL has_text = s->local_text != NULL;
  pthread_mutex_unlock(&s->lock);
  CmdContext* ctx = (CmdContext*)s->context;
  if (ctx->clip) (void)clip_send_format_list(ctx->clip, has_text);
}

void cmd_rdp_stop(CmdRdpSession* s) {
  if (!s) return;
  // No more callbacks into a plugin that is letting go of this session.
  s->cb.frame = NULL;
  s->cb.state = NULL;
  s->cb.resized = NULL;
  s->cb.remote_text = NULL;
  if (s->context) freerdp_abort_connect_context(s->context);
  if (s->thread_started) pthread_join(s->thread, NULL);
  if (s->context) freerdp_client_context_free(s->context);
  pthread_mutex_lock(&s->lock);
  free(s->local_text);
  s->local_text = NULL;
  pthread_mutex_unlock(&s->lock);
  pthread_mutex_destroy(&s->lock);
  free(s);
}

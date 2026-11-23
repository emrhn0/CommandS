// The RDP engine behind an embedded macOS session: a thin C layer over
// FreeRDP, so the Swift plugin never touches FreeRDP's structs. One
// CmdRdpSession is one connection, run on a thread of its own.
#ifndef COMMANDS_RDP_MAC_H
#define COMMANDS_RDP_MAC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmdRdpSession CmdRdpSession;

enum {
  CMD_RDP_CONNECTED = 1,
  CMD_RDP_CLOSED = 2,  // ended normally: logged off, disconnected from inside
  CMD_RDP_ERROR = 3,
};

// Every callback runs on the session's own thread.
typedef struct {
  void* user;
  // The desktop after a paint: BGRA, `stride` bytes per row. Only valid during
  // the call.
  void (*frame)(void* user, const uint8_t* pixels, int width, int height, int stride);
  // state: CMD_RDP_*. `message` is null or UTF-8, only valid during the call.
  // `auth_failed`: the server refused the user name or password.
  void (*state)(void* user, int state, const char* message, int auth_failed);
  // The remote desktop changed size.
  void (*resized)(void* user, int width, int height);
  // Text the remote side put on its clipboard, UTF-8.
  void (*remote_text)(void* user, const char* utf8);
} CmdRdpCallbacks;

typedef struct {
  const char* host;
  int port;
  const char* username;
  const char* domain;
  const char* password;
  int width;
  int height;
  int clipboard;
  int wallpaper;
  // Where FreeRDP keeps the certificates it has seen (trust on first use).
  const char* config_dir;
} CmdRdpOptions;

// Starts connecting; null if the session could not be set up at all.
CmdRdpSession* cmd_rdp_start(const CmdRdpOptions* options, const CmdRdpCallbacks* callbacks);

// Input. `scancode` carries the extended (E0) flag in bit 8.
void cmd_rdp_key(CmdRdpSession* s, int down, int repeat, uint32_t scancode);
void cmd_rdp_mouse(CmdRdpSession* s, uint16_t flags, uint16_t x, uint16_t y);
void cmd_rdp_ctrl_alt_del(CmdRdpSession* s);

// Asks the server to re-render at this size (display control channel).
void cmd_rdp_resize(CmdRdpSession* s, int width, int height);

// Offers this text to the remote clipboard.
void cmd_rdp_set_local_text(CmdRdpSession* s, const char* utf8);

// Disconnects, waits for the thread, frees everything. No callback runs after
// this returns.
void cmd_rdp_stop(CmdRdpSession* s);

#ifdef __cplusplus
}
#endif

#endif

import Carbon
import Cocoa
import CoreVideo
import CRdpMac
import FlutterMacOS

/// Embedded RDP for the macOS app: each session is a FreeRDP connection
/// (see CRdpMac/rdp_mac.c) painting into a Flutter texture, so the remote
/// desktop is drawn inside its tab the way the ActiveX control is on Windows.
public class CommandsRdpMacPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private var sessions: [Int: RdpMacSession] = [:]
  private var nextId = 1

  init(channel: FlutterMethodChannel, textures: FlutterTextureRegistry) {
    self.channel = channel
    self.textures = textures
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "commands/rdp_mac", binaryMessenger: registrar.messenger)
    let instance = CommandsRdpMacPlugin(channel: channel, textures: registrar.textures)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "available" {
      result(true)
      return
    }
    if call.method == "connect" {
      connect(args, result: result)
      return
    }
    guard let id = args["id"] as? Int, let session = sessions[id] else {
      // A session that already ended: nothing to do.
      result(nil)
      return
    }
    switch call.method {
    case "key":
      session.key(
        scancode: UInt32(args["scancode"] as? Int ?? 0),
        down: args["down"] as? Bool ?? false,
        repeating: args["repeat"] as? Bool ?? false)
    case "mouse":
      session.mouse(
        flags: UInt16(truncatingIfNeeded: args["flags"] as? Int ?? 0),
        x: args["x"] as? Int ?? 0, y: args["y"] as? Int ?? 0)
    case "resize":
      session.resize(width: args["width"] as? Int ?? 0, height: args["height"] as? Int ?? 0)
    case "ctrlAltDel":
      session.ctrlAltDel()
    case "focus":
      session.offerPasteboard()
    case "close":
      sessions.removeValue(forKey: id)
      session.stop()
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(nil)
  }

  private func connect(_ args: [String: Any], result: @escaping FlutterResult) {
    let id = nextId
    nextId += 1
    let session = RdpMacSession(id: id, textures: textures) { [weak self] event in
      var payload = event
      payload["id"] = id
      self?.channel.invokeMethod("event", arguments: payload)
    }
    let configDir = Self.configDirectory()
    let started = session.start(
      host: args["host"] as? String ?? "",
      port: args["port"] as? Int ?? 3389,
      username: args["username"] as? String ?? "",
      domain: args["domain"] as? String ?? "",
      password: args["password"] as? String ?? "",
      width: args["width"] as? Int ?? 1280,
      height: args["height"] as? Int ?? 800,
      clipboard: args["clipboard"] as? Bool ?? true,
      wallpaper: args["wallpaper"] as? Bool ?? false,
      configDir: configDir)
    guard started else {
      result(FlutterError(code: "connect", message: "The RDP session could not be set up.", details: nil))
      return
    }
    sessions[id] = session
    result([
      "id": id,
      "textureId": session.textureId,
      "isoKeyboard": KBGetLayoutType(Int16(LMGetKbdType())) == OSType(kKeyboardISO),
    ])
  }

  /// FreeRDP's own files (the certificates it has seen) go next to the app's
  /// other data, not into ~/.config.
  private static func configDirectory() -> String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("CommandS/freerdp", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
  }
}

/// One session: the C engine, and the texture its frames go to.
final class RdpMacSession: NSObject, FlutterTexture {
  let id: Int
  private(set) var textureId: Int64 = 0
  private weak var textures: FlutterTextureRegistry?
  private let emit: ([String: Any]) -> Void

  private var engine: OpaquePointer?
  private var clipboard = false

  // Frames: written on the session thread, read by Flutter's raster thread.
  private let frameLock = NSLock()
  private var latest: CVPixelBuffer?
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var frameQueued = false

  /// The pasteboard as this session last saw it, so text the session itself
  /// put there is not offered straight back.
  private var pasteboardChange = NSPasteboard.general.changeCount

  init(id: Int, textures: FlutterTextureRegistry, emit: @escaping ([String: Any]) -> Void) {
    self.id = id
    self.textures = textures
    self.emit = emit
    super.init()
    textureId = textures.register(self)
  }

  func start(
    host: String, port: Int, username: String, domain: String, password: String,
    width: Int, height: Int, clipboard: Bool, wallpaper: Bool, configDir: String
  ) -> Bool {
    self.clipboard = clipboard
    // The engine holds an unretained pointer to self; `stop` keeps self alive
    // until the session thread has finished.
    let user = Unmanaged.passUnretained(self).toOpaque()
    var callbacks = CmdRdpCallbacks(
      user: user,
      frame: { user, pixels, width, height, stride in
        guard let user, let pixels else { return }
        Unmanaged<RdpMacSession>.fromOpaque(user).takeUnretainedValue()
          .onFrame(pixels, Int(width), Int(height), Int(stride))
      },
      state: { user, state, message, authFailed in
        guard let user else { return }
        let text = message.map { String(cString: $0) } ?? ""
        Unmanaged<RdpMacSession>.fromOpaque(user).takeUnretainedValue()
          .onState(Int(state), text, authFailed != 0)
      },
      resized: { user, width, height in
        guard let user else { return }
        Unmanaged<RdpMacSession>.fromOpaque(user).takeUnretainedValue()
          .send(["type": "size", "width": Int(width), "height": Int(height)])
      },
      remote_text: { user, text in
        guard let user, let text else { return }
        let value = String(cString: text)
        Unmanaged<RdpMacSession>.fromOpaque(user).takeUnretainedValue().onRemoteText(value)
      })
    engine = host.withCString { cHost in
      username.withCString { cUser in
        domain.withCString { cDomain in
          password.withCString { cPassword in
            configDir.withCString { cConfig in
              var options = CmdRdpOptions(
                host: cHost, port: Int32(port), username: cUser, domain: cDomain,
                password: cPassword, width: Int32(width), height: Int32(height),
                clipboard: clipboard ? 1 : 0, wallpaper: wallpaper ? 1 : 0, config_dir: cConfig)
              return cmd_rdp_start(&options, &callbacks)
            }
          }
        }
      }
    }
    if engine == nil {
      textures?.unregisterTexture(textureId)
      return false
    }
    offerPasteboard(force: true)
    return true
  }

  // ---- from the engine (session thread) ----

  private func onFrame(_ pixels: UnsafePointer<UInt8>, _ width: Int, _ height: Int, _ stride: Int) {
    guard width > 0, height > 0 else { return }
    if pool == nil || poolWidth != width || poolHeight != height {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      var newPool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
      pool = newPool
      poolWidth = width
      poolHeight = height
    }
    guard let pool else { return }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
      return
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      let dst = base.assumingMemoryBound(to: UInt8.self)
      let dstStride = CVPixelBufferGetBytesPerRow(buffer)
      let rowBytes = min(width * 4, stride, dstStride)
      if dstStride == stride {
        memcpy(dst, pixels, stride * height)
      } else {
        for row in 0..<height {
          memcpy(dst + row * dstStride, pixels + row * stride, rowBytes)
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    frameLock.lock()
    latest = buffer
    let alreadyQueued = frameQueued
    frameQueued = true
    frameLock.unlock()
    if alreadyQueued { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.frameLock.lock()
      self.frameQueued = false
      self.frameLock.unlock()
      self.textures?.textureFrameAvailable(self.textureId)
    }
  }

  private func onState(_ state: Int, _ message: String, _ authFailed: Bool) {
    switch state {
    case CMD_RDP_CONNECTED:
      send(["type": "connected"])
    case CMD_RDP_CLOSED:
      send(["type": "closed"])
    default:
      send(["type": "error", "message": message, "authFailed": authFailed])
    }
  }

  private func onRemoteText(_ text: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.engine != nil else { return }
      let board = NSPasteboard.general
      board.clearContents()
      board.setString(text, forType: .string)
      self.pasteboardChange = board.changeCount
    }
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.engine != nil else { return }
      self.emit(event)
    }
  }

  // ---- from Flutter (main thread) ----

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    frameLock.lock()
    defer { frameLock.unlock() }
    guard let latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  func key(scancode: UInt32, down: Bool, repeating: Bool) {
    guard let engine else { return }
    cmd_rdp_key(engine, down ? 1 : 0, repeating ? 1 : 0, scancode)
  }

  func mouse(flags: UInt16, x: Int, y: Int) {
    guard let engine else { return }
    cmd_rdp_mouse(engine, flags, UInt16(clamping: max(0, x)), UInt16(clamping: max(0, y)))
  }

  func resize(width: Int, height: Int) {
    guard let engine else { return }
    cmd_rdp_resize(engine, Int32(width), Int32(height))
  }

  func ctrlAltDel() {
    guard let engine else { return }
    cmd_rdp_ctrl_alt_del(engine)
  }

  /// Offers the Mac's clipboard text to the server, if it changed since the
  /// session last looked. Called when the tab gets the keyboard.
  func offerPasteboard(force: Bool = false) {
    guard let engine, clipboard else { return }
    let board = NSPasteboard.general
    if !force && board.changeCount == pasteboardChange { return }
    pasteboardChange = board.changeCount
    guard let text = board.string(forType: .string), !text.isEmpty else { return }
    text.withCString { cmd_rdp_set_local_text(engine, $0) }
  }

  func stop() {
    guard let engine else { return }
    self.engine = nil
    textures?.unregisterTexture(textureId)
    // Disconnecting waits for the network; never on the main thread. The
    // closure keeps self alive until the engine is gone.
    DispatchQueue.global(qos: .utility).async {
      cmd_rdp_stop(engine)
      _ = self
    }
  }
}

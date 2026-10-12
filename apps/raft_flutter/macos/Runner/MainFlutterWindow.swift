import Cocoa
import FlutterMacOS
import CFNetwork

class MainFlutterWindow: NSWindow {
  private var interactionChannel: FlutterMethodChannel?
  private var titleBar: RaftTitleBar?
  private var proxyChannel: FlutterMethodChannel?
  override func awakeFromNib() {
    // Do not restore an old fullscreen/Space state during background launch.
    isRestorable = false
    let flutterViewController = FlutterViewController()
    // The window is ordered in before Flutter's first frame (AppDelegate), and
    // until then FlutterView paints black. Use the stored theme's canvas colour
    // for both so a dark theme does not flash white (or a light one black).
    let canvas = MainFlutterWindow.storedCanvasColor()
    self.backgroundColor = canvas
    flutterViewController.backgroundColor = canvas
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    interactionChannel = FlutterMethodChannel(
      name: "app.raft/interaction",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    interactionChannel?.setMethodCallHandler { call, result in
      if call.method == "doubleClickInterval" {
        result(NSEvent.doubleClickInterval)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    proxyChannel = FlutterMethodChannel(
      name: "app.raft/system-proxy",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    proxyChannel?.setMethodCallHandler { call, result in
      switch call.method {
      case "snapshot":
        result(RaftSystemProxy.snapshot())
      case "resolve":
        guard let url = (call.arguments as? [String: Any])?["url"] as? String else {
          result(FlutterError(code: "invalid", message: "Missing URL.", details: nil))
          return
        }
        RaftSystemProxy.resolve(url) { result($0) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // The app draws the title strip (rail colours, no text) under the
    // transparent system title bar; see docs/desktop-title-bar.md.
    titleBar = RaftTitleBar(
      window: self, messenger: flutterViewController.engine.binaryMessenger)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// `layer-canvas` of the stored appearance. shared_preferences keeps
  /// `raft.mode` / `raft.light` in NSUserDefaults under the `flutter.` prefix.
  /// Dark is always Elegant dark (#141411); every light family's canvas is white.
  private static func storedCanvasColor() -> NSColor {
    let mode = UserDefaults.standard.string(forKey: "flutter.raft.mode") ?? "system"
    var dark = mode == "dark"
    if mode == "system" {
      let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
      dark = match == .darkAqua
    }
    return dark
      ? NSColor(srgbRed: 20.0 / 255.0, green: 20.0 / 255.0, blue: 17.0 / 255.0, alpha: 1)
      : NSColor.white
  }
}

/// The window's title bar on macOS: transparent, over a full-size content
/// view, with the traffic lights left at the top-left where the system puts
/// them. Flutter paints the strip below them (`RaftDesktopTitleBar`), so this
/// reports how tall the system's bar is, whether the window is fullscreen
/// (the system hides the bar then), and does the two things a click on the
/// strip would have done in a native bar: move the window and zoom it.
final class RaftTitleBar: NSObject {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private var observers: [NSObjectProtocol] = []

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "app.raft/titlebar", binaryMessenger: messenger)
    super.init()
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result)
    }
    let names: [NSNotification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.willEnterFullScreenNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.willExitFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ]
    for name in names {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in
          self?.publish()
        })
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// The system title bar's height: what the content view has above the
  /// layout rect. Zero in fullscreen, where the bar is not part of the window.
  private var state: [String: Any] {
    guard let window = window, let content = window.contentView else {
      return ["height": 0, "fullscreen": false]
    }
    let fullscreen = window.styleMask.contains(.fullScreen)
    let height = content.frame.height - window.contentLayoutRect.height
    return [
      "height": fullscreen || !height.isFinite || height < 0 ? 0 : Double(height),
      "fullscreen": fullscreen,
    ]
  }

  private func publish() {
    channel.invokeMethod("state", arguments: state)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(state)
    case "setStyle":
      // Behind the transparent bar and under the Flutter view: what shows
      // while the window resizes, in the strip's own colour.
      if let args = call.arguments as? [String: Any],
        let argb = args["background"] as? Int
      {
        window?.backgroundColor = NSColor(
          srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
          green: CGFloat((argb >> 8) & 0xFF) / 255,
          blue: CGFloat(argb & 0xFF) / 255,
          alpha: 1)
      }
      result(nil)
    case "startDragging":
      if let window = window, let event = NSApp.currentEvent,
        event.type == .leftMouseDown || event.type == .leftMouseDragged
      {
        window.performDrag(with: event)
      }
      result(nil)
    case "doubleClick":
      // The user's System Settings choice for a title bar double-click.
      // "Fill" (macOS 15+) fills the screen's usable area and a second
      // double-click restores; older systems only have the Minimize bool.
      let defaults = UserDefaults.standard
      let action = defaults.string(forKey: "AppleActionOnDoubleClick")
        ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
      switch action {
      case "Minimize": window?.miniaturize(nil)
      case "None": break
      case "Fill": fill()
      default: window?.zoom(nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var frameBeforeFill: NSRect?

  private func fill() {
    guard let window, let visible = window.screen?.visibleFrame else { return }
    if window.frame == visible, let previous = frameBeforeFill {
      frameBeforeFill = nil
      window.setFrame(previous, display: true, animate: true)
    } else {
      frameBeforeFill = window.frame
      window.setFrame(visible, display: true, animate: true)
    }
  }
}

// MARK: - System proxy (shared by iOS and macOS; keep both copies identical)

/// Reads the system HTTP proxy configuration with CFNetwork and answers
/// per-URL proxy lookups, running PAC scripts (`CFNetworkExecuteProxyAutoConfigurationURL`)
/// when the system uses one. Dart caches every answer; nothing here blocks a
/// request. WPAD auto-discovery is not executed (CFNetwork exposes no API for it
/// without the script text), so it is reported as `autoDetect` only.
final class RaftSystemProxy {
  private final class PacRun {
    var source: CFRunLoopSource?
    var finished = false
    let done: ([String]) -> Void
    init(done: @escaping ([String]) -> Void) { self.done = done }
    func finish(_ answer: [String]) {
      if finished { return }
      finished = true
      if let source = source {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
      }
      done(answer)
    }
  }

  static func settings() -> [String: Any] {
    (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
  }

  /// The static part of the configuration, independent of any URL.
  static func snapshot() -> [String: Any] {
    let s = settings()
    func flag(_ key: String) -> Bool { (s[key] as? NSNumber)?.boolValue ?? false }
    func hostPort(_ enable: String, _ host: String, _ port: String, fallback: Int) -> String? {
      guard flag(enable), let h = s[host] as? String, !h.isEmpty else { return nil }
      let p = (s[port] as? NSNumber)?.intValue ?? fallback
      return "\(h):\(p)"
    }
    var out: [String: Any] = [:]
    if let v = hostPort("HTTPEnable", "HTTPProxy", "HTTPPort", fallback: 80) { out["http"] = v }
    if let v = hostPort("HTTPSEnable", "HTTPSProxy", "HTTPSPort", fallback: 80) { out["https"] = v }
    if let v = hostPort("SOCKSEnable", "SOCKSProxy", "SOCKSPort", fallback: 1080) { out["socks"] = v }
    if flag("ProxyAutoConfigEnable"), let pac = s["ProxyAutoConfigURLString"] as? String, !pac.isEmpty {
      out["pacUrl"] = pac
    }
    out["autoDetect"] = flag("ProxyAutoDiscoveryEnable")
    out["bypass"] = (s["ExceptionsList"] as? [String]) ?? []
    out["excludeSimple"] = flag("ExcludeSimpleHostnames")
    return out
  }

  static func lines(_ proxies: [[String: Any]]) -> [String] {
    let none = kCFProxyTypeNone as String
    let http = kCFProxyTypeHTTP as String
    let https = kCFProxyTypeHTTPS as String
    let socks = kCFProxyTypeSOCKS as String
    return proxies.compactMap { entry -> String? in
      guard let type = entry[kCFProxyTypeKey as String] as? String else { return nil }
      let host = entry[kCFProxyHostNameKey as String] as? String
      let port = (entry[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue
      if type == none { return "DIRECT" }
      guard let host = host, let port = port else { return nil }
      // Apple's "HTTPS" proxy is an HTTP proxy used for https URLs (CONNECT).
      if type == http || type == https { return "PROXY \(host):\(port)" }
      if type == socks { return "SOCKS \(host):\(port)" }
      return nil
    }
  }

  /// The system's decision for one URL, PAC evaluated. `done` runs on the main thread.
  static func resolve(_ urlString: String, done: @escaping ([String]) -> Void) {
    guard let url = URL(string: urlString) else { done([]); return }
    let cfProxies = CFNetworkCopyProxiesForURL(url as CFURL, settings() as CFDictionary).takeRetainedValue()
    let proxies = ((cfProxies as [AnyObject]) as? [[String: Any]]) ?? []
    let pacType = kCFProxyTypeAutoConfigurationURL as String
    guard let pac = proxies.first(where: { ($0[kCFProxyTypeKey as String] as? String) == pacType }),
      let pacURL = pac[kCFProxyAutoConfigurationURLKey as String] as? URL
    else {
      done(lines(proxies))
      return
    }
    let pending = PacRun(done: done)
    let retained = Unmanaged.passRetained(pending)
    var context = CFStreamClientContext(
      version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let source = CFNetworkExecuteProxyAutoConfigurationURL(
      pacURL as CFURL, url as CFURL,
      { info, result, _ in
        let run = Unmanaged<PacRun>.fromOpaque(info).takeUnretainedValue()
        let list = ((result as [AnyObject]) as? [[String: Any]]) ?? []
        run.finish(RaftSystemProxy.lines(list))
      }, &context)
    pending.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    // A PAC host that never answers must not leave the lookup open.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      pending.finish([])
      retained.release()
    }
  }
}

import Flutter
import UIKit
import CFNetwork

final class RaftSharingBridge: NSObject, FlutterPlugin {
  private let sessionQueue = DispatchQueue(label: "app.raft.share-access")
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "app.raft/sharing", binaryMessenger: registrar.messenger())
    let bridge = RaftSharingBridge()
    registrar.addMethodCallDelegate(bridge, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "updateShareSession":
      guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "RaftShareKeychainGroup") as? String,
            !accessGroup.isEmpty, !accessGroup.contains("$(") else {
        result(FlutterError(code: "sharing_unavailable", message: "Share account is unavailable.", details: nil)); return
      }
      sessionQueue.async {
        do {
          let session = try (call.arguments as? [String: Any]).map { try ShareAccessSession.parse($0) }
          try ShareSessionVault(accessGroup: accessGroup).replace(session)
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "sharing_unavailable", message: "Share account is unavailable.", details: nil)) }
        }
      }
    case "incomingDirectory":
      guard let group = Bundle.main.object(forInfoDictionaryKey: "RaftAppGroup") as? String else {
        result(FlutterError(code: "sharing_unavailable", message: "The shared inbox is unavailable.", details: nil)); return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let path = try ShareInboxWriter.directory(group: group).path
          DispatchQueue.main.async { result(path) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "sharing_unavailable", message: "The shared inbox is unavailable.", details: nil)) }
        }
      }
    case "share":
      guard let arguments = call.arguments as? [String: Any],
            let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
        result(FlutterError(code: "sharing_unavailable", message: "Open Raft before sharing.", details: nil)); return
      }
      while let presented = controller.presentedViewController { controller = presented }
      var items: [Any] = []
      if let text = arguments["text"] as? String, !text.isEmpty { items.append(text) }
      if let path = arguments["path"] as? String {
        // getTemporaryDirectory on iOS maps to Library/Caches, not /tmp.
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let file = ShareInboxWriter.exportFile(path: path, caches: cache) else {
          result(FlutterError(code: "invalid", message: "Invalid shared file.", details: nil)); return
        }
        items.append(file)
      }
      guard !items.isEmpty else { result(FlutterError(code: "invalid", message: "Nothing to share.", details: nil)); return }
      let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = controller.view
      sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX,
        y: controller.view.bounds.midY, width: 1, height: 1)
      sheet.popoverPresentationController?.permittedArrowDirections = []
      sheet.completionWithItemsHandler = { _, _, _, error in
        if error != nil { result(FlutterError(code: "sharing_failed", message: "System sharing failed.", details: nil)) }
        else { result(nil) }
      }
      controller.present(sheet, animated: true)
    default: result(FlutterMethodNotImplemented)
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

final class RaftProxyBridge: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "app.raft/system-proxy", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(RaftProxyBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "snapshot":
      result(RaftSystemProxy.snapshot())
    case "resolve":
      guard let url = (call.arguments as? [String: Any])?["url"] as? String else {
        result(FlutterError(code: "invalid", message: "Missing URL.", details: nil)); return
      }
      RaftSystemProxy.resolve(url) { result($0) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

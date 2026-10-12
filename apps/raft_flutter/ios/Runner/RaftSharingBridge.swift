import Flutter
import UIKit

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

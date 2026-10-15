import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.registerLaunchHandlers()
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RaftDeviceMemory") {
      FlutterMethodChannel(name: "app.raft/device-memory", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { call, result in
          if call.method == "snapshot" {
            result(["totalBytes": Int64(ProcessInfo.processInfo.physicalMemory)])
          } else {
            result(FlutterMethodNotImplemented)
          }
        }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RaftSharingBridge") {
      RaftSharingBridge.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RaftProxyBridge") {
      RaftProxyBridge.register(with: registrar)
    }
  }
}

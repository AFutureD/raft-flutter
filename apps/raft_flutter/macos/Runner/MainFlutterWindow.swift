import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var interactionChannel: FlutterMethodChannel?
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

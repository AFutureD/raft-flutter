import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Flutter's outlet is weak. Keep the existing window and engine alive when
  // the user closes it, so reopening preserves the current workspace and draft.
  private var retainedMainWindow: NSWindow?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The nib starts invisible. Show behind existing windows without activation,
    // including when a cold launch finishes after the user has switched apps.
    retainedMainWindow = mainFlutterWindow
    retainedMainWindow?.order(.below, relativeTo: 0)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    guard let window = retainedMainWindow ?? mainFlutterWindow else { return true }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

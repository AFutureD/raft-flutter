import Cocoa
import FlutterMacOS
@testable import RaftMacAppDelegate

// No real window is shown: the tests exercise the production delegate, while
// recording the native window operations it requests.
private final class WindowSpy: NSWindow {
  var minimized = false
  var operations: [String] = []

  override var isMiniaturized: Bool { minimized }

  override func deminiaturize(_ sender: Any?) {
    operations.append("restore")
    minimized = false
  }

  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    operations.append("order")
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    operations.append("show")
  }
}

private var failures: [String] = []
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

final class WindowLifecycleTests {
  func testClosingLastWindowKeepsAppRunning() {
    let delegate = AppDelegate()
    check(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared), "last-window close must keep the process running")
  }

  private func reopen(visible: Bool, minimized: Bool = false) {
    let delegate = AppDelegate()
    let window = WindowSpy(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.minimized = minimized
    delegate.mainFlutterWindow = window
    let callback: NSApplicationDelegate = delegate

    check(callback.applicationShouldHandleReopen?(.shared, hasVisibleWindows: visible) == false, "main-window reopen must handle the event")
    check(window.operations == (minimized ? ["restore", "show"] : ["show"]), "reopen must restore/raise the original window")
    check(delegate.mainFlutterWindow === window, "reopen must retain the same window")
  }

  func testLaunchRetainsMainWindow() {
    let delegate = AppDelegate()
    weak var retained: NSWindow?
    autoreleasepool {
      let window = WindowSpy(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      delegate.mainFlutterWindow = window
      retained = window
      delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }
    check(retained != nil, "the main window must survive its weak Flutter outlet")
  }

  func testDockReopenRestoresOriginalClosedWindow() {
    reopen(visible: false)
  }

  func testDockReopenRaisesExistingWindow() {
    reopen(visible: true)
  }

  func testDockReopenDeminiaturizesBeforeShowingWindow() {
    reopen(visible: true, minimized: true)
  }

  func testMissingMainWindowLeavesDefaultReopenHandling() {
    let callback: NSApplicationDelegate = AppDelegate()
    check(callback.applicationShouldHandleReopen?(.shared, hasVisibleWindows: false) == true, "missing window must leave default handling")
  }
}

_ = NSApplication.shared.setActivationPolicy(.prohibited)
let tests = WindowLifecycleTests()
tests.testClosingLastWindowKeepsAppRunning()
tests.testLaunchRetainsMainWindow()
tests.testDockReopenRestoresOriginalClosedWindow()
tests.testDockReopenRaisesExistingWindow()
tests.testDockReopenDeminiaturizesBeforeShowingWindow()
tests.testMissingMainWindowLeavesDefaultReopenHandling()
for failure in failures { print("FAIL: \(failure)") }
print("Native window lifecycle: 6 cases, \(failures.count) failed assertions")
exit(failures.isEmpty ? 0 : 1)

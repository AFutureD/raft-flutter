import Flutter
import UIKit

// Public UIKit alternate-icon API. OS state owns the choice, not a Dart cache.
final class RaftStartupPalette {
  static let colors = ["yellow", "blue", "green", "white", "pink"]
  static let names = ["blue": "AppIconBlue", "green": "AppIconGreen",
                      "white": "AppIconWhite", "pink": "AppIconPink"]
  static func selected() -> String {
    let name = UIApplication.shared.alternateIconName
    return names.first(where: { $0.value == name })?.key ?? "yellow"
  }

  static func startupColor() -> UIColor {
    let hex: UInt32
    switch selected() {
    case "blue": hex = 0x27CCF3
    case "green": hex = 0xA9D877
    case "white": hex = 0xFFFFFF
    case "pink": hex = 0xFE7DA8
    default: hex = 0xFFD440
    }
    return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                   green: CGFloat((hex >> 8) & 255) / 255,
                   blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
}

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    // LaunchScreen itself is fixed and appearance-aware. This view covers only
    // real engine/session initialization and disappears at the first render.
    let startup = UIView()
    startup.backgroundColor = RaftStartupPalette.startupColor()
    let mark = UIImageView(image: UIImage(named: "LaunchMark", in: nil,
                    compatibleWith: UITraitCollection(userInterfaceStyle: .light)))
    mark.translatesAutoresizingMaskIntoConstraints = false
    mark.contentMode = .scaleAspectFit
    startup.addSubview(mark)
    NSLayoutConstraint.activate([
      mark.widthAnchor.constraint(equalToConstant: 120),
      mark.heightAnchor.constraint(equalToConstant: 120),
      mark.centerXAnchor.constraint(equalTo: startup.centerXAnchor),
      mark.centerYAnchor.constraint(equalTo: startup.centerYAnchor)
    ])
    // Flutter's public splashScreenView owns layout and first-render removal;
    // no timer, display callback replacement or extra UIWindow is required.
    controller.splashScreenView = startup
  }
}

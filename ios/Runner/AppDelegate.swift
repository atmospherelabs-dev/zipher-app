import UIKit
import Flutter
import workmanager_apple
import app_links

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 10.0, *) {
        UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "background-sync")
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "ironwood-migration")

    protectWalletDirectory()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // With the UIScene lifecycle, a link that cold-starts the app (zipher://,
  // zcash:, CipherPay checkout) arrives in the scene connection options, which
  // app_links 3.x never reads. Hand it over so getInitialAppLink() returns it.
  // Links opened while the app runs still reach app_links through Flutter.
  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    if let url = options.urlContexts.first?.url {
      AppLinks.shared.handleLink(url: url)
    }
    // FlutterAppDelegate does not implement this method, so calling super
    // throws "unrecognized selector" whenever a new scene session is created
    // (first launch after install). Return the Info.plist configuration.
    return UISceneConfiguration(name: "flutter", sessionRole: connectingSceneSession.role)
  }

  // UIScene lifecycle (required when building with the iOS 27 SDK): the scene
  // delegate creates the Flutter engine, so plugins register here.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    engineBridge.pluginRegistry.registrar(forPlugin: "ZipherLaunchLinks")?
      .addSceneDelegate(LaunchLinkBridge.shared)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZipherPush") {
      PushBridge.register(with: registrar)
    }
  }

  /// Apply NSFileProtectionComplete to the wallet data directory.
  /// Files are encrypted at rest and inaccessible while the device is locked.
  /// Also excludes wallet data from iCloud/iTunes backups.
  private func protectWalletDirectory() {
    let fileManager = FileManager.default
    guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

    let walletDirs = ["zipher_wallet", "zipher_wallet_testnet"]
    for dirName in walletDirs {
      let walletDir = docs.appendingPathComponent(dirName)
      if fileManager.fileExists(atPath: walletDir.path) {
        do {
          try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: walletDir.path
          )
          var resourceValues = URLResourceValues()
          resourceValues.isExcludedFromBackup = true
          var mutableURL = walletDir
          try mutableURL.setResourceValues(resourceValues)
        } catch {
          NSLog("Zipher: failed to set file protection on \(dirName): \(error)")
        }
      }
    }
  }
}

func registerPlugins(registry: FlutterPluginRegistry) {
  GeneratedPluginRegistrant.register(with: registry)
}

/// Relaunching an existing scene session delivers the launch link only to
/// `scene(_:willConnectTo:options:)`, which app_links 3.x does not observe.
final class LaunchLinkBridge: NSObject, FlutterSceneLifeCycleDelegate {
  static let shared = LaunchLinkBridge()

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let url = connectionOptions?.urlContexts.first?.url {
      AppLinks.shared.handleLink(url: url)
    }
    return false
  }
}

/// Opt-in APNs registration for agent approval wake-ups. Dart asks for a token
/// only after the user turned notifications on; the token goes to the relay,
/// never to Atmosphere servers or analytics.
final class PushBridge: NSObject, FlutterPlugin {
  private var pending: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PushBridge()
    let channel = FlutterMethodChannel(name: "zipher/push", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "register":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async {
          guard granted else {
            result(FlutterError(code: "denied", message: "Notifications are not allowed for Zipher", details: nil))
            return
          }
          self.pending?(nil)
          self.pending = result
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
    case "unregister":
      UIApplication.shared.unregisterForRemoteNotifications()
      result(nil)
    case "openSettings":
      if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "isSandbox":
      #if DEBUG
      result(true)
      #else
      result(false)
      #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    pending?(deviceToken.map { String(format: "%02x", $0) }.joined())
    pending = nil
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    pending?(FlutterError(code: "push_unavailable", message: error.localizedDescription, details: nil))
    pending = nil
  }
}

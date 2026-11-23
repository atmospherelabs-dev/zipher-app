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
    return super.application(application, configurationForConnecting: connectingSceneSession, options: options)
  }

  // UIScene lifecycle (required when building with the iOS 27 SDK): the scene
  // delegate creates the Flutter engine, so plugins register here.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    engineBridge.pluginRegistry.registrar(forPlugin: "ZipherLaunchLinks")?
      .addSceneDelegate(LaunchLinkBridge.shared)
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

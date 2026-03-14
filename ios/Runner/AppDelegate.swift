import UIKit
import Flutter
import workmanager

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if #available(iOS 10.0, *) {
        UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    WorkmanagerPlugin.registerTask(withIdentifier: "background-sync")

    protectWalletDirectory()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

import 'dart:async';
import 'dart:convert';

import 'package:zipher/router.dart';
import 'package:zipher/services/secure_key_store.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/warp_api.dart';
import 'package:workmanager/workmanager.dart';

import '../../accounts.dart';
import 'accounts/send.dart';
import 'settings.dart';
import 'utils.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../settings.pb.dart';
import '../init.dart';
import '../store2.dart';
import '../zipher_theme.dart';

class SplashPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _SplashState();
}

class _SplashState extends State<SplashPage> {
  late final s = S.of(context);
  final progressKey = GlobalKey<_LoadProgressState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future(() async {
        try {
          if (!GetIt.I.isRegistered<S>()) {
            GetIt.I.registerSingleton<S>(S.of(context));
          }
          if (!appSettings.hasMemo()) appSettings.memo = s.sendFrom(APP_NAME);
          // Reset active account so stale mainnet data doesn't leak into testnet
          aa = nullAccount;
          _initProver();
          // Ensure active coin paths are set (needed after testnet toggle)
          await initCoins();
          // await _setupMempool();
          final applinkUri = await _registerURLHandler();
          final quickAction = await _registerQuickActions();
          _initWallets();
          await _migrateSeedsToKeychain();
          await _restoreActive();
          await _loadKeysFromKeychain();
          initSyncListener();
          // _initForegroundTask();
          await _initBackgroundSync();
          _initAccel();
          final protectOpen = appSettings.protectOpen;
          if (protectOpen) {
            await authBarrier(context);
          }
          appStore.initialized = true;
          // If no account exists (e.g. first time on testnet), go to welcome
          if (aa.id == 0) {
            GoRouter.of(context).go('/welcome');
          } else if (applinkUri != null)
            handleUri(applinkUri);
          else if (quickAction != null)
            handleQuickAction(context, quickAction);
          else
            GoRouter.of(context).go('/account');
        } catch (e, st) {
          logger.e('Splash init error: $e\n$st');
          // Still try to navigate even if something fails
          if (mounted) {
            appStore.initialized = true;
            GoRouter.of(context).go('/welcome');
          }
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LoadProgress(key: progressKey);
  }

  Future<Uri?> _registerURLHandler() async {
    _setProgress(0.3, 'Register Payment URI handlers');
    return await registerURLHandler();
  }

  Future<String?> _registerQuickActions() async {
    _setProgress(0.4, 'Register App Launcher actions');
    String? launchPage;
    final quickActions = QuickActions();
    await quickActions.initialize((quick_action) {
      launchPage = quick_action;
    });
    Future.microtask(() {
      final s = S.of(this.context);
      List<ShortcutItem> shortcuts = [];
      final c = activeCoin;
      final ticker = c.ticker;
      shortcuts.add(ShortcutItem(
          type: '${c.coin}.receive',
          localizedTitle: s.receive(ticker),
          icon: 'receive'));
      shortcuts.add(ShortcutItem(
          type: '${c.coin}.send',
          localizedTitle: s.sendCointicker(ticker),
          icon: 'send'));
      quickActions.setShortcutItems(shortcuts);
    });
    return launchPage;
  }

  void _initProver() async {
    _setProgress(0.1, 'Initialize ZK Prover');
    final spend = await rootBundle.load('assets/sapling-spend.params');
    final output = await rootBundle.load('assets/sapling-output.params');
    WarpApi.initProver(spend.buffer.asUint8List(), output.buffer.asUint8List());
  }

  void _initWallets() {
    final c = activeCoin;
    final coin = c.coin;
    _setProgress(0.5, 'Initializing ${c.ticker}');
    try {
      WarpApi.setDbPasswd(coin, appStore.dbPassword);
      WarpApi.initWallet(coin, c.dbFullPath);
      final p = WarpApi.getProperty(coin, 'settings');
      final settings = p.isNotEmpty
          ? CoinSettings.fromBuffer(base64Decode(p))
          : CoinSettings();
      final url = resolveURL(c, settings);
      WarpApi.updateLWD(coin, url);
      try {
        WarpApi.migrateData(c.coin);
      } catch (_) {} // do not fail on network exception
    } catch (e) {
      logger.e('initWallets error: $e');
    }
  }

  /// One-time migration: move seeds from SQLite DB to platform Keychain
  Future<void> _migrateSeedsToKeychain() async {
    _setProgress(0.6, 'Securing keys...');
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('seed_migration_done') == true) return;

    // Verify keystore health before migrating
    if (!await SecureKeyStore.isKeystoreHealthy()) {
      logger.e('Keystore unhealthy — skipping migration, keys stay in DB');
      return;
    }

    final coin = activeCoin.coin;
    try {
      final accounts = WarpApi.getAccountList(coin);
      for (final acct in accounts) {
        final backup = WarpApi.getBackup(coin, acct.id);
        if (backup.seed == null) continue; // already migrated or view-only

        // Store seed in Keychain
        await SecureKeyStore.storeSeed(
            coin, acct.id, backup.seed!, backup.index);

        // Verify the write succeeded
        final verify = await SecureKeyStore.getSeed(coin, acct.id);
        if (verify != backup.seed) {
          logger.e('Keychain verification failed for $coin/${acct.id} — '
              'will retry next launch');
          return; // don't set flag, retry next launch
        }

        // Clear secrets from SQLite
        WarpApi.clearAccountSecrets(coin, acct.id);
        logger.i('Migrated seed for account ${acct.id} to Keychain');
      }
      await prefs.setBool('seed_migration_done', true);
      logger.i('Seed migration complete');
    } catch (e) {
      logger.e('Seed migration error (will retry): $e');
    }
  }

  /// Load spending keys from Keychain seeds into the Rust runtime cache.
  /// Runs key derivation in an Isolate to avoid blocking the UI.
  Future<void> _loadKeysFromKeychain() async {
    _setProgress(0.7, 'Unlocking wallet...');
    final coin = activeCoin.coin;
    try {
      final accounts = WarpApi.getAccountList(coin);
      for (final acct in accounts) {
        final seed = await SecureKeyStore.getSeed(coin, acct.id);
        if (seed == null) continue; // view-only account
        final index = await SecureKeyStore.getIndex(coin, acct.id);
        await compute(_deriveKeysIsolate, _DeriveParams(coin, acct.id, seed, index));
      }
    } catch (e) {
      logger.e('Key loading error: $e');
    }
  }

  Future<void> _restoreActive() async {
    _setProgress(0.8, 'Load Active Account');
    final prefs = await SharedPreferences.getInstance();
    final a = ActiveAccount2.fromPrefs(prefs);
    if (a != null) {
      // Use async variant to load keys from Keychain and set canPay
      final hasSeed = await SecureKeyStore.hasSeed(a.coin, a.id);
      setActiveAccount(a.coin, a.id, canPayOverride: hasSeed ? true : null);
      aa.update(syncStatus2.latestHeight);
    }
  }

  _initAccel() {
    accelerometerEventStream().listen(handleAccel);
  }

  void _setProgress(double progress, String message) {
    print("$progress $message");
    progressKey.currentState!.setValue(progress, message);
  }

  Future<void> _initBackgroundSync() async {
    try {
      logger.d('${appSettings.backgroundSync}');
      await Workmanager().initialize(
        backgroundSyncDispatcher,
      );
      if (appSettings.backgroundSync != 0)
        await Workmanager().registerPeriodicTask(
          'sync',
          'background-sync',
          constraints: Constraints(
            networkType: appSettings.backgroundSync == 1
                ? NetworkType.unmetered
                : NetworkType.connected,
          ),
        );
      else
        await Workmanager().cancelAll();
    } catch (e) {
      logger.e('Background sync init failed: $e');
    }
  }
}

class LoadProgress extends StatefulWidget {
  LoadProgress({Key? key}) : super(key: key);

  @override
  State<LoadProgress> createState() => _LoadProgressState();
}

class _LoadProgressState extends State<LoadProgress>
    with SingleTickerProviderStateMixin {
  var _value = 0.0;
  String _message = "";
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.3),
            radius: 1.2,
            colors: [
              Color(0xFF0D1640),
              ZipherColors.bg,
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Logo with pulse
              FadeTransition(
                opacity: _pulseAnimation,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(ZipherRadius.xl),
                  child: Image.asset('assets/zipher_logo.png', height: 80),
                ),
              ),
              const SizedBox(height: ZipherSpacing.lg),
              // Brand name
              ZipherWidgets.brandText(fontSize: 32),
              const SizedBox(height: ZipherSpacing.sm),
              Text(
                isTestnet ? 'Testnet Mode' : 'Private Zcash Wallet',
                style: TextStyle(
                  fontSize: 14,
                  color: isTestnet
                      ? ZipherColors.orange
                      : ZipherColors.textSecondary,
                ),
              ),
              const SizedBox(height: ZipherSpacing.xxl),
              // Progress bar
              SizedBox(
                width: 200,
                child: ZipherWidgets.syncProgressBar(_value),
              ),
              const SizedBox(height: ZipherSpacing.md),
              Text(
                _message.isNotEmpty ? _message : s.loading,
                style: const TextStyle(
                  fontSize: 12,
                  color: ZipherColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void setValue(double v, String message) {
    setState(() {
      _value = v;
      _message = message;
    });
  }
}

StreamSubscription? subUniLinks;

bool setActiveAccountOf(int coin) {
  final coinSettings = CoinSettingsExtension.load(coin);
  final id = coinSettings.account;
  if (id == 0) return false;
  setActiveAccount(coin, id);
  return true;
}

void handleUri(Uri uri) {
  final scheme = uri.scheme;
  // Only handle URIs for the active network
  final coinDef = coins.where((c) => c.currency == scheme).firstOrNull;
  if (coinDef == null) return;
  final coin = coinDef.coin;
  if (setActiveAccountOf(coin)) {
    SendContext? sc = SendContext.fromPaymentURI(uri.toString());
    final context = rootNavigatorKey.currentContext!;
    GoRouter.of(context).go('/account/quick_send', extra: sc);
  }
}

Future<Uri?> registerURLHandler() async {
  final _appLinks = AppLinks();

  subUniLinks = _appLinks.uriLinkStream.listen((uri) {
    logger.d(uri);
    handleUri(uri);
  });

  final uri = await _appLinks.getInitialAppLink();
  return uri;
}

void handleQuickAction(BuildContext context, String quickAction) {
  final t = quickAction.split(".");
  final coin = int.parse(t[0]);
  final shortcut = t[1];
  setActiveAccountOf(coin);
  switch (shortcut) {
    case 'receive':
      GoRouter.of(context).go('/account/pay_uri');
    case 'send':
      GoRouter.of(context).go('/account/quick_send');
  }
}

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  if (!appStore.initialized) return;
  Workmanager().executeTask((task, inputData) async {
    try {
      logger.i("Native called background task: $task");
      await syncStatus2.sync(false, auto: true);
    } catch (e) {
      logger.e('Background sync error: $e');
    }
    return true;
  });
}

class _DeriveParams {
  final int coin;
  final int account;
  final String seed;
  final int index;
  _DeriveParams(this.coin, this.account, this.seed, this.index);
}

void _deriveKeysIsolate(_DeriveParams p) {
  WarpApi.loadKeysFromSeed(p.coin, p.account, p.seed, p.index);
}

/// Re-derive keys for all accounts that have seeds in the Keychain.
/// Called from the lifecycle observer when the app resumes.
Future<void> reloadKeysFromKeychain() async {
  final coin = activeCoin.coin;
  try {
    final accounts = WarpApi.getAccountList(coin);
    for (final acct in accounts) {
      final seed = await SecureKeyStore.getSeed(coin, acct.id);
      if (seed == null) continue;
      final index = await SecureKeyStore.getIndex(coin, acct.id);
      await compute(_deriveKeysIsolate, _DeriveParams(coin, acct.id, seed, index));
    }
  } catch (e) {
    logger.e('Reload keys error: $e');
  }
}

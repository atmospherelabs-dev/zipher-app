import 'dart:async';
import 'dart:io';

import 'package:zipher/router.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:workmanager/workmanager.dart';

import 'package:path_provider/path_provider.dart';

import '../../accounts.dart';
import 'accounts/send.dart';
import 'utils.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../init.dart';
import '../services/wallet_service.dart';
import '../services/wallet_registry.dart';
import '../services/secure_key_store.dart';
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
        final minDisplayTime = Future.delayed(const Duration(milliseconds: 1500));
        try {
          if (!GetIt.I.isRegistered<S>()) {
            GetIt.I.registerSingleton<S>(S.of(context));
          }
          if (!appSettings.hasMemo()) appSettings.memo = s.sendFrom(APP_NAME);

          _setProgress(0.1, 'Initializing...');
          await initCoins();

          _setProgress(0.2, 'Checking wallets...');
          final wallet = WalletService.instance;
          final registry = WalletRegistry.instance;
          logger.i('[Splash] server=${wallet.serverUrl}');

          if (!await registry.isMigrated()) {
            print('[Splash] running legacy migration...');
            await _migrateLegacyWallet(wallet, registry);
            print('[Splash] migration done');
          }

          final wallets = await registry.getAll();
          print('[Splash] ${wallets.length} wallet(s) in registry');
          final applinkUri = await _registerURLHandler();
          final quickAction = await _registerQuickActions();

          if (wallets.isNotEmpty) {
            var activeId = await registry.getActiveId();
            print('[Splash] activeId=$activeId');

            if (activeId == null ||
                !wallets.any((w) => w.id == activeId)) {
              activeId = wallets.first.id;
              print('[Splash] recovery: using first wallet $activeId');
              await registry.setActive(activeId);
            }

            final exists = await wallet.walletExists(walletId: activeId);
            print('[Splash] wallet exists on disk: $exists');
            if (!exists) {
              String? fallbackId;
              for (final w in wallets) {
                if (await wallet.walletExists(walletId: w.id)) {
                  fallbackId = w.id;
                  break;
                }
              }
              if (fallbackId != null) {
                activeId = fallbackId;
                print('[Splash] fallback to wallet $activeId');
                await registry.setActive(activeId);
              } else {
                await minDisplayTime;
                print('[Splash] no wallets on disk, going to /welcome');
                appStore.initialized = true;
                GoRouter.of(context).go('/welcome');
                return;
              }
            }

            _setProgress(0.5, 'Opening wallet...');
            print('[Splash] opening wallet $activeId...');
            await wallet.openWalletById(activeId);
            print('[Splash] wallet opened');

            _setProgress(0.7, 'Loading wallet data...');
            try {
              final profile = await registry.getById(activeId);
              final birthday = await wallet.getBirthday();

              aa = ActiveAccount2(
                coin: activeCoin.coin,
                id: 1,
                name: profile?.name ?? 'Main',
                address: '',
                canPay: true,
                walletId: activeId,
              );

              // Use cached balance for instant display
              if (profile != null && profile.lastBalance > 0) {
                aa.poolBalances = PoolBalance(orchard: profile.lastBalance);
              }

              // Load full state (balance, txs, address) from wallet
              await aa.update(null);
              print('[Splash] loaded: balance=${aa.poolBalances.confirmed} txs=${aa.txs.items.length} birthday=$birthday');

              // Initialize sync state from wallet's birthday
              if (birthday > 0) {
                syncStatus2.syncedHeight = birthday;
              }
            } catch (e) {
              logger.e('Failed to load wallet data: $e');
              print('[Splash] ERROR loading wallet data: $e');
            }

            initSyncListener();
            await _initBackgroundSync();
            _initAccel();

            final protectOpen = appSettings.protectOpen;
            if (protectOpen) {
              await authBarrier(context);
            }

            appStore.initialized = true;

            await minDisplayTime;
            if (applinkUri != null) {
              handleUri(applinkUri);
            } else if (quickAction != null) {
              handleQuickAction(context, quickAction);
            } else {
              print('[Splash] navigating to /account');
              GoRouter.of(context).go('/account');
            }
          } else {
            await minDisplayTime;
            print('[Splash] no wallets, going to /welcome');
            appStore.initialized = true;
            GoRouter.of(context).go('/welcome');
          }
        } catch (e, st) {
          logger.e('Splash init error: $e\n$st');
          await minDisplayTime;
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

  _initAccel() {
    accelerometerEventStream().listen(handleAccel);
  }

  void _setProgress(double progress, String message) {
    print("$progress $message");
    progressKey.currentState?.setValue(progress, message);
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
              FadeTransition(
                opacity: _pulseAnimation,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(ZipherRadius.xl),
                  child: Image.asset('assets/zipher_logo.png', height: 80),
                ),
              ),
              const SizedBox(height: ZipherSpacing.lg),
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

/// Migrate legacy single-wallet directory to UUID-based layout.
Future<void> _migrateLegacyWallet(
    WalletService wallet, WalletRegistry registry) async {
  try {
    final appDir = await getApplicationDocumentsDirectory();

    // Check legacy mainnet directory
    final legacyDir = Directory('${appDir.path}/zipher_wallet');
    final legacyFile = File('${legacyDir.path}/zingo-wallet.dat');

    if (!await legacyFile.exists()) {
      await registry.markMigrated();
      return;
    }

    // Create a new profile for the legacy wallet
    final profile = await registry.create('Main Wallet');

    // Rename directory to new UUID-based path
    final newDir = Directory('${appDir.path}/zipher_wallet_${profile.id}');
    await legacyDir.rename(newDir.path);

    // Also migrate testnet directory if it exists
    final legacyTestDir = Directory('${appDir.path}/zipher_wallet_testnet');
    if (await legacyTestDir.exists()) {
      final newTestDir =
          Directory('${appDir.path}/zipher_wallet_${profile.id}_testnet');
      await legacyTestDir.rename(newTestDir.path);
    }

    // Copy seed from legacy key to new wallet-keyed format
    final legacySeed = await SecureKeyStore.getSeed(0, 1);
    if (legacySeed != null && legacySeed.isNotEmpty) {
      await SecureKeyStore.storeSeedForWallet(profile.id, legacySeed);
      // Keep legacy key (seed_0_1) for 2 releases as fallback.
      // Verify new key reads back correctly.
      final verification =
          await SecureKeyStore.getSeedForWallet(profile.id);
      if (verification != legacySeed) {
        logger.e('Migration verification failed -- legacy key preserved');
      }
    }

    await registry.setActive(profile.id);
    await registry.markMigrated();
    logger.i('Legacy wallet migrated to profile ${profile.id}');
  } catch (e) {
    logger.e('Legacy wallet migration failed: $e');
    await registry.markMigrated();
  }
}

StreamSubscription? subUniLinks;

bool setActiveAccountOf(int coin) {
  return aa.id != 0;
}

void handleUri(Uri uri) async {
  final scheme = uri.scheme;
  final coinDef = coins.where((c) => c.currency == scheme).firstOrNull;
  if (coinDef == null) return;
  final coin = coinDef.coin;
  if (coin == activeCoin.coin && aa.id != 0) {
    final context = rootNavigatorKey.currentContext!;
    if (appSettings.protectSend) {
      final authed = await authBarrier(context, dismissable: true);
      if (!authed) return;
    }
    SendContext? sc = SendContext.fromPaymentURI(uri.toString());
    GoRouter.of(context).go('/account/quick_send', extra: sc);
  }
}

Future<Uri?> registerURLHandler() async {
  final _appLinks = AppLinks();

  subUniLinks = _appLinks.uriLinkStream.listen((uri) {
    logger.d('Deep link received: ${uri.scheme}://...');
    handleUri(uri);
  });

  final uri = await _appLinks.getInitialAppLink();
  return uri;
}

void handleQuickAction(BuildContext context, String quickAction) async {
  final t = quickAction.split(".");
  final shortcut = t[1];
  switch (shortcut) {
    case 'receive':
      GoRouter.of(context).go('/account/pay_uri');
    case 'send':
      if (appSettings.protectSend) {
        final authed = await authBarrier(context, dismissable: true);
        if (!authed) return;
      }
      GoRouter.of(context).go('/account/quick_send');
  }
}

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  if (!appStore.initialized) return;
  Workmanager().executeTask((task, inputData) async {
    try {
      logger.i("Native called background task: $task");
      await syncStatus2.sync();
    } catch (e) {
      logger.e('Background sync error: $e');
    }
    return true;
  });
}

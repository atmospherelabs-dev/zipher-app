import 'dart:async';

import 'package:zipher/router.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:workmanager/workmanager.dart';

import '../../accounts.dart';
import 'accounts/send.dart';
import 'utils.dart';
import '../appsettings.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../init.dart';
import '../services/wallet_service.dart';
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

          _setProgress(0.1, 'Initializing...');
          await initCoins();

          _setProgress(0.3, 'Checking wallet...');
          final wallet = WalletService.instance;
          final exists = await wallet.walletExists();

          final applinkUri = await _registerURLHandler();
          final quickAction = await _registerQuickActions();

          if (exists) {
            _setProgress(0.5, 'Opening wallet...');
            await wallet.openWallet();

            _setProgress(0.7, 'Loading balance...');
            try {
              final balance = await wallet.getBalance();
              final addrs = await wallet.getAddresses();
              aa = ActiveAccount2.fromWallet(
                coin: activeCoin.coin,
                address: addrs.isNotEmpty ? addrs.first.address : '',
                balance: balance,
              );
            } catch (e) {
              logger.e('Failed to load wallet data: $e');
            }

            initSyncListener();
            await _initBackgroundSync();
            _initAccel();

            final protectOpen = appSettings.protectOpen;
            if (protectOpen) {
              await authBarrier(context);
            }

            appStore.initialized = true;

            if (applinkUri != null) {
              handleUri(applinkUri);
            } else if (quickAction != null) {
              handleQuickAction(context, quickAction);
            } else {
              GoRouter.of(context).go('/account');
            }
          } else {
            appStore.initialized = true;
            GoRouter.of(context).go('/welcome');
          }
        } catch (e, st) {
          logger.e('Splash init error: $e\n$st');
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

StreamSubscription? subUniLinks;

bool setActiveAccountOf(int coin) {
  return aa.id != 0;
}

void handleUri(Uri uri) {
  final scheme = uri.scheme;
  final coinDef = coins.where((c) => c.currency == scheme).firstOrNull;
  if (coinDef == null) return;
  final coin = coinDef.coin;
  if (coin == activeCoin.coin && aa.id != 0) {
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
  final shortcut = t[1];
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

import 'pages/unavailable.dart';
import 'package:flutter/foundation.dart';
import 'package:showcaseview/showcaseview.dart';

import 'pages/accounts/swap/history.dart';
import 'pages/faucet.dart';
import 'pages/swap_status.dart';
import 'pages/more/cold.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'accounts.dart';
import 'coin/coins.dart';
import 'pages/accounts/manager.dart';
import 'pages/accounts/new_import.dart';
import 'pages/accounts/restore.dart';
import 'pages/accounts/pay_uri.dart';
import 'pages/accounts/rescan.dart';
import 'pages/accounts/send.dart';
import 'pages/accounts/split.dart';
import 'pages/accounts/submit.dart';
import 'pages/main/home.dart';
import 'pages/more/about.dart';
import 'pages/more/backup.dart';
import 'pages/more/contacts.dart';
import 'pages/more/memos.dart';
import 'pages/more/more.dart';
import 'pages/more/debug_log.dart';
import 'pages/more/ironwood.dart';
import 'pages/action/wallet_chat.dart';
import 'services/frost_service.dart';
import 'pages/cipherpay/invoice_pay.dart';
import 'pages/cipherpay/invoice_status.dart';
import 'pages/frost/frost_create.dart';
import 'pages/frost/frost_join.dart';
import 'pages/frost/frost_approve.dart';
import 'pages/frost/frost_recovery.dart';
import 'pages/frost/frost_sign_coordinator.dart';
import 'pages/frost/frost_hub.dart';
import 'pages/hitl/hitl_approve.dart';
import 'services/cipherpay_client.dart';
import 'services/hitl_watch_service.dart';
import 'pages/tx.dart';
import 'pages/scan.dart';
import 'pages/showqr.dart';
import 'pages/splash.dart';
import 'pages/welcome.dart';
import 'pages/settings.dart';
import 'pages/utils.dart';
import 'store2.dart';
import 'zipher_theme.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final _accountNavigatorKey = GlobalKey<NavigatorState>();

Page<void> _slideUpPage(Widget child, GoRouterState state) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final offsetTween = Tween<Offset>(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic));
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: offsetTween.animate(animation),
          child: child,
        ),
      );
    },
  );
}

final helpRouteMap = {
  "/account": "/accounts",
  "/txplan": "/transacting/report",
  "/submit_tx": "/transacting/report#transaction-sent",
  "/broadcast_tx": "/transacting/report#transaction-sent",
  "/swap": "/swap",
  "/more/history": "/history",
};

/// Unfocuses any active text field whenever a route is pushed or popped.
/// This ensures the keyboard doesn't linger after navigation (e.g. swipe-back).
class _UnfocusOnNavigation extends NavigatorObserver {
  void _unfocus() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void didPop(Route route, Route? previousRoute) => _unfocus();
  @override
  void didPush(Route route, Route? previousRoute) => _unfocus();
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _unfocus();
}

final router = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/splash',
  debugLogDiagnostics: kDebugMode,
  observers: [_UnfocusOnNavigation()],
  routes: [
    GoRoute(path: '/', redirect: (context, state) => '/account'),
    GoRoute(
      path: '/ask',
      redirect: (context, state) => Uri(
              path: '/account',
              queryParameters: state.uri.queryParameters.isEmpty
                  ? null
                  : state.uri.queryParameters)
          .toString(),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => ScaffoldBar(shell: shell),
      branches: [
        StatefulShellBranch(
          navigatorKey: _accountNavigatorKey,
          routes: [
            GoRoute(
              path: '/account',
              builder: (context, state) => WalletChatPage(
                initialIntent: state.uri.queryParameters['intent'],
              ),
              redirect: (context, state) {
                if (aa.id == 0) return '/welcome';
                return null;
              },
              routes: [
                GoRoute(
                  path: 'overview',
                  builder: (context, state) => HomePage(),
                ),
                GoRoute(
                  path: 'swap',
                  redirect: (_, state) => state.uri.path == '/account/swap'
                      ? '/account?intent=swap'
                      : null,
                  routes: [
                    GoRoute(
                      path: 'history',
                      builder: (context, state) => SwapHistoryPage(),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'txplan',
                  builder: (context, state) =>
                      const UnavailablePage('Legacy transaction signing'),
                ),
                GoRoute(
                  path: 'submit_tx',
                  builder: (context, state) {
                    if (state.extra == null) {
                      return const SubmitTxPage();
                    }
                    return const UnavailablePage('Legacy transaction signing');
                  },
                ),
                GoRoute(
                  path: 'broadcast_tx',
                  builder: (context, state) =>
                      const UnavailablePage('Legacy transaction broadcast'),
                ),
                GoRoute(
                  path: 'export_raw_tx',
                  builder: (context, state) =>
                      ExportUnsignedTxPage(state.extra as String),
                ),
                GoRoute(
                  path: 'rescan',
                  builder: (context, state) => RescanPage(),
                ),
                GoRoute(
                  path: 'quick_send',
                  pageBuilder: (context, state) {
                    bool custom = state.uri.queryParameters['custom'] == '1';
                    return _slideUpPage(
                        QuickSendPage(
                          custom: custom,
                          single: true,
                          sendContext: state.extra as SendContext?,
                        ),
                        state);
                  },
                  routes: [
                    GoRoute(
                      path: 'contacts',
                      builder: (context, state) => ContactsPage(main: false),
                    ),
                    GoRoute(
                      path: 'accounts',
                      builder: (context, state) =>
                          AccountManagerPage(main: false),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'pay_uri',
                  builder: (context, state) => PaymentURIPage(),
                ),
                GoRoute(
                  path: 'action',
                  redirect: (context, state) {
                    final intent = state.uri.queryParameters['intent'];
                    return Uri(
                            path: '/account',
                            queryParameters:
                                intent == null ? null : {'intent': intent})
                        .toString();
                  },
                ),
                GoRoute(
                  path: 'split',
                  builder: (context, state) => SplitBillPage(
                    prefilled: state.extra as List<Zip321Payment>?,
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/swap',
              redirect: (_, state) => !isTestnet && state.uri.path == '/swap'
                  ? '/account?intent=swap'
                  : null,
              builder: (context, state) => FaucetPage(),
              routes: [
                GoRoute(
                  path: 'status',
                  builder: (context, state) {
                    final extra = state.extra;
                    if (extra is String) {
                      return SwapStatusPage(depositAddress: extra);
                    }
                    final map = extra as Map<String, dynamic>;
                    return SwapStatusPage(
                      depositAddress: map['depositAddress'] as String,
                      fromCurrency: map['fromCurrency'] as String?,
                      fromAmount: map['fromAmount'] as String?,
                      toCurrency: map['toCurrency'] as String?,
                      toAmount: map['toAmount'] as String?,
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
                path: '/more',
                builder: (context, state) => MorePage(),
                routes: [
                  GoRoute(
                      path: 'account_manager',
                      builder: (context, state) =>
                          AccountManagerPage(main: true),
                      routes: [
                        GoRoute(
                            path: 'new',
                            builder: (context, state) => NewImportAccountPage(
                                first: false,
                                seedInfo: state.extra as SeedInfo?)),
                      ]),
                  GoRoute(
                      path: 'cold',
                      builder: (context, state) => PlaceHolderPage('Cold'),
                      routes: [
                        GoRoute(
                          path: 'sign',
                          builder: (context, state) => const UnavailablePage(
                              'Legacy transaction signing'),
                        ),
                        GoRoute(
                          path: 'signed',
                          builder: (context, state) =>
                              SignedTxPage(state.extra as String),
                        ),
                        GoRoute(
                          path: 'broadcast',
                          builder: (context, state) => const UnavailablePage(
                              'Legacy transaction broadcast'),
                        ),
                      ]),
                  GoRoute(
                    path: 'batch_backup',
                    builder: (context, state) =>
                        const UnavailablePage('App data backup'),
                  ),
                  GoRoute(
                    path: 'backup',
                    builder: (context, state) => BackupPage(),
                    routes: [
                      GoRoute(
                        path: 'keygen',
                        builder: (context, state) =>
                            const UnavailablePage('Backup key generation'),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'rescan',
                    builder: (context, state) => RescanPage(),
                  ),
                  GoRoute(
                    path: 'rewind',
                    builder: (context, state) => RescanPage(),
                  ),
                  GoRoute(
                    path: 'keytool',
                    builder: (context, state) =>
                        const UnavailablePage('Key derivation tool'),
                  ),
                  GoRoute(
                    path: 'sweep',
                    builder: (context, state) =>
                        const UnavailablePage('Private key sweep'),
                  ),
                  GoRoute(
                    path: 'debug_log',
                    builder: (context, state) => const DebugLogPage(),
                  ),
                  GoRoute(
                    path: 'governance',
                    builder: (context, state) =>
                        const UnavailablePage('Governance voting'),
                  ),
                  GoRoute(
                    path: 'ironwood',
                    builder: (context, state) => const IronwoodPage(),
                  ),
                  GoRoute(
                      path: 'about',
                      builder: (context, state) =>
                          AboutPage(state.extra as String)),
                  GoRoute(
                    path: 'submit_tx',
                    builder: (context, state) =>
                        const UnavailablePage('Legacy transaction signing'),
                  ),
                  GoRoute(
                    path: 'memos',
                    builder: (context, state) => const MemoInboxPage(),
                  ),
                  GoRoute(
                    path: 'history',
                    builder: (context, state) => TxPage(),
                    routes: [
                      GoRoute(
                        path: 'details',
                        builder: (context, state) => TransactionPage(
                            int.parse(state.uri.queryParameters["index"]!)),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'contacts',
                    builder: (context, state) => ContactsPage(main: true),
                    routes: [
                      GoRoute(
                        path: 'add',
                        builder: (context, state) => ContactAddPage(),
                      ),
                      GoRoute(
                        path: 'edit',
                        builder: (context, state) => ContactEditPage(
                            int.parse(state.uri.queryParameters['id']!)),
                      ),
                      GoRoute(
                        path: 'submit_tx',
                        builder: (context, state) =>
                            const UnavailablePage('Legacy transaction signing'),
                      ),
                    ],
                  ),
                ]),
          ],
        ),
      ],
    ),
    GoRoute(
        path: '/disclaimer',
        builder: (context, state) {
          final mode = (state.extra as String?) ?? 'restore';
          return DisclaimerPage(mode: mode);
        }),
    GoRoute(
        path: '/restore', builder: (context, state) => RestoreAccountPage()),
    GoRoute(
      path: '/splash',
      builder: (context, state) => SplashPage(),
    ),
    GoRoute(
      path: '/welcome',
      builder: (context, state) => WelcomePage(),
    ),
    GoRoute(
      path: '/first_account',
      builder: (context, state) => NewImportAccountPage(first: true),
    ),
    GoRoute(
      path: '/settings',
      parentNavigatorKey: rootNavigatorKey,
      pageBuilder: (context, state) {
        final coin =
            state.uri.queryParameters['coin']?.let(int.parse) ?? aa.coin;
        return _slideUpPage(SettingsPage(coin: coin), state);
      },
    ),
    GoRoute(
      path: '/scan',
      pageBuilder: (context, state) =>
          _slideUpPage(ScanQRCodePage(state.extra as ScanQRContext), state),
    ),
    GoRoute(
      path: '/showqr',
      builder: (context, state) => ShowQRPage(
          title: state.uri.queryParameters['title']!,
          text: state.extra as String),
    ),
    GoRoute(
      path: '/invoice/pay',
      pageBuilder: (context, state) {
        final ref = state.extra as InvoicePayArgs;
        return _slideUpPage(
            InvoicePayPage(
              invoiceRef: ref.invoiceRef,
              prefetched: ref.prefetched,
            ),
            state);
      },
    ),
    GoRoute(
      path: '/invoice/status',
      pageBuilder: (context, state) => _slideUpPage(
          InvoiceStatusPage(args: state.extra as InvoiceStatusArgs), state),
    ),
    GoRoute(
      path: '/wallet/frost',
      pageBuilder: (context, state) =>
          _slideUpPage(const FrostHubPage(), state),
    ),
    GoRoute(
      path: '/wallet/create/frost',
      pageBuilder: (context, state) =>
          _slideUpPage(const FrostCreatePage(), state),
    ),
    GoRoute(
      path: '/wallet/join',
      pageBuilder: (context, state) =>
          _slideUpPage(const FrostJoinPage(), state),
    ),
    GoRoute(
      path: '/frost/approve',
      pageBuilder: (context, state) {
        final extra = state.extra;
        if (extra is FrostApprovalArgs) {
          return _slideUpPage(FrostApprovePage(args: extra), state);
        }
        final request =
            FrostApprovalRequest.fromPayload(state.uri.queryParameters);
        return _slideUpPage(
            FrostApprovePage(
              args: FrostApprovalArgs(
                sessionId: request.sessionId,
                walletName: request.walletLabel,
                destination: request.destination,
                zatoshis: request.zatoshis,
                feeZec: request.feeZec,
                memoPreview: request.memoPreview,
              ),
            ),
            state);
      },
    ),
    GoRoute(
      path: '/hitl/approve',
      pageBuilder: (context, state) {
        final extra = state.extra;
        if (extra is HitlApprovalRequest) {
          return _slideUpPage(HitlApprovePage(request: extra), state);
        }
        return _slideUpPage(const Scaffold(), state);
      },
    ),
    GoRoute(
      path: '/frost/recovery',
      pageBuilder: (context, state) => _slideUpPage(
          FrostRecoveryPage(
            walletId: state.uri.queryParameters['walletId'] ?? '',
          ),
          state),
    ),
    GoRoute(
      path: '/frost/sign',
      pageBuilder: (context, state) => _slideUpPage(
          FrostSignCoordinatorPage(
              args: state.extra as FrostSignCoordinatorArgs),
          state),
    ),
  ],
);

/// Args passed to `/invoice/pay` so we can optionally hand off a prefetched
/// invoice (e.g. from the QR scan handler) and skip a second network call.
class InvoicePayArgs {
  final String invoiceRef;
  final CipherPayInvoice? prefetched;
  const InvoicePayArgs({required this.invoiceRef, this.prefetched});
}

class ScaffoldBar extends StatefulWidget {
  final StatefulNavigationShell shell;

  const ScaffoldBar({required this.shell, Key? key});

  @override
  State<ScaffoldBar> createState() => _ScaffoldBar();
}

class _ScaffoldBar extends State<ScaffoldBar> {
  int _knownCoin = aa.coin;
  int _knownId = aa.id;
  bool _knownTestnet = isTestnet;
  final Set<int> _staleTabs = {};

  void _goToBranch(int i) {
    if (aa.coin != _knownCoin || aa.id != _knownId) {
      _knownCoin = aa.coin;
      _knownId = aa.id;
      _staleTabs.addAll([0, 1, 2]);
    }
    if (isTestnet != _knownTestnet) {
      _knownTestnet = isTestnet;
      _staleTabs.addAll([0, 1, 2]);
    }
    final isCurrentTab = i == widget.shell.currentIndex;
    final isStale = _staleTabs.remove(i);
    widget.shell.goBranch(
      i,
      initialLocation: isCurrentTab || isStale,
    );
  }

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.of(context);
    final RouteMatch lastMatch =
        router.routerDelegate.currentConfiguration.last;
    final RouteMatchList matchList = lastMatch is ImperativeRouteMatch
        ? lastMatch.matches
        : router.routerDelegate.currentConfiguration;
    final String location = matchList.uri.toString();

    return PopScope(
        canPop: location == '/account',
        onPopInvokedWithResult: (didPop, _) => _onPop(didPop),
        child: Scaffold(
          backgroundColor: ZipherColors.bg,
          bottomNavigationBar: Container(
            clipBehavior: Clip.none,
            decoration: BoxDecoration(
              color: ZipherColors.bg,
              border: Border(
                top: BorderSide(
                  color: ZipherColors.borderSubtle,
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [0, if (isTestnet) 1, 2].map((i) {
                    final isActive = widget.shell.currentIndex == i;
                    final navIndex = i;
                    final icons = [
                      Icons.home_outlined,
                      isTestnet
                          ? Icons.water_drop_outlined
                          : Icons.swap_horiz_outlined,
                      Icons.more_horiz_rounded,
                    ];
                    final activeIcons = [
                      Icons.home_rounded,
                      isTestnet
                          ? Icons.water_drop_rounded
                          : Icons.swap_horiz_rounded,
                      Icons.more_horiz_rounded,
                    ];
                    final labels = [
                      'Home',
                      isTestnet ? 'Faucet' : 'Swap',
                      'More'
                    ];
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _goToBranch(i),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? ZipherColors.cyan
                                          .withValues(alpha: 0.10)
                                      : Colors.transparent,
                                  borderRadius:
                                      BorderRadius.circular(ZipherRadius.md),
                                ),
                                child: Icon(
                                  isActive
                                      ? activeIcons[navIndex]
                                      : icons[navIndex],
                                  size: 24,
                                  color: isActive
                                      ? ZipherColors.cyan
                                      : ZipherColors.text20,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                labels[navIndex],
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: isActive
                                      ? ZipherColors.cyan
                                      : ZipherColors.text20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          body: ShowCaseWidget(builder: (context) => widget.shell),
        ));
  }

  settings() {
    GoRouter.of(context).push('/settings');
  }

  _onPop(bool didPop) {
    router.go('/account');
  }
}

class PlaceHolderPage extends StatelessWidget {
  final String title;
  final Widget? child;
  PlaceHolderPage(this.title, {this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: Column(
        children: [
          ZipherWidgets.pageHeader(context, title),
          if (child != null) Expanded(child: child!),
        ],
      ),
    );
  }
}

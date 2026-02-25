import 'dart:ui';

import 'package:showcaseview/showcaseview.dart';

import 'pages/accounts/swap/history.dart';
import 'pages/faucet.dart';
import 'pages/swap.dart';
import 'pages/swap_status.dart';
import 'pages/more/cold.dart';
import 'settings.pb.dart';
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
import 'pages/accounts/submit.dart';
import 'pages/accounts/txplan.dart';
import 'pages/main/home.dart';
import 'pages/more/about.dart';
import 'pages/more/backup.dart';
import 'pages/more/batch.dart';
import 'pages/more/contacts.dart';
import 'pages/more/keytool.dart';
import 'pages/more/memos.dart';
import 'pages/more/more.dart';
import 'pages/more/sweep.dart';
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

final helpRouteMap = {
  "/account": "/accounts",
  "/txplan": "/transacting/report",
  "/submit_tx": "/transacting/report#transaction-sent",
  "/broadcast_tx": "/transacting/report#transaction-sent",
  "/swap": "/swap",
  "/more/history": "/history",
};

final router = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/splash',
  debugLogDiagnostics: true,
  routes: [
    GoRoute(path: '/', redirect: (context, state) => '/account'),
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => ScaffoldBar(shell: shell),
      branches: [
        StatefulShellBranch(
          navigatorKey: _accountNavigatorKey,
          routes: [
            GoRoute(
              path: '/account',
              builder: (context, state) => HomePage(),
              redirect: (context, state) {
                if (aa.id == 0) return '/welcome';
                return null;
              },
              routes: [
                GoRoute(
                  path: 'swap',
                  builder: (context, state) => NearSwapPage(),
                  routes: [
                    GoRoute(
                      path: 'history',
                      builder: (context, state) => SwapHistoryPage(),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'txplan',
                  builder: (context, state) => TxPlanPage(
                    state.extra as String,
                    tab: state.uri.queryParameters['tab']!,
                    signOnly: state.uri.queryParameters['sign'] != null,
                    isShield: state.uri.queryParameters['shield'] != null,
                  ),
                ),
                GoRoute(
                  path: 'submit_tx',
                  builder: (context, state) =>
                      SubmitTxPage(txPlan: state.extra as String),
                ),
                GoRoute(
                  path: 'broadcast_tx',
                  builder: (context, state) =>
                      SubmitTxPage(txBin: state.extra as String),
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
                  builder: (context, state) {
                    bool custom = state.uri.queryParameters['custom'] == '1';
                    return QuickSendPage(
                      custom: custom,
                      single: true,
                      sendContext: state.extra as SendContext?,
                    );
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
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
                path: '/swap',
                builder: (context, state) => ValueListenableBuilder<bool>(
                  valueListenable: testnetNotifier,
                  builder: (_, isTest, __) =>
                      isTest ? FaucetPage() : NearSwapPage(),
                ),
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
                          builder: (context, state) => ColdSignPage(),
                        ),
                        GoRoute(
                          path: 'signed',
                          builder: (context, state) =>
                              SignedTxPage(state.extra as String),
                        ),
                        GoRoute(
                          path: 'broadcast',
                          builder: (context, state) => BroadcastTxPage(),
                        ),
                      ]),
                  GoRoute(
                    path: 'batch_backup',
                    builder: (context, state) => BatchBackupPage(),
                  ),
                  GoRoute(
                    path: 'backup',
                    builder: (context, state) => BackupPage(),
                    routes: [
                      GoRoute(
                        path: 'keygen',
                        builder: (context, state) => KeygenPage(),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'rescan',
                    builder: (context, state) => RescanPage(),
                  ),
                  GoRoute(
                    path: 'rewind',
                    builder: (context, state) => RewindPage(),
                  ),
                  GoRoute(
                    path: 'keytool',
                    builder: (context, state) => KeyToolPage(),
                  ),
                  GoRoute(
                    path: 'sweep',
                    builder: (context, state) => SweepPage(),
                  ),
                  GoRoute(
                      path: 'about',
                      builder: (context, state) =>
                          AboutPage(state.extra as String)),
                  GoRoute(
                    path: 'submit_tx',
                    builder: (context, state) =>
                        SubmitTxPage(txPlan: state.extra as String),
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
                            SubmitTxPage(txPlan: state.extra as String),
                      ),
                    ],
                  ),
                ]),
          ],
        ),
      ],
    ),
    GoRoute(path: '/disclaimer', builder: (context, state) {
      final mode = (state.extra as String?) ?? 'restore';
      return DisclaimerPage(mode: mode);
    }),
    GoRoute(path: '/restore', builder: (context, state) => RestoreAccountPage()),
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
      builder: (context, state) {
        final coin =
            state.uri.queryParameters['coin']?.let(int.parse) ?? aa.coin;
        return SettingsPage(coin: coin);
      },
    ),
    GoRoute(
      path: '/quick_send_settings',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) =>
          QuickSendSettingsPage(state.extra as CustomSendSettings),
    ),
    GoRoute(
      path: '/scan',
      builder: (context, state) => ScanQRCodePage(state.extra as ScanQRContext),
    ),
    GoRoute(
      path: '/showqr',
      builder: (context, state) => ShowQRPage(
          title: state.uri.queryParameters['title']!,
          text: state.extra as String),
    ),
  ],
);

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
        onPopInvoked: _onPop,
        child: Scaffold(
          backgroundColor: ZipherColors.bg,
          bottomNavigationBar: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
            decoration: BoxDecoration(
              color: ZipherColors.bg.withValues(alpha: 0.80),
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
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(3, (i) {
                    final isActive = widget.shell.currentIndex == i;
                    final icons = [
                      Icons.home_outlined,
                      isTestnet ? Icons.water_drop_outlined : Icons.swap_horiz_outlined,
                      Icons.more_horiz_rounded,
                    ];
                    final activeIcons = [
                      Icons.home_rounded,
                      isTestnet ? Icons.water_drop_rounded : Icons.swap_horiz_rounded,
                      Icons.more_horiz_rounded,
                    ];
                    final labels = ['Home', isTestnet ? 'Faucet' : 'Swap', 'More'];
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          // Detect account or network change since last tap
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
                        },
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
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                isActive ? activeIcons[i] : icons[i],
                                size: 24,
                                color: isActive
                                    ? ZipherColors.cyan
                                    : ZipherColors.text20,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              labels[i],
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
                    );
                  }),
                ),
              ),
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

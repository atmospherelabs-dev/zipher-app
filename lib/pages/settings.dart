import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:protobuf/protobuf.dart';
import 'package:warp_api/warp_api.dart';

import '../accounts.dart';
import '../zipher_theme.dart';
import '../coin/coin.dart';
import '../coin/coins.dart';
import '../generated/intl/messages.dart';
import '../appsettings.dart' as app;
import '../settings.pb.dart';
import '../store2.dart';
import 'utils.dart';

late List<String> currencies;

// ═══════════════════════════════════════════════════════════
// PREFERENCES PAGE (simplified)
// ═══════════════════════════════════════════════════════════

class SettingsPage extends StatefulWidget {
  final int coin;
  SettingsPage({required this.coin});

  @override
  State<StatefulWidget> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  final formKey = GlobalKey<FormBuilderState>();
  late final appSettings = app.appSettings.deepCopy();
  late final coinSettings = app.coinSettings.deepCopy();
  String? _selectedCurrency;
  int _selectedServerIndex = 0;
  final _customUrlController = TextEditingController();
  final Map<int, int?> _pingResults = {}; // index -> ms (null = testing)
  bool _pinging = false;

  @override
  void initState() {
    super.initState();
    _selectedCurrency = appSettings.currency;
    currencies = [appSettings.currency];
    coinSettings.lwd = coinSettings.lwd.deepCopy();
    _selectedServerIndex = coinSettings.lwd.index;
    _customUrlController.text = coinSettings.lwd.customURL;
    Future(() async {
      final c = await fetchCurrencies();
      if (c != null && mounted) setState(() => currencies = c);
    });
    _pingAllServers();
  }

  Future<void> _pingAllServers() async {
    final servers = coins[widget.coin].lwd;
    setState(() {
      _pinging = true;
      for (int i = 0; i < servers.length; i++) {
        _pingResults[i] = null; // null = in progress
      }
    });
    await Future.wait(
      List.generate(servers.length, (i) => _pingServer(i, servers[i].url)),
    );
    if (mounted) setState(() => _pinging = false);
  }

  Future<void> _pingServer(int index, String url) async {
    try {
      final uri = Uri.parse(url);
      final client = http.Client();
      final sw = Stopwatch()..start();
      try {
        await client.head(uri).timeout(const Duration(seconds: 5));
      } catch (_) {
        // gRPC servers may reject HTTP HEAD, that's fine -- we still measured the TCP round-trip
      }
      sw.stop();
      client.close();
      if (mounted) setState(() => _pingResults[index] = sw.elapsedMilliseconds);
    } catch (_) {
      if (mounted) setState(() => _pingResults[index] = -1); // -1 = failed
    }
  }

  @override
  void dispose() {
    _customUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final currencyItems = currencies
        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
        .toList();

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'PREFERENCES',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
            color: ZipherColors.text60,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded,
              color: ZipherColors.text60),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        actions: [
          IconButton(
            onPressed: _save,
            icon: Icon(Icons.check_rounded,
                size: 22,
                color: ZipherColors.cyan.withValues(alpha: 0.8)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: FormBuilder(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Currency ──
              _sectionLabel('Currency'),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedCurrency,
                    items: currencyItems,
                    onChanged: (v) {
                      setState(() => _selectedCurrency = v);
                      appSettings.currency = v!;
                    },
                    isExpanded: true,
                    dropdownColor: ZipherColors.surface,
                    style: TextStyle(
                      fontSize: 14,
                      color: ZipherColors.text90,
                    ),
                    icon: Icon(Icons.expand_more_rounded,
                        color: ZipherColors.text20),
                  ),
                ),
              ),
              const Gap(6),
              _hint('Fiat currency for price display'),

              const Gap(24),

              // ── Default Memo ──
              _sectionLabel('Default Memo'),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: TextField(
                  controller: TextEditingController(text: appSettings.memo),
                  style: TextStyle(
                    fontSize: 14,
                    color: ZipherColors.text90,
                  ),
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: 'e.g. Sent from Zipher',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: ZipherColors.text20,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.all(16),
                  ),
                  onChanged: (v) => appSettings.memo = v,
                ),
              ),
              const Gap(6),
              _hint('Attached to every transaction you send'),

              const Gap(24),

              // ── Server ──
              Row(
                children: [
                  Expanded(child: _sectionLabel('Server')),
                  GestureDetector(
                    onTap: _pinging ? null : _pingAllServers,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.speed_rounded,
                          size: 13,
                          color: _pinging
                              ? ZipherColors.text10
                              : ZipherColors.cyan.withValues(alpha: 0.5),
                        ),
                        const Gap(4),
                        Text(
                          _pinging ? 'Testing...' : 'Test latency',
                          style: TextStyle(
                            fontSize: 11,
                            color: _pinging
                                ? ZipherColors.text10
                                : ZipherColors.cyan.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Gap(8),
              _buildServerSelector(),
              const Gap(6),
              _hint('Lightwalletd node used for syncing'),

              // ── Background Sync ──
              ...[
                const Gap(24),
                _sectionLabel('Background Sync'),
                const Gap(8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sync when the app is in the background',
                        style: TextStyle(
                          fontSize: 13,
                          color: ZipherColors.text40,
                        ),
                      ),
                      const Gap(12),
                      Row(
                        children: [
                          _syncOption(0, 'Off', s),
                          const Gap(8),
                          _syncOption(1, 'Wi-Fi only', s),
                          const Gap(8),
                          _syncOption(2, 'Always', s),
                        ],
                      ),
                    ],
                  ),
                ),
              ],

              // ── Security ──
              const Gap(24),
              _sectionLabel('Security'),
              const Gap(8),
              Container(
                decoration: BoxDecoration(
                  color: ZipherColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    _securityToggle(
                      icon: Icons.lock_rounded,
                      label: 'Require auth for Send & Swap',
                      subtitle: 'Biometric or device PIN before sending or swapping funds',
                      value: appSettings.protectSend,
                      onChanged: (v) => setState(() => appSettings.protectSend = v),
                    ),
                    Divider(height: 1, color: ZipherColors.cardBg,
                        indent: 52, endIndent: 16),
                    _securityToggle(
                      icon: Icons.shield_rounded,
                      label: 'Require auth on App Open',
                      subtitle: 'Authenticate every time you open Zipher',
                      value: appSettings.protectOpen,
                      onChanged: (v) => setState(() => appSettings.protectOpen = v),
                    ),
                  ],
                ),
              ),
              const Gap(6),
              _hint('Uses Face ID, Touch ID, or device passcode'),

              const Gap(40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServerSelector() {
    final c = coins[widget.coin];
    final servers = c.lwd;
    final isCustom = _selectedServerIndex < 0 ||
        _selectedServerIndex >= servers.length;

    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (int i = 0; i < servers.length; i++)
            _serverTile(i, servers[i].name, servers[i].url,
                selected: _selectedServerIndex == i),
          _serverTile(-1, 'Custom', null, selected: isCustom),
          if (isCustom)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: ZipherColors.cardBg,
                  ),
                ),
              ),
              child: TextField(
                controller: _customUrlController,
                style: TextStyle(
                  fontSize: 13,
                  color: ZipherColors.text90,
                ),
                decoration: InputDecoration(
                  hintText: 'https://your-server:9067',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: ZipherColors.text20,
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                ),
                onChanged: (v) => coinSettings.lwd.customURL = v,
              ),
            ),
        ],
      ),
    );
  }

  Widget _serverTile(int index, String name, String? url,
      {required bool selected}) {
    final ping = _pingResults[index];
    Widget? pingWidget;
    if (index >= 0 && _pingResults.containsKey(index)) {
      if (ping == null) {
        pingWidget = SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: ZipherColors.text20,
          ),
        );
      } else if (ping < 0) {
        pingWidget = Text(
          '---',
          style: TextStyle(
            fontSize: 10,
            color: ZipherColors.red.withValues(alpha: 0.6),
          ),
        );
      } else {
        final color = ping < 200
            ? ZipherColors.green
            : ping < 500
                ? ZipherColors.orange
                : ZipherColors.red;
        pingWidget = Text(
          '${ping}ms',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: color.withValues(alpha: 0.7),
          ),
        );
      }
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedServerIndex = index;
            coinSettings.lwd.index = index;
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 18,
                color: selected
                    ? ZipherColors.cyan.withValues(alpha: 0.8)
                    : ZipherColors.text20,
              ),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected
                            ? ZipherColors.text90
                            : ZipherColors.text40,
                      ),
                    ),
                    if (url != null)
                      Text(
                        url,
                        style: TextStyle(
                          fontSize: 10,
                          color: ZipherColors.text20,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (pingWidget != null) ...[
                const Gap(8),
                pingWidget,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: ZipherColors.text20,
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: ZipherColors.text20,
        ),
      ),
    );
  }

  Widget _syncOption(int value, String label, S s) {
    final selected = appSettings.backgroundSync == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => appSettings.backgroundSync = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? ZipherColors.cyan.withValues(alpha: 0.12)
                : ZipherColors.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: selected
                ? Border.all(
                    color: ZipherColors.cyan.withValues(alpha: 0.2))
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? ZipherColors.cyan.withValues(alpha: 0.9)
                    : ZipherColors.text40,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _securityToggle({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18,
              color: value
                  ? ZipherColors.cyan.withValues(alpha: 0.7)
                  : ZipherColors.text20),
          const Gap(14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: ZipherColors.text90,
                )),
                const Gap(2),
                Text(subtitle, style: TextStyle(
                  fontSize: 11,
                  color: ZipherColors.text20,
                )),
              ],
            ),
          ),
          const Gap(12),
          SizedBox(
            height: 28,
            child: Switch.adaptive(
              value: value,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  void _save() async {
    final prefs = await SharedPreferences.getInstance();
    await appSettings.save(prefs);
    coinSettings.save(aa.coin);
    app.appSettings = app.AppSettingsExtension.load(prefs);
    app.coinSettings = app.CoinSettingsExtension.load(aa.coin);
    final serverUrl = resolveURL(coins[aa.coin], app.coinSettings);
    WarpApi.updateLWD(aa.coin, serverUrl);
    aaSequence.settingsSeqno = DateTime.now().millisecondsSinceEpoch;
    Future(() async {
      await marketPrice.update();
      aa.currency = appSettings.currency;
    });
    GoRouter.of(context).pop();
  }
}

// ═══════════════════════════════════════════════════════════
// QUICK SEND SETTINGS (kept for router compatibility)
// ═══════════════════════════════════════════════════════════

class QuickSendSettingsPage extends StatefulWidget {
  final CustomSendSettings customSendSettings;
  QuickSendSettingsPage(this.customSendSettings);

  @override
  State<StatefulWidget> createState() => _QuickSendSettingsState();
}

class _QuickSendSettingsState extends State<QuickSendSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(s.customSendSettings),
      ),
      body: const Center(child: Text('Deprecated')),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// SHARED WIDGETS (used by pool.dart, sweep.dart, etc.)
// ═══════════════════════════════════════════════════════════

class FieldUA extends StatelessWidget {
  final String name;
  final String label;
  late final Set<int> initialValues;
  final void Function(int?)? onChanged;
  final bool radio;
  final bool emptySelectionAllowed;
  final int pools;
  final String? Function(int)? validator;
  FieldUA(
    int initialValue, {
    required this.name,
    required this.label,
    this.onChanged,
    this.emptySelectionAllowed = false,
    required this.radio,
    this.validator,
    this.pools = 7,
  }) : initialValues = PoolBitSet.toSet(initialValue);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = Theme.of(context);
    final small = t.textTheme.labelMedium!;
    return FormBuilderField(
      name: name,
      initialValue: initialValues,
      onChanged: (v) => onChanged?.call(PoolBitSet.fromSet(v!)),
      validator: (v) => validator?.call(PoolBitSet.fromSet(v!)),
      builder: (field) => InputDecorator(
          decoration:
              InputDecoration(label: Text(label), errorText: field.errorText),
          child: Padding(
            padding: EdgeInsets.fromLTRB(0, 8, 0, 0),
            child: SegmentedButton(
              segments: [
                if (pools & 1 != 0)
                  ButtonSegment(
                      value: 0,
                      label: Text(s.transparent,
                          overflow: TextOverflow.ellipsis, style: small)),
                if (pools & 2 != 0)
                  ButtonSegment(
                      value: 1,
                      label: Text(s.sapling,
                          overflow: TextOverflow.ellipsis, style: small)),
                if (aa.hasUA && pools & 4 != 0)
                  ButtonSegment(
                      value: 2,
                      label: Text(s.orchard,
                          overflow: TextOverflow.ellipsis, style: small)),
              ],
              selected: field.value!,
              onSelectionChanged: (v) => field.didChange(v),
              multiSelectionEnabled: !radio,
              emptySelectionAllowed: emptySelectionAllowed,
              showSelectedIcon: false,
            ),
          )),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════

Future<List<String>?> fetchCurrencies() async {
  try {
    final base = "api.coingecko.com";
    final uri = Uri.https(base, '/api/v3/simple/supported_vs_currencies');
    final rep = await http.get(uri);
    if (rep.statusCode == 200) {
      final currencies = jsonDecode(rep.body) as List<dynamic>;
      final c = currencies.map((v) => (v as String).toUpperCase()).toList();
      c.sort();
      return c;
    }
  } catch (_) {}
  return null;
}

String resolveURL(CoinBase c, CoinSettings settings) {
  if (settings.lwd.index >= 0 && settings.lwd.index < c.lwd.length)
    return c.lwd[settings.lwd.index].url;
  else {
    return settings.lwd.customURL;
  }
}

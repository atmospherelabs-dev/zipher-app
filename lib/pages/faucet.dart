import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:warp_api/warp_api.dart';

import '../accounts.dart';
import '../zipher_theme.dart';

const _faucetBaseUrl = 'https://testnet.zecfaucet.com/';
const _explorerUrl = 'https://testnet.cipherscan.app';

class FaucetPage extends StatefulWidget {
  @override
  State<FaucetPage> createState() => _FaucetPageState();
}

class _FaucetPageState extends State<FaucetPage> {
  String? _address;

  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  void _loadAddress() {
    try {
      final addr = WarpApi.getAddress(aa.coin, aa.id, 7);
      setState(() => _address = addr);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: ZipherColors.bg,
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Gap(topPad + 20),

              Text(
                'Testnet Faucet',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: ZipherColors.text90,
                ),
              ),
              const Gap(8),
              Text(
                'Get free TAZ (testnet ZEC) to try out Zipher',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: ZipherColors.text40,
                ),
              ),
              const Gap(40),

              // Faucet icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: ZipherColors.cyan.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.water_drop_rounded,
                  size: 40,
                  color: ZipherColors.cyan,
                ),
              ),
              const Gap(32),

              // Address card
              if (_address != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: ZipherColors.cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ZipherColors.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your testnet address',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: ZipherColors.text40,
                        ),
                      ),
                      const Gap(8),
                      Text(
                        _address!,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: ZipherColors.text60,
                          height: 1.5,
                        ),
                      ),
                      const Gap(8),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: _address!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Address copied'),
                              duration: Duration(seconds: 2),
                              backgroundColor: ZipherColors.surface,
                            ),
                          );
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy_rounded,
                                size: 14, color: ZipherColors.cyan),
                            const Gap(4),
                            Text(
                              'Copy',
                              style: TextStyle(
                                fontSize: 12,
                                color: ZipherColors.cyan,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Gap(24),
              ],

              // Get TAZ button
              SizedBox(
                width: double.infinity,
                child: ZipherWidgets.secondaryButton(
                  label: 'Get TAZ from Faucet',
                  icon: Icons.water_drop_rounded,
                  onPressed: _openFaucet,
                ),
              ),
              const Gap(16),

              // Explore on CipherScan button
              SizedBox(
                width: double.infinity,
                child: GestureDetector(
                  onTap: _openExplorer,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: ZipherColors.borderSubtle,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.explore_rounded,
                            size: 18,
                            color: ZipherColors.cyan.withValues(alpha: 0.6)),
                        const Gap(8),
                        Text(
                          'Explore on CipherScan',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: ZipherColors.cyan,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Gap(32),

              // Info text
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: ZipherColors.orange.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: ZipherColors.orange.withValues(alpha: 0.08),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 16,
                        color: ZipherColors.orange.withValues(alpha: 0.5)),
                    const Gap(10),
                    Expanded(
                      child: Text(
                        'TAZ has no real value. This is for testing only. '
                        'Switch to mainnet in More > Developer to use real ZEC.',
                        style: TextStyle(
                          fontSize: 12,
                          color: ZipherColors.text40,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(40),
            ],
          ),
        ),
      ),
    );
  }

  void _openFaucet() {
    launchUrl(
      Uri.parse(_faucetBaseUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  void _openExplorer() {
    launchUrl(
      Uri.parse(_explorerUrl),
      mode: LaunchMode.externalApplication,
    );
  }
}

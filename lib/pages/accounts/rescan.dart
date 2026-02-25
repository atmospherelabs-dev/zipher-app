import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../zipher_theme.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../utils.dart';

class RescanPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _RescanState();
}

class _RescanState extends State<RescanPage> with WithLoadingAnimation {
  late final s = S.of(context);
  final formKey = GlobalKey<FormBuilderState>();
  final _heightController = TextEditingController();
  final minDate = activationDate;
  DateTime maxDate = DateTime.now();
  DateTime? _selectedDate;
  bool _showCalendar = false;
  bool _useHeight = false;

  // Rewind data
  late final List<Checkpoint> checkpoints = WarpApi.getCheckpoints(aa.coin);

  @override
  void dispose() {
    _heightController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZipherColors.bg,
      appBar: AppBar(
        backgroundColor: ZipherColors.bg,
        elevation: 0,
        title: Text(
          'RECOVER',
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
      ),
      body: wrapWithLoading(
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: FormBuilder(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Info
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: ZipherColors.cyan.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: ZipherColors.cyan.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 16,
                          color: ZipherColors.cyan.withValues(alpha: 0.5)),
                      const Gap(10),
                      Expanded(
                        child: Text(
                          'If your balance looks wrong or transactions are missing, '
                          'you can re-sync from an earlier point. Your funds are safe on the blockchain — this just re-reads them.',
                          style: TextStyle(
                            fontSize: 12,
                            color: ZipherColors.cyan.withValues(alpha: 0.5),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const Gap(28),

                // ═════════════════════════════
                // Quick Rewind (if checkpoints)
                // ═════════════════════════════
                if (checkpoints.isNotEmpty) ...[
                  _sectionLabel('Quick Rewind'),
                  const Gap(4),
                  Text(
                    'Roll back to a recent save point. Fastest option.',
                    style: TextStyle(
                      fontSize: 11,
                      color: ZipherColors.text20,
                    ),
                  ),
                  const Gap(10),
                  _buildRewindOptions(),
                  const Gap(28),
                ],

                // ═════════════════════════════
                // Full Rescan
                // ═════════════════════════════
                _sectionLabel('Full Rescan'),
                const Gap(4),
                Text(
                  'Re-download all transactions from a specific point. Slower but thorough.',
                  style: TextStyle(
                    fontSize: 11,
                    color: ZipherColors.text20,
                  ),
                ),
                const Gap(12),

                // Date picker
                GestureDetector(
                  onTap: () =>
                      setState(() => _showCalendar = !_showCalendar),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.calendar_today_rounded,
                            size: 16,
                            color: ZipherColors.text40),
                        const Gap(10),
                        Expanded(
                          child: Text(
                            _selectedDate != null
                                ? '${_selectedDate!.day}/${_selectedDate!.month}/${_selectedDate!.year}'
                                : 'Pick a date to rescan from...',
                            style: TextStyle(
                              fontSize: 14,
                              color: _selectedDate != null
                                  ? ZipherColors.text90
                                  : ZipherColors.text20,
                            ),
                          ),
                        ),
                        Icon(
                          _showCalendar
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: ZipherColors.text20,
                        ),
                      ],
                    ),
                  ),
                ),

                if (_showCalendar) ...[
                  const Gap(8),
                  Container(
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Theme(
                      data: ThemeData.dark().copyWith(
                        colorScheme: ColorScheme.dark(
                          primary: ZipherColors.cyan,
                          surface: ZipherColors.bg,
                          onSurface: ZipherColors.text90,
                        ),
                      ),
                      child: CalendarDatePicker(
                        initialDate: _selectedDate ?? maxDate,
                        firstDate: minDate,
                        lastDate: maxDate,
                        onDateChanged: (v) => setState(() {
                          _selectedDate = v;
                          _useHeight = false;
                        }),
                      ),
                    ),
                  ),
                ],

                const Gap(12),

                // Or block height
                GestureDetector(
                  onTap: () => setState(() => _useHeight = !_useHeight),
                  child: Row(
                    children: [
                      Icon(
                        _useHeight
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 16,
                        color: _useHeight
                            ? ZipherColors.cyan.withValues(alpha: 0.6)
                            : ZipherColors.text20,
                      ),
                      const Gap(6),
                      Text(
                        'Use block height instead',
                        style: TextStyle(
                          fontSize: 12,
                          color: ZipherColors.text40,
                        ),
                      ),
                    ],
                  ),
                ),

                if (_useHeight) ...[
                  const Gap(8),
                  Container(
                    decoration: BoxDecoration(
                      color: ZipherColors.cardBg,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: FormBuilderTextField(
                      name: 'height',
                      controller: _heightController,
                      keyboardType: TextInputType.number,
                      style: TextStyle(
                        fontSize: 14,
                        color: ZipherColors.text90,
                      ),
                      decoration: InputDecoration(
                        hintText: 'e.g. 2000000',
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
                    ),
                  ),
                ],

                const Gap(24),

                // Rescan button
                InkWell(
                  onTap: _rescan,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: ZipherColors.cyan.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.sync_rounded,
                            size: 18,
                            color:
                                ZipherColors.cyan.withValues(alpha: 0.8)),
                        const Gap(8),
                        Text(
                          'Start Full Rescan',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color:
                                ZipherColors.cyan.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const Gap(40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRewindOptions() {
    final recent = checkpoints.take(5).toList();
    return Container(
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (int i = 0; i < recent.length; i++) ...[
            _rewindTile(recent[i]),
            if (i < recent.length - 1)
              Divider(
                height: 1,
                color: ZipherColors.borderSubtle,
                indent: 16,
                endIndent: 16,
              ),
          ],
        ],
      ),
    );
  }

  Widget _rewindTile(Checkpoint cp) {
    final dt =
        DateTime.fromMillisecondsSinceEpoch(cp.timestamp * 1000);
    final dateStr = '${dt.day}/${dt.month}/${dt.year}';
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _rewindTo(cp),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.history_rounded,
                  size: 16,
                  color: ZipherColors.text20),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$dateStr at $timeStr',
                      style: TextStyle(
                        fontSize: 13,
                        color: ZipherColors.text60,
                      ),
                    ),
                    Text(
                      'Block ${cp.height}',
                      style: TextStyle(
                        fontSize: 10,
                        color: ZipherColors.text20,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 16,
                  color: ZipherColors.text10),
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

  void _rewindTo(Checkpoint cp) async {
    final confirmed = await showConfirmDialog(context, 'Rewind',
        'Roll back to block ${cp.height}? This is quick and safe.');
    if (!confirmed) return;
    WarpApi.rewindTo(aa.coin, cp.height);
    Future(() async {
      syncStatus2.sync(true);
    });
    GoRouter.of(context).pop();
  }

  void _rescan() async {
    final h = _useHeight ? _heightController.text : '';
    final d = _selectedDate ?? minDate;

    if (!_useHeight && _selectedDate == null) {
      final confirmed = await showConfirmDialog(context, 'Full Rescan',
          'No date selected. This will rescan from the very beginning and may take a long time. Continue?');
      if (!confirmed) return;
    }

    load(() async {
      final height = h.isNotEmpty
          ? int.parse(h)
          : await WarpApi.getBlockHeightByTime(aa.coin, d);
      final confirmed = await showConfirmDialog(
          context,
          'Full Rescan',
          'Re-sync from block $height? '
              'This may take a while but your funds are safe.');
      if (!confirmed) return;
      aa.reset(height);
      Future(() => syncStatus2.rescan(height));
      GoRouter.of(context).pop();
    });
  }
}

// Keep RewindPage for backward compatibility with router
class RewindPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _RewindState();
}

class _RewindState extends State<RewindPage> {
  @override
  Widget build(BuildContext context) {
    return RescanPage();
  }
}

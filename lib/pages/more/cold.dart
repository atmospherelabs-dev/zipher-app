import 'package:flutter/material.dart';

import '../../generated/intl/messages.dart';
import '../../zipher_theme.dart';
import '../utils.dart';
import '../widgets.dart';

class SignedTxPage extends StatelessWidget {
  final String txBin;
  SignedTxPage(this.txBin);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
        backgroundColor: ZipherColors.bg,
        appBar: AppBar(
            backgroundColor: ZipherColors.surface,
            title: Text(s.signedTx),
            actions: [
              IconButton(
                  onPressed: () => export(context), icon: Icon(Icons.save))
            ]),
        body: AnimatedQR.init(s.signedTx, s.scanSignedTx, txBin));
  }

  export(BuildContext context) async {
    final s = S.of(context);
    await saveFile(txBin, 'tx.bin', s.signedTx);
  }
}

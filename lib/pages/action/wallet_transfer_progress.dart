import 'wallet_conversation.dart';

/// What is known about the Zcash transaction behind a send or swap deposit.
enum TransferBroadcast {
  /// Proving and signing; nothing exists yet.
  signing,

  /// Signing failed before a transaction existed. No funds are reserved.
  notSent,

  /// A server accepted it.
  accepted,

  /// It exists in the wallet but no server confirmed receiving it.
  unreachable,

  /// It exists in the wallet and a node refused it.
  rejected,
}

enum TransferStepState { done, active, pending, failed }

enum TransferTone { progress, success, warning, failure }

class TransferStep {
  const TransferStep(this.title, this.state);
  final String title;
  final TransferStepState state;
}

/// Everything the status card says, derived from observed facts only: the
/// engine's broadcast outcome, the wallet's own history and the provider's
/// reported swap status. Nothing here predicts an outcome.
class TransferProgress {
  const TransferProgress({
    required this.zatoshis,
    required this.broadcast,
    this.resubmits = true,
    this.mined = false,
    this.expired = false,
    this.swapSymbol,
    this.swapNetwork,
    this.swapStatus,
    this.reason,
  });

  final int zatoshis;
  final TransferBroadcast broadcast;

  /// The wallet keeps resubmitting an unaccepted transaction until it expires.
  final bool resubmits;

  /// The wallet has seen the transaction in a block.
  final bool mined;

  /// The transaction passed its expiry height unmined; its inputs are free.
  final bool expired;
  final String? swapSymbol;
  final String? swapNetwork;

  /// Provider status string (1Click), once known.
  final String? swapStatus;

  /// Why nothing was sent, for [TransferBroadcast.notSent].
  final String? reason;

  bool get isSwap => swapSymbol != null;
  String get _zec => '${WalletConversation.formatZec(zatoshis)} ZEC';

  bool get _swapDone => swapStatus == 'SUCCESS' || swapStatus == 'COMPLETED';
  bool get _swapRefunded => swapStatus == 'REFUNDED';
  bool get _swapFailed =>
      swapStatus == 'FAILED' ||
      swapStatus == 'EXPIRED' ||
      swapStatus == 'INCOMPLETE_DEPOSIT';
  bool get _depositSeen =>
      _swapDone ||
      _swapRefunded ||
      swapStatus == 'KNOWN_DEPOSIT_TX' ||
      swapStatus == 'CONFIRMING' ||
      swapStatus == 'PROCESSING';

  /// The provider can only act on a deposit the network has; its status
  /// therefore also proves the Zcash transaction arrived.
  bool get _onNetwork =>
      mined || broadcast == TransferBroadcast.accepted || _depositSeen;

  bool get finished =>
      broadcast == TransferBroadcast.notSent ||
      expired ||
      (isSwap ? _swapDone || _swapRefunded || _swapFailed : mined);

  TransferTone get tone {
    if (broadcast == TransferBroadcast.notSent || (expired && !mined)) {
      return TransferTone.failure;
    }
    if (isSwap && _swapFailed) return TransferTone.failure;
    if (isSwap && _swapRefunded) return TransferTone.warning;
    if (isSwap ? _swapDone : mined) return TransferTone.success;
    if (!_onNetwork && broadcast != TransferBroadcast.signing) {
      return TransferTone.warning;
    }
    return TransferTone.progress;
  }

  String get title {
    final what = isSwap ? '$_zec to $swapSymbol' : _zec;
    if (broadcast == TransferBroadcast.notSent) return 'Not sent';
    if (expired && !mined) {
      return isSwap ? 'Swap not started' : 'Transaction expired';
    }
    if (isSwap) {
      if (_swapDone) return 'Swap complete';
      if (_swapRefunded) return 'Swap refunded';
      if (_swapFailed) return 'Swap needs attention';
      return 'Swapping $what';
    }
    return mined ? 'Sent $what' : 'Sending $what';
  }

  String get badge => switch (tone) {
        TransferTone.success => 'Complete',
        TransferTone.failure =>
          broadcast == TransferBroadcast.notSent ? 'Nothing sent' : 'Failed',
        TransferTone.warning => _swapRefunded
            ? 'Refunded'
            : broadcast == TransferBroadcast.rejected
                ? 'Refused'
                : resubmits
                    ? 'Retrying'
                    : 'Unconfirmed',
        TransferTone.progress => 'In progress',
      };

  List<TransferStep> get steps {
    if (broadcast == TransferBroadcast.notSent) return const [];
    final signing = broadcast == TransferBroadcast.signing;
    final stuck = expired && !mined;
    final sent = _onNetwork
        ? TransferStepState.done
        : signing
            ? TransferStepState.pending
            : stuck || broadcast == TransferBroadcast.rejected
                ? TransferStepState.failed
                : TransferStepState.active;
    final result = <TransferStep>[
      TransferStep(signing ? 'Signing on this device' : 'Signed on this device',
          signing ? TransferStepState.active : TransferStepState.done),
      TransferStep(
          switch (sent) {
            TransferStepState.done => 'Sent to the Zcash network',
            TransferStepState.failed => stuck
                ? 'Never reached the Zcash network'
                : 'Refused by the Zcash network',
            TransferStepState.active => 'Sending to the Zcash network',
            TransferStepState.pending => 'Send to the Zcash network',
          },
          sent),
    ];
    if (!isSwap) {
      result.add(TransferStep(
          mined ? 'Confirmed on Zcash' : 'Confirm on Zcash',
          mined
              ? TransferStepState.done
              : _onNetwork
                  ? TransferStepState.active
                  : TransferStepState.pending));
      return result;
    }
    final network = swapNetwork ?? 'the destination';
    final onNetwork = sent == TransferStepState.done;
    result.add(TransferStep(
        _depositSeen ? 'Deposit confirmed' : 'Confirm the deposit',
        _depositSeen
            ? TransferStepState.done
            : swapStatus == 'INCOMPLETE_DEPOSIT'
                ? TransferStepState.failed
                : onNetwork
                    ? TransferStepState.active
                    : TransferStepState.pending));
    result.add(TransferStep(
        _swapDone
            ? '$swapSymbol delivered on $network'
            : _swapRefunded
                ? 'ZEC refunded to your wallet'
                : 'Swap and deliver $swapSymbol on $network',
        _swapDone || _swapRefunded
            ? TransferStepState.done
            : _swapFailed
                ? TransferStepState.failed
                : _depositSeen
                    ? TransferStepState.active
                    : TransferStepState.pending));
    return result;
  }

  /// One plain sentence about what the user should know or do, if anything.
  String? get notice {
    if (broadcast == TransferBroadcast.notSent) {
      return '${reason ?? 'The transaction could not be prepared.'} Nothing left your wallet and no funds are reserved.';
    }
    if (expired && !mined) {
      return 'This transaction expired before any server accepted it. Nothing was paid and the funds are back in your balance.';
    }
    if (!_onNetwork) {
      final ifExpired = isSwap
          ? 'If it expires, the swap never starts and the ZEC returns to your balance.'
          : 'If it expires, the ZEC returns to your balance.';
      switch (broadcast) {
        case TransferBroadcast.unreachable:
          return resubmits
              ? 'No Zcash server confirmed receiving this yet. Zipher keeps submitting it until it expires. Don’t send it again. $ifExpired'
              : 'No Zcash server confirmed receiving this, and it could not be saved for retry. Check Activity before sending again. $ifExpired';
        case TransferBroadcast.rejected:
          return 'The Zcash network refused this transaction, so nothing was paid${isSwap ? ' and the swap has not started' : ''}. The ZEC it used stays reserved until the transaction expires, then returns to your balance.${resubmits ? ' Zipher retries in case the refusal was temporary.' : ''}';
        case TransferBroadcast.signing:
        case TransferBroadcast.notSent:
        case TransferBroadcast.accepted:
          return null;
      }
    }
    if (isSwap) {
      if (_swapRefunded) {
        return 'The swap could not be completed, so your ZEC was refunded. It shows in your balance once the refund confirms.';
      }
      if (swapStatus == 'INCOMPLETE_DEPOSIT') {
        return 'The deposit was below the quoted amount. Open the swap details to see the refund.';
      }
      if (_swapFailed) {
        return 'The swap did not complete. Open the swap details to check the deposit and refund.';
      }
    }
    return null;
  }
}

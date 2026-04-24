/// EIP-1559 unsigned transaction builder and minimal RLP encoder.
///
/// Pure functions, no state, no I/O. Used by EvmRpc and orchestrators.
class TxBuilder {
  TxBuilder._();

  /// Build an unsigned EIP-1559 (type 0x02) transaction as a hex string.
  static String buildUnsignedEip1559({
    required int chainId,
    required int nonce,
    required int maxPriorityFeePerGas,
    required int maxFeePerGas,
    required int gasLimit,
    required String to,
    required BigInt value,
    required String data,
  }) {
    final items = <List<int>>[
      _rlpEncodeInt(chainId),
      _rlpEncodeInt(nonce),
      _rlpEncodeInt(maxPriorityFeePerGas),
      _rlpEncodeInt(maxFeePerGas),
      _rlpEncodeInt(gasLimit),
      _rlpEncodeBytes(hexToBytes(to)),
      _rlpEncodeBigInt(value),
      _rlpEncodeBytes(hexToBytes(data)),
      _rlpEncodeList([]), // accessList
    ];

    final payload = items.expand((e) => e).toList();
    final list = _rlpEncodeList(payload);
    return bytesToHex([0x02, ...list]);
  }

  /// ABI-encode `transfer(address, uint256)`.
  static List<int> buildErc20TransferCalldata(String to, String amount) {
    final toClean = to.replaceAll('0x', '').replaceAll('0X', '');
    final amountHex = BigInt.parse(amount).toRadixString(16).padLeft(64, '0');

    final data = <int>[0xa9, 0x05, 0x9c, 0xbb]; // transfer selector
    data.addAll(List.filled(12, 0));
    data.addAll(hexToBytes(toClean));
    data.addAll(hexToBytes(amountHex));
    return data;
  }

  // -- RLP encoder -----------------------------------------------------------

  static List<int> _rlpEncodeInt(int value) {
    if (value == 0) return _rlpEncodeBytes([]);
    final bytes = <int>[];
    var v = value;
    while (v > 0) {
      bytes.insert(0, v & 0xFF);
      v >>= 8;
    }
    return _rlpEncodeBytes(bytes);
  }

  static List<int> _rlpEncodeBigInt(BigInt value) {
    if (value == BigInt.zero) return _rlpEncodeBytes([]);
    final bytes = <int>[];
    var v = value;
    while (v > BigInt.zero) {
      bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
      v >>= 8;
    }
    return _rlpEncodeBytes(bytes);
  }

  static List<int> _rlpEncodeBytes(List<int> bytes) {
    if (bytes.length == 1 && bytes[0] < 0x80) return bytes;
    if (bytes.length <= 55) return [0x80 + bytes.length, ...bytes];
    final lenBytes = _intToBytes(bytes.length);
    return [0xb7 + lenBytes.length, ...lenBytes, ...bytes];
  }

  static List<int> _rlpEncodeList(List<int> payload) {
    if (payload.length <= 55) return [0xc0 + payload.length, ...payload];
    final lenBytes = _intToBytes(payload.length);
    return [0xf7 + lenBytes.length, ...lenBytes, ...payload];
  }

  static List<int> _intToBytes(int value) {
    final bytes = <int>[];
    var v = value;
    while (v > 0) {
      bytes.insert(0, v & 0xFF);
      v >>= 8;
    }
    return bytes.isEmpty ? [0] : bytes;
  }

  /// Parse hex string (with or without `0x` prefix) to bytes.
  static List<int> hexToBytes(String hex) {
    var h = hex;
    if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
    if (h.isEmpty) return [];
    if (h.length % 2 != 0) h = '0$h';
    final bytes = <int>[];
    for (var i = 0; i < h.length; i += 2) {
      bytes.add(int.parse(h.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  /// Bytes to lowercase hex string (no 0x prefix).
  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

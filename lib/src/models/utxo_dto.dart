class UtxoDTO {
  final String txid;
  final int vout;
  final int value;
  final List<int> pubKey;

  UtxoDTO({
    required this.txid,
    required this.vout,
    required this.value,
    required this.pubKey,
  });
}

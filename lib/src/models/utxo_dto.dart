class UtxoDTO {
  final String txid;
  final int vout;
  final int value;
  final List<int> pubKey;
  final String address;

  UtxoDTO({
    required this.txid,
    required this.vout,
    required this.value,
    required this.pubKey,
    required this.address,
  }) : assert(pubKey.isNotEmpty);
}

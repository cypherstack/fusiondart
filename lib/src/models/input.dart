import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:convert/convert.dart';
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/models/transaction.dart';

class Input {
  List<int> prevTxid;
  int prevIndex;
  List<int> pubKey;
  int amount;
  List<String> signatures = [];

  Input(
      {required this.prevTxid,
      required this.prevIndex,
      required this.pubKey,
      required this.amount});

  int sizeOfInput() {
    assert(1 < pubKey.length &&
        pubKey.length < 76); // need to assume regular push opcode
    return 108 + pubKey.length;
  }

  int get value {
    return amount;
  }

  String getPubKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return "";
  }

  String getPrivKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return "";
  }

  static Input fromInputComponent(InputComponent inputComponent) {
    return Input(
      prevTxid: inputComponent.prevTxid, // Make sure the types are matching
      prevIndex: inputComponent.prevIndex.toInt(),
      pubKey: inputComponent.pubkey,
      amount: inputComponent.amount.toInt(),
    );
  }

  static Input fromStackUTXOData(
    ({String txid, int vout, int value}) utxoInfo,
  ) {
    return Input(
      prevTxid: utf8.encode(utxoInfo.txid), // Convert txid to a List<int>
      prevIndex: utxoInfo.vout,
      pubKey: utf8.encode('0000'), // Placeholder
      amount: utxoInfo.value,
    );
  }

  void sign(String privateKey, Transaction tx) {
    String message = tx.txid();

    // generate 32 random bytes
    Uint8List aux = Uint8List(32);
    Random random = Random.secure();
    for (int i = 0; i < 32; i++) {
      aux[i] = random.nextInt(256);
    }

    String signature = bip340.sign(privateKey, message, hex.encode(aux));

    signatures.add(signature);
  }

  bool verify(String publicKey, Transaction tx) {
    String message = tx.txid();

    for (String signature in signatures) {
      if (!bip340.verify(publicKey, message, signature)) {
        return false;
      }
    }

    // only return true if no signatures failed
    return true;
  }
}

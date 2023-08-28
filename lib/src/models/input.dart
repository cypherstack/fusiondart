import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:convert/convert.dart';
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/models/transaction.dart';

/// Class that represents an input in a transaction.
///
/// Attributes:
/// - [prevTxid]: The previous transaction id as a list of integers.
/// - [prevIndex]: The previous index number.
/// - [pubKey]: The public key as a list of integers.
/// - [amount]: The amount of cryptocurrency in this input.
class Input {
  List<int> prevTxid;
  int prevIndex;
  List<int> pubKey;
  int amount;
  List<String> signatures = [];

  /// Constructor for Input class.
  Input(
      {required this.prevTxid,
      required this.prevIndex,
      required this.pubKey,
      required this.amount});

  /// Calculates the size of the input.
  ///
  /// Assumes that the public key length is within the valid range for push opcodes.
  ///
  /// Returns:
  ///   The size of the input.
  int sizeOfInput() {
    assert(1 < pubKey.length &&
        pubKey.length < 76); // need to assume regular push opcode
    return 108 + pubKey.length;
  }

  /// Returns the value amount of the Input.
  ///
  /// Returns:
  ///   The value amount of the Input.
  int get value {
    return amount;
  }

  /// Placeholder for getting public key based on an index.
  ///
  /// TODO implement.
  String getPubKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return "";
  }

  /// Placeholder for getting private key based on an index.
  ///
  /// TODO implement
  String getPrivKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return "";
  }

  /// Factory method to create an Input object from an InputComponent.
  ///
  /// Parameters:
  /// - [inputComponent]: The InputComponent from which to create the Input object.
  ///
  /// Returns:
  ///   The Input object.
  static Input fromInputComponent(InputComponent inputComponent) {
    return Input(
      prevTxid: inputComponent.prevTxid, // Make sure the types are matching
      prevIndex: inputComponent.prevIndex.toInt(),
      pubKey: inputComponent.pubkey,
      amount: inputComponent.amount.toInt(),
    );
  }

  /// Factory method to create an Input object from a tuple of UTXO data.
  ///
  /// TODO implement pubKey.
  ///
  /// Parameters:
  /// - [utxoInfo]: The tuple containing UTXO data.
  ///
  /// Returns:
  ///   The Input object.
  static Input fromStackUTXOData(
    (String txId, int vout, int value) utxoInfo,
  ) {
    return Input(
      prevTxid: utf8.encode(utxoInfo.$1), // Convert txId to a List<int>
      prevIndex: utxoInfo.$2,
      pubKey: utf8.encode('0000'), // Placeholder
      amount: utxoInfo.$3,
    );
  }

  /// Signs the transaction.
  ///
  /// Parameters:
  /// - [privateKey]: The private key used for signing.
  /// - [tx]: The transaction object.
  ///
  /// Returns:
  ///   `void`
  void sign(String privateKey, Transaction tx) {
    String message = tx.txid();

    // Generate 32 random bytes for auxiliary data.
    Uint8List aux = Uint8List(32);
    Random random = Random.secure();
    for (int i = 0; i < 32; i++) {
      aux[i] = random.nextInt(256);
    }

    // Sign the message.
    String signature = bip340.sign(privateKey, message, hex.encode(aux));

    // Add the signature to the list of signatures.
    signatures.add(signature);
  }

  /// Verifies the signatures in the transaction.
  ///
  /// Parameters:
  /// - [publicKey]: The public key used for verification.
  /// - [tx]: The transaction object.
  ///
  /// Returns:
  ///   `true` if verification passes for all signatures, otherwise `false`.
  bool verify(String publicKey, Transaction tx) {
    String message = tx.txid();

    // Loop through all the signatures and verify them.
    for (String signature in signatures) {
      if (!bip340.verify(publicKey, message, signature)) {
        return false;
      }
    }

    // Return true if all signatures are verified.
    return true;
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:fusiondart/src/models/transaction.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/util.dart';

/// Input component class.
///
/// Based on the protobuf definition of an InputComponent.
///
/// The input contains the following fields:
/// - [prevTxid]: The transaction id as a list of integers.
/// - [prevIndex]: The index number of the output (vout).
/// - [pubKey]: The public key as a list of integers.
/// - [amount]: The amount of cryptocurrency in this input as an integer.
/// - [signatures]: List of signatures for the input.  This is not a required
///  field in the input.
///
/// TODO: getPubKey and getPrivKey.
class Input {
  /// The transaction id as a list of integers.
  List<int> prevTxid;

  /// The index number of the output (vout).
  int prevIndex;

  /// The public key as a list of integers.
  List<int> pubKey;
  // What we really need is a List<List<int> pubKey> pubKeys...

  /// A list of public keys as lists of integers.
  List<List<int>> pubKeys = [];
  // This isn't used yet, but it's used in the python.
  // This is where it's accessed:
  // https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L971
  // This is where it's set:
  // https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L347
  // The problem with this is that we need a class which encompasses multiple
  // Inputs, or...

  /// The amount of cryptocurrency in this input as an integer.
  int amount; // Using an int will impact portability to cryptocurrencies with smaller units.

  /// List of signatures for the input.
  List<Uint8List> signatures = [];
  // Signatures are added in the `sign` method and verified in the `verify` method.

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
  /// See https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash_plugins/fusion/util.py#L51-L55.
  ///
  /// Returns:
  ///   The size of the input.
  int sizeOfInput() {
    // Sizes of inputs after signing:
    // 32 + 8 + 1 + 1 + [length of sig] + 1 + [length of pubkey]
    // = 141 for compressed pubkeys, 173 for uncompressed.
    assert(1 < pubKey.length &&
        pubKey.length < 76); // 76 bytes is the max length of a push opcode.
    return 108 + pubKey.length; // 108 bytes for the rest of the input.
  }

  /// Returns the value amount of the Input.
  ///
  /// Returns:
  ///   The value amount of the Input as an int.
  int get value {
    return amount;
  }

  /// Placeholder for getting public key based on an index.
  ///
  /// This function is confusing because in the python code, the public key is
  /// selected from a list of public keys.  We don't have that list.
  ///
  /// See
  /// https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L971C44-L971C44
  /// where keypairs is
  /// https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L301
  /// and set in
  /// https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L339
  /// https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L346
  ///
  /// TODO implement.
  Uint8List getPubKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return Uint8List(0);
  }

  /// Placeholder for getting private key based on an index.
  ///
  /// See https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L971C44-L971C44
  ///
  /// TODO implement
  Uint8List getPrivKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return Uint8List(0);
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
      prevIndex: inputComponent.prevIndex,
      pubKey: inputComponent.pubkey,
      amount: inputComponent.amount.toInt(),
    );
  }

  /// Factory method to create an Input object from a Record of UTXO data.
  ///
  /// Parameters:
  /// - [utxoInfo]: The record containing UTXO data.
  ///
  /// Returns:
  ///   The Input object.
  static Input fromWallet({
    required String txId,
    required int vout,
    required int value,
    required List<int> pubKey,
  }) {
    return Input(
      // TODO: Are raw bytes wanted here or hex?
      prevTxid: utf8.encode(txId), // Convert txId to a List<int>.
      prevIndex: vout,
      pubKey: pubKey,
      amount: value,
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
  void sign(Uint8List privateKey, Transaction tx) {
    // TODO reverse???
    String message = tx.txid();

    // Sign the message.
    final signature =
        Utilities.schnorrSign(privateKey, message.toUint8ListFromHex);

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
  bool verify(Uint8List publicKey, Transaction tx) {
    // TODO reverse???
    final message = tx.txid().toUint8ListFromHex;

    // Loop through all the signatures and verify them.
    for (final signature in signatures) {
      if (!Utilities.schnorrVerify(publicKey, signature, message)) {
        return false;
      }
    }

    // Return true if all signatures are verified.
    return true;
  }

  /// Overrides the toString method to provide detailed information about the instance.
  ///
  /// Returns:
  ///   A string representing the state of this `Input` object.
  @override
  String toString() {
    return 'Input {'
        ' prevTxid: ${hex.encode(prevTxid)},'
        ' prevIndex: $prevIndex,'
        ' pubKey: ${hex.encode(pubKey)},'
        ' amount: $amount,'
        ' signatures: $signatures'
        ' }';
  }
}

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_list_int.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/models/input.dart';
import 'package:fusiondart/src/models/output.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';

/// Class that represents a transaction.
///
/// Translated from https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L289
class Transaction {
  List<Input> inputs = [];
  List<Output> outputs = [];

  /// Instance variable for the locktime of the transaction.
  BigInt locktime = BigInt
      .zero; // https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L311

  /// Instance variable for the version of the transaction.
  BigInt version = BigInt
      .one; // https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L312

  /// Default constructor for the Transaction class.
  Transaction();

  /// Factory method to create a Transaction from components and a session hash.
  ///
  /// Parameters:
  /// - [allComponents]: The components for the transaction.
  /// - [sessionHash]: The session hash for the transaction.
  ///
  /// Returns:
  ///   A tuple containing the Transaction and a list of input indices.
  static (Transaction, List<int>) txFromComponents(
    List<List<int>> allComponents,
    List<int> sessionHash,
  ) {
    // Initialize a new Transaction.
    Transaction tx = Transaction();

    final List<int> inputIndices = [];
    final comps =
        allComponents.map((e) => Component()..mergeFromBuffer(e)).toList();

    for (int i = 0; i < comps.length; i++) {
      final comp = comps[i];
      if (comp.hasInput()) {
        final inp = comp.input;
        if (inp.prevTxid.length != 32) {
          throw FusionError("bad component prevout");
        }

        final input = Input.fromInputComponent(inp);
        tx.inputs.add(input);
        inputIndices.add(i);
      } else if (comp.hasOutput()) {
        final output = Output.fromOutputComponent(comp.output);
        tx.outputs.add(output);
      } else if (!comp.hasBlank()) {
        throw FusionError("bad component");
      }
    }

    return (tx, inputIndices);
  }

  /// Serializes the preimage of the transaction.
  ///
  /// Translated from https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L746
  ///
  /// Parameters:
  /// - [index]: The index of the input.
  /// - [hashType]: The type of hash.
  /// - [useCache] (optional): Whether to use cached data.
  ///
  /// Returns:
  ///   A list of integers representing the serialized preimage.
  Uint8List serializePreimageBytes(int i,
      {int nHashType = 0x00000041, bool useCache = false}) {
    if ((nHashType & 0xff) != 0x41) {
      throw ArgumentError(
          "Other hash types not supported; submit a PR to fix this!");
    }

    Uint8List nVersion = version.toBytes;
    Uint8List hashTypeBytes = BigInt.from(nHashType).toBytes;
    Uint8List nLocktime = locktime.toBytes;

    var txin = inputs[i];
    Uint8List outpoint = serializeOutpointBytes(txin);
    Uint8List preimageScript = getPreimageScript(txin).toUint8ListFromHex;

    /*
    var inputToken = txin['token_data'];
    Uint8List serInputToken;
    if (inputToken != null) {
      serInputToken = Uint8List.fromList([
        token.PREFIX_BYTE,
        ...inputToken.serialize()
      ]); // Adjust based on Dart token structure
    } else {
      serInputToken = Uint8List(0);
    }
    */

    Uint8List scriptCode = Uint8List.fromList(
        [...varIntBytes(preimageScript.length), ...preimageScript]);
    Uint8List amount;
    try {
      amount = intToBytes(txin['value'], 8);
    } catch (e) {
      throw FusionError(
          'InputValueMissing'); // Adjust the error type based on your Dart codebase
    }
    Uint8List nSequence = intToBytes(txin['sequence'] ?? 0xffffffff - 1, 4);

    var hashPrevouts, hashSequence, hashOutputs;
    // Unpack values from calcCommonSighash function
    (hashPrevouts, hashSequence, hashOutputs) =
        calcCommonSighash(useCache: useCache);

    Uint8List preimage = Uint8List.fromList([
      ...nVersion,
      ...hashPrevouts,
      ...hashSequence,
      ...outpoint,
      ...serInputToken,
      ...scriptCode,
      ...amount,
      ...nSequence,
      ...hashOutputs,
      ...nLocktime,
      ...hashTypeBytes
    ]);

    return preimage;
  }

  /// Serializes the transaction.
  ///
  /// Returns:
  ///   A string representing the serialized transaction.
  String serializePreimage(int i,
      {int nHashType = 0x00000041, bool useCache = false}) {
    return serializePreimageBytes(i, nHashType: nHashType, useCache: useCache)
        .toHex;
  }

  // Serialize outpoint
  static String serializeOutpoint(Input txin) {
    return serializeOutpointBytes(txin).toHex;
  }

  static Uint8List serializeOutpointBytes(Input txin) {
    return Uint8List.fromList([
      ...hex.decode(txin.prevTxid.reversed).toUint8ListFromHex, // TODO
      ...BigInt.from(txin.prevIndex).toBytes
    ]);
  }

  static String getPreimageScript(Input txin) {
    throw UnimplementedError();
  }

  List<Uint8List> calcCommonSighash({bool useCache = false}) {
    throw UnimplementedError();
  }

  Uint8List serializeOutputNBytes(int n) {
    throw UnimplementedError();
  }

  /// Checks if the transaction is complete.
  ///
  /// TODO implement.
  ///
  /// Returns:
  ///   A boolean value indicating if the transaction is complete.
  bool isComplete() {
    throw UnimplementedError();
  }

  /// Gets the transaction ID.
  ///
  /// TODO implement.
  ///
  /// Returns:
  ///   A string representing the transaction ID.
  String txid() {
    throw UnimplementedError();
  }
}

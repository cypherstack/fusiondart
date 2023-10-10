import 'dart:typed_data';

import 'package:bitbox/bitbox.dart' as bitbox;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';

/// Class that represents a transaction.
///
/// Translated from https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L289
class Transaction {
  final List<bitbox.Input> inputs;
  final List<Output> outputs;

  /// Instance variable for the locktime of the transaction.
  BigInt locktime = BigInt
      .zero; // https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L311

  /// Instance variable for the version of the transaction.
  BigInt version = BigInt
      .one; // https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L312

  /// Default constructor for the Transaction class.
  Transaction(this.inputs, this.outputs);

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
    coinlib.NetworkParams network,
  ) {
    // Initialize a new Transaction.
    Transaction tx = Transaction([], []);

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

        final input = bitbox.Input(
          hash: Uint8List.fromList(inp.prevTxid),
          index: inp.prevIndex,
          sequence: 0xffffffff,
          pubkeys: [Uint8List.fromList(inp.pubkey)],
          value: inp.amount.toInt(),
        );

        tx.inputs.add(input);
        inputIndices.add(i);
      } else if (comp.hasOutput()) {
        final output = Output.fromOutputComponent(comp.output, network);
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
  ///   A Uint8List representing the serialized preimage.
  Uint8List serializePreimageBytes(
    int i, {
    required coinlib.NetworkParams network,
    int nHashType = 0x00000041,
    bool useCache = false,
  }) {
    if ((nHashType & 0xff) != 0x41) {
      throw ArgumentError(
          "Other hash types not supported; submit a PR to fix this!");
    }

    final nVersion = version.toBytesPadded(4);
    final hashTypeBytes = BigInt.from(nHashType).toBytesPadded(4);
    final nLocktime = locktime.toBytesPadded(4);

    bitbox.Input txin = inputs[i];
    Uint8List outpoint = _serializeOutpointBytes(txin);
    Uint8List preimageScript = _getPreimageScript(txin);

    final Uint8List serInputToken;
    // TODO handle tokens.
    /*if (txin.hasToken) {
      throw Exception("Tried to use an input with token data in fusion!");
      // serInputToken = Uint8List.fromList([0xef, ...inputToken.serialize()]);
      // See https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L760
      // and https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/token.py#L165
      // 0xef should be moved to a Bitcoin Cash opcode enum or similar, see  https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/bitcoin.py#L252
    } else {*/
    serInputToken = Uint8List(0);
    /*}*/

    final scriptCode = Uint8List.fromList([
      ..._varIntBytes(BigInt.from(preimageScript.length)),
      ...preimageScript
    ]);
    Uint8List amount;
    try {
      amount = BigInt.from(txin.value!).toBytesPadded(8);
    } catch (e) {
      throw FusionError('InputValueMissing');
    }
    Uint8List nSequence =
        BigInt.from(txin.sequence ?? (0xffffffff - 1)).toBytesPadded(4);

    /*
    final amount = txin.value.toBytesPadded(8);
    final nSequence = BigInt.from(txin.sequence).toBytesPadded(4);
     */

    // Unpack values from calcCommonSighash function
    ({
      Uint8List hashOutputs,
      Uint8List hashPrevouts,
      Uint8List hashSequence
    }) commonSighash = _calcCommonSighash(network: network, useCache: useCache);

    Uint8List hashPrevouts, hashSequence, hashOutputs;
    (hashPrevouts, hashSequence, hashOutputs) = (
      commonSighash.hashPrevouts,
      commonSighash.hashSequence,
      commonSighash.hashOutputs,
    );

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

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L610
  Uint8List _serializeOutpointBytes(bitbox.Input txin) {
    return Uint8List.fromList([
      ...txin.hash!.reversed,
      ...BigInt.from(txin.index!).toBytesPadded(4),
    ]);
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L589
  Uint8List _getPreimageScript(bitbox.Input txin) {
    return txin.script!;
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/bitcoin.py#L369
  Uint8List _varIntBytes(BigInt i) {
    // Based on: https://en.bitcoin.it/wiki/Protocol_specification#Variable_length_integer
    if (i < BigInt.from(0xfd)) {
      return i.toBytes;
    } else if (i <= BigInt.from(0xffff)) {
      return Uint8List.fromList([0xfd, ...i.toBytesPadded(2)]);
    } else if (i <= BigInt.from(0xffffffff)) {
      return Uint8List.fromList([0xfe, ...i.toBytesPadded(4)]);
    } else {
      return Uint8List.fromList([0xff, ...i.toBytesPadded(8)]);
    }
  }

  ({
    Uint8List hashPrevouts,
    Uint8List hashSequence,
    Uint8List hashOutputs,
  }) _calcCommonSighash({
    required coinlib.NetworkParams network,
    bool useCache = false,
  }) {
    // if (useCache) {
    //   try {
    //     List<int> cmeta =
    //         _cachedSighashTup[0]; // TODO cache sighash tuple (record).
    //     List<Uint8List> res = _cachedSighashTup[1];
    //     if (listEquals(cmeta, meta)) {
    //       return res;
    //     } else {
    //       _cachedSighashTup = null;
    //     }
    //   } catch (e) {
    //     // Handle the exception or simply continue
    //   }
    // }

    final List<int> prePrevouts = [];
    final List<int> preSeq = [];
    for (final input in inputs) {
      prePrevouts.addAll(_serializeOutpointBytes(input));
      preSeq.addAll(
        BigInt.from(input.sequence ?? (0xffffffff - 1)).toBytesPadded(4),
      );
    }

    final List<int> preOuts = [];
    for (int i = 0; i < outputs.length; i++) {
      preOuts.addAll(_serializeOutputNBytes(i, network));
    }

    final hashPrevouts = Utilities.doubleSha256(
      Uint8List.fromList(prePrevouts),
    );

    final hashSequence = Utilities.doubleSha256(
      Uint8List.fromList(preSeq),
    );

    final hashOutputs = Utilities.doubleSha256(
      Uint8List.fromList(preOuts),
    );

    // _cachedSighashTup = [
    //   meta,
    //   [hashPrevouts, hashSequence, hashOutputs]
    // ]; // TODO cache sighash tuple (record).
    return (
      hashPrevouts: hashPrevouts,
      hashSequence: hashSequence,
      hashOutputs: hashOutputs
    );
  }

  Uint8List _serializeOutputNBytes(
    int n,
    coinlib.NetworkParams network,
  ) {
    assert(n >= 0 && n < outputs.length);

    final output = outputs[n];

    final amount = output.value;

    List<int> buf = [];

    final amountBytes1 = (ByteData(8)..setInt64(0, amount, Endian.big))
        .buffer
        .asUint8List(); // Convert amount to bytes

    final amountBytes2 = BigInt.from(amount).toBytesPadded(8);

    assert(amountBytes1.equals(amountBytes2));

    buf.addAll(amountBytes2);

    final spk = Utilities.scriptOf(address: output.address, network: network);

    buf.addAll(_varIntBytes(BigInt.from(spk.length)));
    buf.addAll(spk);

    return Uint8List.fromList(buf);
  }
}

import 'dart:typed_data';

import 'package:bitbox/bitbox.dart' as bitbox;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/models/output.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';

/// Class that represents a transaction.
///
/// Translated from https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L289
class Transaction {
  List<bitbox.Input> inputs = [];
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
    coinlib.NetworkParams network,
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
    Uint8List outpoint = serializeOutpointBytes(txin);
    Uint8List preimageScript = txin.script!; // TODO validate null assertion.

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
      ...varIntBytes(BigInt.from(preimageScript.length)),
      ...preimageScript
    ]);
    Uint8List amount;
    try {
      amount = BigInt.from(txin.value ?? 0).toBytes;
    } catch (e) {
      throw FusionError(
          'InputValueMissing'); // Adjust the error type based on your Dart codebase
    }
    Uint8List nSequence = BigInt.from(txin.sequence ?? 0xffffffff - 1).toBytes;
    // TODO verify default of 0xffffffff - 1 is acceptable.

    /*
    final amount = txin.value.toBytesPadded(8);
    final nSequence = BigInt.from(txin.sequence).toBytesPadded(4);
     */

    // Unpack values from calcCommonSighash function
    ({
      Uint8List hashOutputs,
      Uint8List hashPrevouts,
      Uint8List hashSequence
    }) commonSighash = calcCommonSighash(
        network: network,
        useCache: useCache); // TODO fix this python-transliterationalism.

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

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L606
  static String serializeOutpoint(bitbox.Input txin) {
    return serializeOutpointBytes(txin).toHex;
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L610
  static Uint8List serializeOutpointBytes(bitbox.Input txin) {
    return Uint8List.fromList([
      ...txin.hash!, // TODO Does this need reversing here??
      // ...hex.encode(txin.prevTxid.reversed as List<int>).toUint8ListFromHex,
      ...BigInt.from(txin.index!).toBytesPadded(4),
    ]);
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/bitcoin.py#L369
  Uint8List varIntBytes(BigInt i) {
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
  }) calcCommonSighash({
    required coinlib.NetworkParams network,
    bool useCache = false,
  }) {
    List<bitbox.Input> inputs = this.inputs;
    int nOutputs =
        outputs.length; // Assuming there's a 'outputs' getter in your class
    List<int> meta = [inputs.length, nOutputs];

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

    Uint8List hashPrevouts = Uint8List.fromList(crypto.sha256
        .convert(Uint8List.fromList(inputs
            .map((txin) => serializeOutpointBytes(txin))
            .expand((x) => x)
            .toList()))
        .bytes);

    Uint8List hashSequence = Uint8List.fromList(crypto.sha256
        .convert(Uint8List.fromList(inputs
            .map((txin) =>
                BigInt.from(txin.sequence ?? 0xffffffff - 1).toBytesPadded(4))
            .expand((x) => x)
            .toList()))
        .bytes);

    Uint8List hashOutputs = Uint8List.fromList(crypto.sha256
        .convert(Uint8List.fromList(
            List.generate(nOutputs, (n) => serializeOutputNBytes(n, network))
                .expand((x) => x)
                .toList()))
        .bytes);

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

  Uint8List serializeOutputNBytes(
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

    final spk = coinlib.Address.fromString(
      bitbox.Address.toLegacyAddress(
        output.address,
      ),
      network,
    ).program.script.compiled;

    buf.addAll(varIntBytes(BigInt.from(spk.length)));
    buf.addAll(spk);

    return Uint8List.fromList(buf);
  }
}

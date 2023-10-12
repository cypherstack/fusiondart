import 'dart:typed_data';

import 'package:bitbox/bitbox.dart' as bitbox;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/protocol.dart';

// Translated from https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L289
/// Class that represents a transaction.
class Transaction {
  final List<bitbox.Input> inputs;
  final List<Output> outputs;

  /// Instance variable for the locktime of the transaction.
  BigInt locktime = BigInt.zero;
  // https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L311

  /// Instance variable for the version of the transaction.
  BigInt version = BigInt.one;
  // https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L312

  /// Default constructor for the Transaction class.
  Transaction(this.inputs, this.outputs);

  /// Factory method to create a Transaction from components and a session hash.
  static ({
    Transaction tx,
    List<({bitbox.Input input, int compIndex})> inputAndCompIndexes
  }) txFromComponents(
    List<List<int>> allComponents,
    List<int> sessionHash,
    coinlib.NetworkParams network,
  ) {
    // Initialize a new Transaction.
    Transaction tx = Transaction([], []);

    final List<({bitbox.Input input, int compIndex})> inputAndCompIndexes = [];
    final comps =
        allComponents.map((e) => Component()..mergeFromBuffer(e)).toList();

    assert(sessionHash.length == 32);

    final fuseId = Protocol.FUSE_ID.toUint8ListFromUtf8;
    assert(fuseId.length == 4);
    final prefix = [4, ...fuseId];

    final opReturnScript = coinlib.Script.decompile(Uint8List.fromList([
      0x6a, // OP_RETURN
      ...prefix,
      0x20, // aka 32 aka PUSH
      ...sessionHash,
    ]));

    tx.outputs.add(Output.fromScriptPubKey(
        value: 0, scriptPubkey: opReturnScript.compiled));

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

        inputAndCompIndexes.add(
          (input: input, compIndex: i),
        );
      } else if (comp.hasOutput()) {
        final output = Output.fromOutputComponent(comp.output);
        tx.outputs.add(output);
      } else if (!comp.hasBlank()) {
        throw FusionError("bad component");
      }
    }

    return (tx: tx, inputAndCompIndexes: inputAndCompIndexes);
  }

  Uint8List serializePreimageBytesAlt(
    int i, {
    required coinlib.NetworkParams network,
    int nHashType = 0x00000041,
    bool useCache = false,
  }) {
    final tx = bitbox.Transaction();

    tx.inputs.addAll(inputs);
    tx.outputs.addAll(outputs.map((e) => bitbox.Output(
          script: e.scriptPubKey,
          value: e.value,
        )));

    final input = inputs[i];

    final address = coinlib.P2PKHAddress.fromPublicKey(
      coinlib.ECPublicKey.fromHex(input.pubkeys!.first!.toHex),
      version: network.p2pkhPrefix,
    );

    final pubKeyScript = address.program.script.compiled;

    // final pre = tx.hashForCashSignature(
    //   i,
    //   pubKeyScript,
    //   input.value!,
    //   0x41,
    // ) as Uint8List;

    final tx2 = coinlib.Transaction(
      inputs: inputs.map(
        (e) => coinlib.P2PKHInput(
          prevOut: coinlib.OutPoint(
            e.hash!,
            e.index!,
          ),
          publicKey: coinlib.ECPublicKey.fromHex(
            e.pubkeys![0]!.toHex,
          ),
        ),
      ),
      outputs: outputs.map(
        (e) => coinlib.Output.fromScriptBytes(
          BigInt.from(e.value),
          e.scriptPubKey,
        ),
      ),
      version: version.toInt(),
    );
    //
    // final pre2 = tx2.signatureHashForWitness(
    //   i,
    //   coinlib.Script.decompile(pubKeyScript),
    //   BigInt.from(input.value!),
    //   coinlib.SigHashType.fromValue(nHashType),
    // );

    Uint8List _hashConcatWritable(Iterable<coinlib.Writable> list) {
      return Utilities.doubleSha256(
        Uint8List.fromList(
          list.map((e) => e.toBytes().toList()).reduce((a, b) => a + b),
        ),
      );
    }

    final hashPrevouts = _hashConcatWritable(tx2.inputs.map((i) => i.prevOut));

    final sequenceBytes = Uint8List(4 * tx2.inputs.length);
    final sequenceWriter = coinlib.BytesWriter(sequenceBytes);
    for (final input in tx2.inputs) {
      sequenceWriter.writeUInt32(input.sequence);
    }
    final hashSequence = Utilities.doubleSha256(sequenceBytes);

    final hashOutputs = _hashConcatWritable(tx2.outputs);

    final thisIn = tx2.inputs[i];

    // Get data for input
    late coinlib.Script scriptCode2;

    if (thisIn is coinlib.PKHInput) {
      // Require explicit cast for a mixin
      final pk = (thisIn as coinlib.PKHInput).publicKey;
      scriptCode2 = coinlib.P2PKH.fromPublicKey(pk).script;
    } else if (thisIn is coinlib.P2SHMultisigInput) {
      // For P2SH the script code is the redeem script
      scriptCode2 = thisIn.program.script;
    } else {
      throw Exception("${thisIn.runtimeType} not a signable input");
    }

    final compiledScript = scriptCode2.compiled;

    assert(compiledScript.equals(pubKeyScript));

    final size =
        156 + (coinlib.MeasureWriter()..writeVarSlice(compiledScript)).size;
    final bytes = Uint8List(size);
    final writer = coinlib.BytesWriter(bytes);
    writer.writeUInt32(version.toInt());
    writer.writeSlice(hashPrevouts);
    writer.writeSlice(hashSequence);
    thisIn.prevOut.write(writer);
    writer.writeVarSlice(compiledScript);
    writer.writeUInt64(BigInt.from(input.value!));
    writer.writeUInt32(thisIn.sequence);
    writer.writeSlice(hashOutputs);
    writer.writeUInt32(locktime.toInt());
    writer.writeUInt32(nHashType);

    return bytes;
  }

  /// Serializes the preimage of the transaction.
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
    Uint8List preimageScript = _getPreimageScript(txin, network);

    final serInputToken = Uint8List(0);

    final scriptCode = Uint8List.fromList([
      ..._varIntBytes(BigInt.from(preimageScript.length)),
      ...preimageScript
    ]);

    final Uint8List amount;
    try {
      amount = BigInt.from(txin.value!).toBytesPadded(8);
    } catch (e) {
      throw FusionError('InputValueMissing');
    }

    final nSequence =
        BigInt.from(txin.sequence ?? (0xffffffff - 1)).toBytesPadded(4);

    final commonSighash = _calcCommonSighash(
      network: network,
      useCache: useCache,
    );

    Uint8List preimage = Uint8List.fromList([
      ...nVersion,
      ...commonSighash.hashPrevouts,
      ...commonSighash.hashSequence,
      ...outpoint,
      ...serInputToken,
      ...scriptCode,
      ...amount,
      ...nSequence,
      ...commonSighash.hashOutputs,
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
  Uint8List _getPreimageScript(
      bitbox.Input txin, coinlib.NetworkParams network) {
    final adr = coinlib.P2PKHAddress.fromPublicKey(
      coinlib.ECPublicKey.fromHex(
        Uint8List.fromList(txin.pubkeys!.first!).toHex,
      ),
      version: network.p2pkhPrefix,
    );

    return adr.program.script.compiled;
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/bitcoin.py#L369
  /// Returns the variable length bytes for a given integer [i].
  ///
  /// Based on Based on: https://en.bitcoin.it/wiki/Protocol_specification#Variable_length_integer
  Uint8List _varIntBytes(BigInt i) {
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

  /// Calculates the common sighash for the transaction.
  ///
  /// TODO remove sighash tuple caching comments when they're confirmed unneeded.
  ({
    Uint8List hashPrevouts,
    Uint8List hashSequence,
    Uint8List hashOutputs,
  }) _calcCommonSighash({
    required coinlib.NetworkParams network,
    bool useCache = false,
  }) {
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

    return (
      hashPrevouts: hashPrevouts,
      hashSequence: hashSequence,
      hashOutputs: hashOutputs
    );
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L675
  /// Serializes the output at index n.
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

    final spk = output.scriptPubKey;

    buf.addAll(_varIntBytes(BigInt.from(spk.length)));
    buf.addAll(spk);

    return Uint8List.fromList(buf);
  }
}

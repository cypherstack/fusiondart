import 'dart:typed_data';

import 'package:bitbox/bitbox.dart' as bitbox;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/exceptions.dart';
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
    coinlib.Network network,
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

  /// Serializes the preimage of the transaction.
  Uint8List serializePreimageBytes(
    int i, {
    required coinlib.Network network,
    int nHashType = 0x00000041,
    bool useCache = false,
  }) {
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

    final size =
        156 + (coinlib.MeasureWriter()..writeVarSlice(compiledScript)).size;
    final bytes = Uint8List(size);
    final writer = coinlib.BytesWriter(bytes);
    writer.writeUInt32(version.toInt());
    writer.writeSlice(hashPrevouts);
    writer.writeSlice(hashSequence);
    thisIn.prevOut.write(writer);
    writer.writeVarSlice(compiledScript);
    writer.writeUInt64(BigInt.from(inputs[i].value!));
    writer.writeUInt32(thisIn.sequence);
    writer.writeSlice(hashOutputs);
    writer.writeUInt32(locktime.toInt());
    writer.writeUInt32(nHashType);

    return bytes;
  }
}

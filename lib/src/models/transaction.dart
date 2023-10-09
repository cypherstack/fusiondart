import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
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
  ///   A Uint8List representing the serialized preimage.
  Uint8List serializePreimageBytes(int i,
      {int nHashType = 0x00000041, bool useCache = false}) {
    if ((nHashType & 0xff) != 0x41) {
      throw ArgumentError(
          "Other hash types not supported; submit a PR to fix this!");
    }

    Uint8List nVersion = version.toBytes;
    Uint8List hashTypeBytes = BigInt.from(nHashType).toBytes;
    Uint8List nLocktime = locktime.toBytes;

    Input txin = inputs[i];
    Uint8List outpoint = serializeOutpointBytes(txin);
    Uint8List preimageScript = getPreimageScript(txin).toUint8ListFromHex;

    final Uint8List serInputToken;
    if (txin.hasToken) {
      throw Exception("Tried to use an input with token data in fusion!");
      // serInputToken = Uint8List.fromList([0xef, ...inputToken.serialize()]);
      // See https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/transaction.py#L760
      // and https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/token.py#L165
      // 0xef should be moved to a Bitcoin Cash opcode enum or similar, see  https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/bitcoin.py#L252
    } else {
      serInputToken = Uint8List(0);
    }

    Uint8List scriptCode = Uint8List.fromList([
      ...varIntBytes(BigInt.from(preimageScript.length)),
      ...preimageScript
    ]);
    Uint8List amount;
    try {
      amount = txin.value.toBytes;
    } catch (e) {
      throw FusionError(
          'InputValueMissing'); // Adjust the error type based on your Dart codebase
    }
    Uint8List nSequence =
        BigInt.from(txin.sequence).toBytes; // TODO fix txin.sequence getter
    // Was `txin['sequence'] ?? 0xffffffff - 1`.

    // Unpack values from calcCommonSighash function
    ({
      Uint8List hashOutputs,
      Uint8List hashPrevouts,
      Uint8List hashSequence
    }) commonSighash = calcCommonSighash(
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

  /// Serializes the transaction.
  ///
  /// Returns:
  ///   A string representing the serialized transaction.
  String serializePreimage(int i,
      {int nHashType = 0x00000041, bool useCache = false}) {
    return serializePreimageBytes(i, nHashType: nHashType, useCache: useCache)
        .toHex;
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L606
  static String serializeOutpoint(Input txin) {
    return serializeOutpointBytes(txin).toHex;
  }

  // Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L610
  static Uint8List serializeOutpointBytes(Input txin) {
    return Uint8List.fromList([
      ...hex
          .encode(txin.prevTxid.reversed as List<int>)
          .toUint8ListFromHex, // Is Iterable<int> as List<int> kosher?
      ...BigInt.from(txin.prevIndex).toBytes
    ]);
  }

  /// Translated from https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/transaction.py#L589
  static String getPreimageScript(Input txin) {
    String type = txin.type; // TODO Input.type
    if (type == 'p2pkh') {
      return txin.address // TODO Input.address
          .toScript() // TODO Address.toScript
          .toHex();
    } else if (type == 'p2sh') {
      List<String> pubkeys, xPubkeys = getSortedPubkeys(txin);
      return multisigScript(
          pubkeys,
          txin[
              'num_sig']); // Implement or reference the multisigScript function
    } else if (type == 'p2pk') {
      String pubkey = txin['pubkeys'][0];
      return publicKeyToP2pkScript(
          pubkey); // Implement or reference the publicKeyToP2pkScript function
    } else if (type == 'unknown') {
      return txin['scriptCode'];
    } else {
      throw Exception('Unknown txin type $type');
    }
  }

  /// Sort pubkeys and x_pubkeys, using the order of pubkeys
  ///
  /// Note: this function is CRITICAL to get the correct order of pubkeys in
  /// multisignatures; avoid changing.
  List<List<dynamic>> getSortedPubkeys(Input txin) {
    List<String> xPubKeys =
        txin.xPubKeys; // TODO Input.xPubKeys and properly type XPUBs.
    List<String>? pubKeys =
        txin.pubKeys; // TODO Input.pubKeys and properly type public key.

    if (pubKeys == null) {
      pubKeys = xPubKeys
          .map((x) => xpubkeyToPubkey(x)!)
          .toList(); // TODO validate null assertion.

      var zipped =
          List.generate(pubKeys!.length, (i) => [pubKeys[i], xPubKeys[i]]);
      zipped.sort((a, b) => a[0].compareTo(b[0]));

      txin.pubKeys = pubKeys = [for (var item in zipped) item[0]];
      txin.xPubKeys = xPubKeys = [for (var item in zipped) item[1]];
    }

    return [pubKeys, xPubKeys];
  }

  List<dynamic>? xpubkeyToAddress(String xPubkey) {
    coinlib.HDPublicKey? hdPubkey = coinlib.HDPublicKey.decode(xPubkey);
    if (xPubkey.startsWith('fd')) {
      String address = coinlib.bitcoin.scriptToAddress(xPubkey.substring(2));
      // coinlib.P2PKHAddress.fromPublicKey(pubkey, version: version).toString or similar?
      return [xPubkey, address];
    }

    String? pubkey;

    if (['02', '03', '04'].contains(xPubkey.substring(0, 2))) {
      pubkey = xPubkey;
    } else if (xPubkey.startsWith('ff')) {
      var result = BIP32KeyStore.parseXpubkey(xPubkey);
      String xpub = result[0];
      var s = result[1];
      pubkey = BIP32KeyStore.getPubkeyFromXpub(xpub, s);
    } else if (xPubkey.startsWith('fe')) {
      var result = OldKeyStore.parseXpubkey(xPubkey);
      String mpk = result[0];
      var s = result[1];
      pubkey = OldKeyStore.getPubkeyFromMpk(mpk, s[0], s[1]);
    } else {
      throw Exception("Cannot parse pubkey");
    }

    if (pubkey != null) {
      Address address = Address.fromPubkey(pubkey);
      return [pubkey, address];
    }
    return null; // Return null if no pubkey found
  }

  String? xpubkeyToPubkey(String xPubkey) {
    var result = xpubkeyToAddress(xPubkey);
    if (result != null) {
      return result[0];
    }
    return null;
  }

  Uint8List varIntBytes(BigInt i) {
    // Based on: https://en.bitcoin.it/wiki/Protocol_specification#Variable_length_integer
    if (i < BigInt.from(0xfd)) {
      return i.toBytes;
    } else if (i <= BigInt.from(0xffff)) {
      return Uint8List.fromList([0xfd, ...i.toBytes]);
      // Not sure if this is correct as the python uses `return b"\xfd" + int_to_bytes(i, 2)`, see https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/bitcoin.py#L369
    } else if (i <= BigInt.from(0xffffffff)) {
      return Uint8List.fromList([0xfe, ...i.toBytes]);
    } else {
      return Uint8List.fromList([0xff, ...i.toBytes]);
      // Not sure if this is correct as the python uses `return b"\xff" + int_to_bytes(i, 8)`, see https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/bitcoin.py#L369
    }
  }

  ({Uint8List hashPrevouts, Uint8List hashSequence, Uint8List hashOutputs})
      calcCommonSighash({bool useCache = false}) {
    List<Input> inputs = this.inputs;
    int nOutputs =
        outputs.length; // Assuming there's a 'outputs' getter in your class
    List<int> meta = [inputs.length, nOutputs];

    if (useCache) {
      try {
        List<int> cmeta =
            _cachedSighashTup[0]; // TODO cache sighash tuple (record).
        List<Uint8List> res = _cachedSighashTup[1];
        if (listEquals(cmeta, meta)) {
          return res;
        } else {
          _cachedSighashTup = null;
        }
      } catch (e) {
        // Handle the exception or simply continue
      }
    }

    Uint8List varIntBytes(BigInt i) {
      // Based on: https://en.bitcoin.it/wiki/Protocol_specification#Variable_length_integer
      if (i < BigInt.from(0xfd)) {
        return i.toBytes;
      } else if (i <= BigInt.from(0xffff)) {
        return Uint8List.fromList([0xfd, ...i.toBytes]);
        // Not sure if this is correct as the python uses `return b"\xfd" + int_to_bytes(i, 2)`, see https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/bitcoin.py#L369
      } else if (i <= BigInt.from(0xffffffff)) {
        return Uint8List.fromList([0xfe, ...i.toBytes]);
      } else {
        return Uint8List.fromList([0xff, ...i.toBytes]);
        // Not sure if this is correct as the python uses `return b"\xff" + int_to_bytes(i, 8)`, see https://github.com/Electron-Cash/Electron-Cash/blob/00f7b49076c291c0162b3f591cc30fc6b8da5a23/electroncash/bitcoin.py#L369
      }
    }

    Uint8List hashPrevouts = Uint8List.fromList(crypto.sha256
        .convert(Uint8List.fromList(inputs
            .map((txin) => serializeOutpointBytes(txin))
            .expand((x) => x)
            .toList()))
        .bytes);

    Uint8List hashSequence = Uint8List.fromList(crypto.sha256
        .convert(Uint8List.fromList(inputs
            .map((txin) => txin
                .sequence // TODO BigInt txin.sequence.  Was `intToBytes(txin.sequence ?? 0xffffffff - 1, 4))`.
                .toBytes as Uint8List)
            .expand((x) => x)
            .toList()))
        .bytes);

    Uint8List hashOutputs = Uint8List.fromList(crypto.sha256
        .convert(Uint8List.fromList(
            List.generate(nOutputs, (n) => serializeOutputNBytes(n))
                .expand((x) => x)
                .toList()))
        .bytes);

    _cachedSighashTup = [
      meta,
      [hashPrevouts, hashSequence, hashOutputs]
    ]; // TODO cache sighash tuple (record).
    return (
      hashPrevouts: hashPrevouts,
      hashSequence: hashSequence,
      hashOutputs: hashOutputs
    );
  }

  Uint8List serializeOutputNBytes(int n) {
    throw UnimplementedError();
  }
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bitbox/bitbox.dart' as bitbox;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/pedersen.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;

/// A utility class that provides various helper functions.
abstract class Utilities {
  static void debugPrint(Object? object) {
    if (kDebugPrintEnabled) {
      // ignore: avoid_print
      print(object);
    }
  }

  static PedersenSetup get pedersenSetup => PedersenSetup(
        '\x02CashFusion gives us fungibility.'.toUint8ListFromUtf8,
      );

  static ECDomainParameters get secp256k1Params =>
      ECDomainParameters('secp256k1');

  // ===========================================================================

  static coinlib.NetworkParams get mainNet => coinlib.NetworkParams(
        wifPrefix: 0x80,
        p2pkhPrefix: 0x00,
        p2shPrefix: 0x05,
        privHDPrefix: 0x0488ade4,
        pubHDPrefix: 0x0488b21e,
        bech32Hrp: "bc",
        messagePrefix: "\x18Bitcoin Signed Message:\n",
      );

  static coinlib.NetworkParams get testNet => coinlib.NetworkParams(
        wifPrefix: 0xef,
        p2pkhPrefix: 0x6f,
        p2shPrefix: 0xc4,
        privHDPrefix: 0x04358394,
        pubHDPrefix: 0x043587cf,
        bech32Hrp: "tb",
        messagePrefix: "\x18Bitcoin Signed Message:\n",
      );

  // ===========================================================================

  /// Checks the input for ElectrumX server.
  ///
  /// Parameters:
  /// - [inputComponent] The input component to be checked.
  static void checkInputElectrumX(InputComponent inputComponent) {
    throw UnimplementedError("checkInputElectrumX: TODO implement");
  }

  /// Calculates a random position based on a seed, number of positions, and a counter.
  ///
  /// Parameters:
  /// - [seed] A Uint8List used as a seed.
  /// - [numPositions] The number of positions to consider.
  /// - [counter] The counter value.
  ///
  /// Returns:
  ///   A random position calculated from the seed and counter.
  static int randPosition(Uint8List seed, int numPositions, int counter) {
    // Counter to bytes.
    Uint8List counterBytes = Uint8List(4);
    ByteData counterByteData = ByteData.sublistView(counterBytes);
    counterByteData.setInt32(0, counter, Endian.big);

    // Hash the seed and counter.
    final bytes = Utilities.sha256([...seed, ...counterBytes]);

    // Take the first 8 bytes.
    ByteData byteData = ByteData.sublistView(bytes, 0, 8);
    int int64 = byteData.getUint64(0, Endian.big);

    // Perform the modulo operation.
    return ((int64 * numPositions) >> 64).toInt();
  }

  /// Determines the dust limit based on the length of the transaction.
  ///
  /// See https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash_plugins/fusion/util.py#L70
  ///
  /// Parameters:
  /// - [length] The length of the transaction.
  ///
  /// Returns:
  ///   The calculated dust limit.
  static int dustLimit(int length) {
    return 3 * (length + 148);
    // length represents the size of the transaction in bytes.  148 bytes are
    // added to the length to account for the size of the input script, which is
    // 148 bytes for a compressed input.
  }

  /// Extracts the address from an output script.
  ///
  /// Parameters:
  /// - [scriptPubKey] The output script in Uint8List format.
  ///
  /// Returns:
  ///   The extracted Address.
  static Address getAddressFromOutputScript(
    Uint8List scriptPubKey,
    coinlib.NetworkParams network, [
    bool fusionReserved = false,
  ]) {
    // Throw exception if this is not a standard P2PKH address.
    if (scriptPubKey.length == 25 &&
            scriptPubKey[0] == 0x76 && // OP_DUP
            scriptPubKey[1] == 0xa9 && // OP_HASH160
            scriptPubKey[2] == 0x14 && // 20 bytes to push
            scriptPubKey[23] == 0x88 && // OP_EQUALVERIFY
            scriptPubKey[24] == 0xac // OP_CHECKSIG
        ) {
      // This is a P2PKH script.

      // Extract the public key.
      final pubKeyHash = scriptPubKey.sublist(3, 23);

      final addr = coinlib.P2PKHAddress.fromHash(
        pubKeyHash,
        version: network.p2pkhPrefix,
      );

      return Address(
        address: addr.toString(),
        publicKey: [],
        fusionReserved: fusionReserved,
      );
    } else {
      throw Exception(
          'fusiondart getAddressFromOutputScript: Not a P2PKH script.');
    }
  }

  /// port of https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash/schnorr.py#L87
  static BigInt nonceFunctionRfc6979(
      BigInt order, Uint8List privkeyBytes, Uint8List msg32,
      {Uint8List? algo16, Uint8List? ndata}) {
    assert(privkeyBytes.length == 32);
    assert(msg32.length == 32);
    assert(algo16 == null || algo16.length == 16);
    assert(ndata == null || ndata.length == 32);
    assert(order.bitLength == 256);

    Uint8List V = Uint8List.fromList(List.generate(32, (index) => 0x01));
    Uint8List K = Uint8List.fromList(List.generate(32, (index) => 0x00));

    var blob =
        Uint8List.fromList([...privkeyBytes, ...msg32, ...?ndata, ...?algo16]);

    K = Uint8List.fromList(crypto.Hmac(crypto.sha256, K)
        .convert(Uint8List.fromList([...V, 0x00, ...blob]))
        .bytes);
    V = Uint8List.fromList(crypto.Hmac(crypto.sha256, K).convert(V).bytes);
    K = Uint8List.fromList(crypto.Hmac(crypto.sha256, K)
        .convert(Uint8List.fromList([...V, 0x01, ...blob]))
        .bytes);
    V = Uint8List.fromList(crypto.Hmac(crypto.sha256, K).convert(V).bytes);

    BigInt k;
    while (true) {
      V = Uint8List.fromList(crypto.Hmac(crypto.sha256, K).convert(V).bytes);
      Uint8List T = V;

      assert(T.length == 32);
      k = T.toBigInt;

      if (k > BigInt.zero && k < order) {
        break;
      }

      K = Uint8List.fromList(crypto.Hmac(crypto.sha256, K)
          .convert(Uint8List.fromList([...V, 0x00]))
          .bytes);
      V = Uint8List.fromList(crypto.Hmac(crypto.sha256, K).convert(V).bytes);
    }
    return k;
  }

  /// Signs a [messageHash] using the given [privkey] and an optional [ndata].
  ///
  /// [ndata] is optional but for secure use it should be a random 32-byte value.
  ///
  /// TODO default to generating [ndata] if not provided unless testing.
  static Uint8List schnorrSign(Uint8List privkey, Uint8List messageHash,
      {Uint8List? ndata}) {
    if (ndata != null && ndata.length != 32) {
      throw ArgumentError('ndata must be a bytes object of length 32');
    }

    if (privkey.length != 32) {
      throw ArgumentError('privkey must be a bytes object of length 32');
    }

    if (messageHash.length != 32) {
      throw ArgumentError('messageHash must be a bytes object of length 32');
    }

    final G = Utilities.secp256k1Params.G;
    final order = Utilities.secp256k1Params.n;
    final fieldSize = BigInt.two.pow(256) -
        BigInt.two.pow(32) -
        BigInt.from(977); // This is p for secp256k1.

    BigInt secexp = privkey.toBigInt;
    if (!(secexp > BigInt.zero && secexp < order)) {
      throw ArgumentError('Invalid private key');
    }

    // Calculate secexp * G and convert to ECPoint.
    ECPoint pubPoint = (G * secexp)!;
    Uint8List pubBytes =
        Utilities.pointToSer(pubPoint, true); // true: compressed.

    Uint8List algo16 = Uint8List.fromList('Schnorr+SHA256  '.codeUnits);
    BigInt k = nonceFunctionRfc6979(order, privkey, messageHash,
        ndata: ndata, algo16: algo16);
    ECPoint R = (G * k)!;
    if (jacobi(R.y!.toBigInteger()!, fieldSize) == -BigInt.one) {
      k = order - k;
    }

    Uint8List rBytes = R.x!.toBigInteger()!.toBytesPadded(32);
    Uint8List eBytes =
        Utilities.sha256([...rBytes, ...pubBytes, ...messageHash]);
    BigInt e = eBytes.toBigInt;

    BigInt s = (k + (e * secexp)) % order;

    return Uint8List.fromList([...rBytes, ...s.toBytesPadded(32)]);
  }

  /// Verifies a Schnorr signature.
  ///
  /// Parameters:
  /// - [pubkey] The public key as an ECPoint.
  /// - [signature] The signature as a List<int>.
  /// - [messageHash] The hash of the message as a Uint8List.
  ///
  /// Returns:
  ///   True if the verification succeeds, otherwise false.
  static bool schnorrVerify(
    Uint8List pubKey,
    List<int> signature,
    Uint8List messageHash,
  ) {
    final pubPoint = serToPoint(pubKey, secp256k1Params);

    final curveP = (secp256k1Params.curve as fp.ECCurve).q!;

    final rBytes = Uint8List.fromList(signature.sublist(0, 32));
    final sBytes = Uint8List.fromList(signature.sublist(32, 64));

    if (rBytes.toBigInt >= curveP || sBytes.toBigInt >= secp256k1Params.n) {
      return false;
    }

    final pubBytes = pointToSer(pubPoint, true);

    final e = sha256(
      Uint8List.fromList(
        rBytes + pubBytes + messageHash,
      ),
    ).toBigInt;

    final sG = (secp256k1Params.G * sBytes.toBigInt)!;
    final _eP = (pubPoint * e)!;

    final R = (sG - _eP)!;

    if (R.isInfinity) {
      return false;
    }

    final rX = R.x!.toBigInteger()!;
    final rY = R.y!.toBigInteger()!;

    if (jacobi(rY, curveP) != BigInt.one) {
      return false;
    }

    return rX == rBytes.toBigInt;
  }

  /// Updates the wallet label for a given transaction ID.
  ///
  /// Parameters:
  /// - [txid] The transaction ID.
  /// - [label] The new label for the transaction.
  static void updateWalletLabel(String txid, String label) {
    // TODO implement; call the wallet layer.
    throw UnimplementedError(" // TODO implement updateWalletLabel");
  }

  /// Generates a random sequence of bytes of a given [length].
  ///
  /// Parameters:
  /// - [length] The length of the byte sequence.
  ///
  /// Returns:
  ///   A Uint8List containing the random bytes.
  static Uint8List getRandomBytes(int length, {Random? random}) {
    final rand = random ?? Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = rand.nextInt(0xFF + 1);
    }
    return bytes;
  }

  /// Zips two lists [list1] and [list2] together.
  ///
  /// Parameters:
  /// - [list1] The first `List`.
  /// - [list2] The second `List`.
  ///
  /// Returns:
  ///   A list of lists, each containing one element from each input list.
  static List<List<T>> zip<T>(List<T> list1, List<T> list2) {
    int length = min(list1.length, list2.length);
    return List<List<T>>.generate(length, (i) => [list1[i], list2[i]]);
  }

  /// Calculates the initial hash for the Fusion protocol.
  ///
  /// Parameters:
  /// - [tier] The tier level.
  /// - [covertDomainB] The covert domain in Uint8List format.
  /// - [covertPort] The covert port number.
  /// - [covertSsl] A boolean indicating whether SSL is used.
  /// - [beginTime] The starting time.
  ///
  /// Returns:
  ///   The calculated hash as a List<int>.
  static List<int> calcInitialHash(int tier, Uint8List covertDomainB,
      int covertPort, bool covertSsl, double beginTime) {
    // Converting int to bytes in BigEndian order.
    ByteData tierBytes = ByteData(8)..setInt64(0, tier, Endian.big);
    ByteData covertPortBytes = ByteData(4)..setInt32(0, covertPort, Endian.big);
    ByteData beginTimeBytes = ByteData(8)
      ..setInt64(0, beginTime.toInt(), Endian.big);

    // Define constants.
    const version = Protocol.VERSION;
    const cashFusionSession = "Cash Fusion Session";

    // Creating the list of bytes.
    List<List<int>> elements = [];
    elements.add(utf8.encode(cashFusionSession));
    elements.add(utf8.encode(version));
    elements.add(tierBytes.buffer.asUint8List());
    elements.add(covertDomainB);
    elements.add(covertPortBytes.buffer.asUint8List());
    elements.add(covertSsl ? [1] : [0]);
    elements.add(beginTimeBytes.buffer.asUint8List());

    return _listHash(elements);
  }

  /// Calculates the round hash for the Fusion protocol.
  ///
  /// Parameters:
  /// - [lastHash] The last hash value.
  /// - [roundPubkey] The round public key.
  /// - [roundTime] The round time.
  /// - [allCommitments] All commitments in the round.
  /// - [allComponents] All components in the round.
  ///
  /// Returns:
  ///   The calculated hash as a List<int>.
  static List<int> calcRoundHash(
      List<int> lastHash,
      List<int> roundPubkey,
      int roundTime,
      List<List<int>> allCommitments,
      List<List<int>> allComponents) {
    return _listHash([
      utf8.encode('Cash Fusion Round'),
      lastHash,
      roundPubkey,
      BigInt.from(roundTime).toBytesPadded(8),
      _listHash(allCommitments),
      _listHash(allComponents),
    ]);
  }

  static List<int> _listHash(Iterable<List<int>> iterable) {
    List<int> bytes = <int>[];

    for (List<int> x in iterable) {
      ByteData length = ByteData(4)..setUint32(0, x.length, Endian.big);
      bytes.addAll(length.buffer.asUint8List());
      bytes.addAll(x);
    }
    return Utilities.sha256(bytes);
  }

  static Uint8List getCurrentGenesisHash() {
    // TODO feed in from wallet.
    String genesis =
        "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"; // Bitcoin genesis hash
    List<int> _lastGenesisHash = genesis.toUint8ListFromHex.reversed.toList();
    return Uint8List.fromList(_lastGenesisHash);
  }

  /// Generates an elliptic curve key pair based on the secp256k1 curve.
  ///
  /// This function uses the Elliptic Curve Domain Parameters for secp256k1 to
  /// generate a private and a public key. The keys are returned as Uint8List.
  ///
  /// Returns:
  ///   A tuple containing the private key and the public key as Uint8List.
  static (Uint8List, Uint8List) genKeypair() {
    final private = coinlib.ECPrivateKey.generate();

    // Convert the private and public keys to Uint8List format
    final privKey = private.data;
    final pubKey = private.pubkey.data;

    return (privKey, pubKey);
  }

  /// Returns the sha256 hash of a Uint8List.
  ///
  /// Uses the `crypto` library to perform the sha256 hash operation
  /// on the input [bytes].
  ///
  /// Parameters:
  ///   - [bytes]: The Uint8List to hash.
  ///
  /// Returns:
  ///   A Uint8List containing the sha256 hash of the input [bytes].
  static Uint8List sha256(List<int> bytes) {
    crypto.Digest digest = crypto.sha256.convert(bytes);
    return Uint8List.fromList(digest.bytes);
  }

  static Uint8List doubleSha256(List<int> data) {
    return sha256(sha256(data));
  }

  /// Calculates the component fee based on [size] and [feerate].
  ///
  /// The function calculates the fee required for a component of a given size
  /// when the feerate is known. The feerate should be specified in sat/kB.
  /// Fee is always rounded up due to the addition of 999 sats.
  ///
  /// Returns:
  ///   The calculated fee for the component in satoshis.
  static int componentFee(int size, int feerate) {
    // feerate is provided in sat/kB (satoshi per kilobyte)
    // size is the size of the component in bytes

    // Calculate the fee and round up to the nearest integer value
    return ((size * feerate) + 999) ~/ 1000;
  }

  /// Method to add points together.
  ///
  /// Parameters:
  /// - [pointsIterable]: An iterable of Uint8List objects representing points.
  ///
  /// Returns:
  ///   A Uint8List representing the sum of the points.
  static Uint8List addPoints(
      Iterable<Uint8List> pointsIterable, ECDomainParameters params) {
    // Convert serialized points to ECPoint objects.
    List<ECPoint> pointList = pointsIterable
        .map((pser) => Utilities.serToPoint(pser, params))
        .toList();

    // Check for empty list of points.
    if (pointList.isEmpty) {
      throw ArgumentError('Empty list');
    }

    // Initialize sum of points with the first point in the list.
    ECPoint pSum =
        pointList.first; // Initialize pSum with the first point in the list.

    // Add up all the points in the list.
    for (int i = 1; i < pointList.length; i++) {
      pSum = (pSum + pointList[i])!;
    }

    // Check if sum of points is at infinity.
    if (pSum == params.curve.infinity) {
      throw Exception('Result is at infinity');
    }

    // Convert sum to serialized form and return
    return Utilities.pointToSer(pSum, false);
  }

  /// Converts a serialized elliptic curve point to its `ECPoint` representation.
  ///
  /// Parameters:
  /// - [serializedPoint] The Uint8List that represents the serialized point.
  /// - [params] The domain parameters for the elliptic curve.
  ///
  /// Returns:
  ///   The `ECPoint` object decoded from the serialized point.
  static ECPoint serToPoint(
      Uint8List serializedPoint, ECDomainParameters params) {
    // Decode the point using the curve from parameters
    ECPoint? point = params.curve.decodePoint(serializedPoint);
    if (point == null) {
      throw FormatException('Point decoding failed');
    }
    return point;
  }

  /// Converts an `ECPoint` to its serialized representation.
  ///
  /// Parameters:
  /// - [point] The ECPoint to be serialized.
  /// - [compress] Whether the point should be compressed.
  ///
  /// Returns:
  ///   The serialized point as a `Uint8List`.
  static Uint8List pointToSer(ECPoint point, bool compress) {
    return point.getEncoded(compress);
  }

  /// Generates a random BigInt value, up to [maxValue].
  static BigInt secureRandomBigInt(BigInt maxValue) {
    final random = Random.secure();

    // Calculate the number of bytes needed.
    final byteLength = (maxValue.bitLength + 7) ~/ 8;

    // Loop until we get a value less than maxValue.
    while (true) {
      final bytes = getRandomBytes(byteLength, random: random);
      final result = bytes.toBigInt;

      if (result < maxValue) {
        return result;
      }
    }
  }

  /// port of https://github.com/tlsfuzzer/python-ecdsa/blob/master/src/ecdsa/numbertheory.py#L152
  static BigInt jacobi(BigInt a, BigInt n) {
    if (!n.isOdd) {
      throw Exception("n must odd");
    }

    if (n < BigInt.from(3)) {
      throw Exception("n must be >= 3");
    }

    a = a % n;

    if (a == BigInt.zero) {
      return BigInt.zero;
    }
    if (a == BigInt.one) {
      return BigInt.one;
    }

    BigInt a1 = a;
    BigInt e = BigInt.zero;

    while (a1.isEven) {
      a1 = a1 >> 1;
      e = e + BigInt.one;
    }

    BigInt s;
    if (e.isEven ||
        n % BigInt.from(8) == BigInt.one ||
        n % BigInt.from(8) == BigInt.from(7)) {
      s = BigInt.one;
    } else {
      s = -BigInt.one;
    }

    if (a1 == BigInt.one) {
      return s;
    }

    if (n % BigInt.from(4) == BigInt.from(3) &&
        a1 % BigInt.from(4) == BigInt.from(3)) {
      s = -s;
    }

    return s * jacobi(n % a1, a1);
  }

  // https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/util.py#L51-L62
  static int sizeOfInput(Uint8List pubKey) {
    // # Sizes of inputs after signing:
    // #   32+8+1+1+[length of sig]+1+[length of pubkey]
    // #   == 141 for compressed pubkeys, 173 for uncompressed.
    // # (we use schnorr signatures, always)
    // assert 1 < len(pubkey) < 76  # need to assume regular push opcode
    assert(pubKey.length > 1 && pubKey.length < 76);
    return 108 + pubKey.length;
  }

  // https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/util.py#L51-L62
  static int sizeOfOutput(Uint8List scriptPubKey) {
    // # == 34 for P2PKH, 32 for P2SH
    // assert len(scriptpubkey) < 253  # need to assume 1-byte varint
    assert(scriptPubKey.length < 253);
    return 9 + scriptPubKey.length;
  }

  static Uint8List scriptOf({
    required String address,
    required coinlib.NetworkParams network,
  }) {
    if (bitbox.Address.detectFormat(address) == bitbox.Address.formatCashAddr) {
      address = bitbox.Address.toLegacyAddress(address);
    }

    return coinlib.Address.fromString(
      address,
      network,
    ).program.script.compiled;
  }
}

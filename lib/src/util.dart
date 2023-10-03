import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/pedersen.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:pointycastle/ecc/api.dart';

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

  /// Checks the input for ElectrumX server.
  ///
  /// Parameters:
  /// - [inputComponent] The input component to be checked.
  static void checkInputElectrumX(InputComponent inputComponent) {
    //  Implementation needed here
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
    crypto.Digest digest = crypto.sha256.convert([...seed, ...counterBytes]);

    // Take the first 8 bytes.
    List<int> first8Bytes = digest.bytes.take(8).toList();
    int int64 = ByteData.sublistView(Uint8List.fromList(first8Bytes))
        .getUint64(0, Endian.big);

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
  static Address getAddressFromOutputScript(Uint8List scriptPubKey) {
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
      Uint8List pubKey = scriptPubKey.sublist(3, 23);

      // Use bitcoindart to return the encoded address.
      return Address(
          addr: coinlib.P2PKH
              .fromPublicKey(coinlib.ECPublicKey.fromHex(hex.encode(pubKey)))
              .toString());
    } else {
      throw Exception(
          'fusiondart getAddressFromOutputScript: Not a P2PKH script.');
    }
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
      ECPoint pubKey, List<int> signature, Uint8List messageHash) {
    return bip340.verify(
      hex.encode(pubKey.getEncoded(false)), // false indicates uncompressed.
      hex.encode(messageHash),
      hex.encode(signature),
    );
  }

  /// Formats a given number of satoshis.
  ///
  /// TODO implement.
  ///
  /// Parameters:
  /// - [sats] The number of satoshis to format.
  /// - [numZeros] The number of zeros for formatting (optional).
  ///
  /// Returns:
  ///   The formatted satoshis as a string.
  static String formatSatoshis(sats, {int numZeros = 8}) {
    // To implement
    throw UnimplementedError(" // TODO implement formatSatoshis.");
  }

  /// Updates the wallet label for a given transaction ID.
  ///
  /// TODO implement.
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
  static Uint8List getRandomBytes(int length) {
    final rand = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = rand.nextInt(256);
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
    List<int> elements = [];
    elements.addAll(utf8.encode(cashFusionSession));
    elements.addAll(utf8.encode(version));
    elements.addAll(tierBytes.buffer.asInt8List());
    elements.addAll(covertDomainB);
    elements.addAll(covertPortBytes.buffer.asInt8List());
    elements.add(covertSsl ? 1 : 0);
    elements.addAll(beginTimeBytes.buffer.asInt8List());

    // Hashing the concatenated elements.
    crypto.Digest digest = crypto.sha256.convert(elements);

    return digest.bytes;
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
      BigInt.from(roundTime).toBytes,
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
    return crypto.sha256.convert(bytes).bytes;
  }

  static Uint8List getCurrentGenesisHash() {
    // TODO feed in from wallet.
    String genesis =
        "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"; // Bitcoin genesis hash
    List<int> _lastGenesisHash = genesis.toUint8ListFromHex.reversed.toList();
    return Uint8List.fromList(_lastGenesisHash);
  }

  static bool walletHasTransaction(String txid) {
    // implement later based on wallet.
    return true;
  }

  /// Generates an elliptic curve key pair based on the secp256k1 curve.
  ///
  /// This function uses the Elliptic Curve Domain Parameters for secp256k1 to
  /// generate a private and a public key. The keys are returned as Uint8List.
  ///
  /// Returns:
  ///   A tuple containing the private key and the public key as Uint8List.
  static (Uint8List, Uint8List) genKeypair() {
    // Generate a private key using secure random values and curve's bit length
    final BigInt privKeyBigInt =
        _generatePrivateKey(secp256k1Params.n.bitLength);

    // Calculate the public key point using elliptic curve multiplication
    final ECPoint? pubKeyPoint = secp256k1Params.G * privKeyBigInt;

    // Check for any errors in public key generation
    if (pubKeyPoint == null) {
      throw Exception("Error generating public key.");
    }

    // Convert the private and public keys to Uint8List format
    final privKey = privKeyBigInt.toBytes;
    final pubKey = pubKeyPoint.getEncoded(true);

    return (privKey, pubKey);
  }

  /// Generates a cryptographically secure private key of a given bit length.
  ///
  /// Uses a secure random number generator to create a private key. The bit
  /// length of the generated key is specified by the [bitLength] parameter.
  ///
  /// Note: The cryptographic safety of this function still needs to be verified.
  ///
  /// Parameters:
  ///   - [bitLength]: The bit length of the private key to be generated.
  ///
  /// Returns:
  ///   A BigInt representing the generated private key.
  static BigInt _generatePrivateKey(int bitLength) {
    // TODO verify cryptographic safety

    // Use secure random generator
    final random = Random.secure();

    // Calculate the number of bytes and the remaining bits
    int bytes = bitLength ~/ 8; // floor division
    int remBit = bitLength % 8;

    // Generate a list of random bytes
    List<int> rnd = List<int>.generate(bytes, (_) => random.nextInt(256));

    // Generate the remaining random bits
    int rndBit = random.nextInt(1 << remBit);

    // Add the remaining bits to the random list
    rnd.add(rndBit);

    // Convert the list of random numbers to a hex string and then to a BigInt
    BigInt privateKey = BigInt.parse(
        rnd.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);

    return privateKey;
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
  static Uint8List sha256(Uint8List bytes) {
    crypto.Digest digest = crypto.sha256.convert(bytes);
    return Uint8List.fromList(digest.bytes);
  }

  /// Returns a random Uint8List of length [nbytes].
  ///
  /// Generates a cryptographically secure random sequence of bytes.
  /// Uses `Random.secure()` to generate each byte.
  ///
  /// Optional parameter [nbytes] sets the length of the output list.
  /// Defaults to 32 bytes if not specified.
  ///
  /// Parameters:
  ///  - [nbytes]: The length of the output list.  Defaults to 32 bytes if not specified.
  ///
  /// Returns:
  ///   A Uint8List containing [nbytes] random bytes.
  static Uint8List tokenBytes([int nbytes = 32]) {
    final Random _random = Random.secure();

    return Uint8List.fromList(
        List<int>.generate(nbytes, (i) => _random.nextInt(256)));
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

  /// Generates a secure random big integer with a specified bit length.
  ///
  /// Parameters:
  /// - [bitLength] The bit length of the generated big integer.
  ///
  /// Returns:
  ///   A securely generated random `BigInt`.
  static BigInt secureRandomBigInt(int bitLength) {
    final random = Random.secure();
    final bytes = (bitLength + 7) ~/ 8; // Ceiling division.
    final Uint8List randomBytes = Uint8List(bytes);

    // Populate the byte array with random values.
    for (int i = 0; i < bytes; i++) {
      randomBytes[i] = random.nextInt(256);
    }

    // Convert byte array to BigInt.
    BigInt randomNumber =
        (randomBytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join())
            .toBigIntFromHex;

    return randomNumber;
  }

  /// Generates a random BigInt value, up to [maxValue].
  static BigInt randomBigInt(BigInt maxValue) {
    final random = Random.secure();

    // Calculate the number of bytes needed.
    final byteLength = (maxValue.bitLength + 7) ~/ 8;

    // Loop until we get a value less than maxValue.
    while (true) {
      final bytes = Uint8List(byteLength);
      for (int i = 0; i < byteLength; i++) {
        bytes[i] = random.nextInt(0xFF + 1);
      }
      final result = bytes.toBigInt;

      if (result < maxValue) {
        return result;
      }
    }
  }
}

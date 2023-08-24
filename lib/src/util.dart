import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/models/address.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:pointycastle/ecc/api.dart';

extension HexEncoding on List<int> {
  String toHex() {
    return map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

class Util {
  static void checkInputElectrumX(InputComponent inputComponent) {
    //  Implementation needed here
    //
  }

  static int randPosition(Uint8List seed, int numPositions, int counter) {
    // counter to bytes
    Uint8List counterBytes = Uint8List(4);
    ByteData counterByteData = ByteData.sublistView(counterBytes);
    counterByteData.setInt32(0, counter, Endian.big);

    // hash the seed and counter
    crypto.Digest digest = crypto.sha256.convert([...seed, ...counterBytes]);

    // take the first 8 bytes
    List<int> first8Bytes = digest.bytes.take(8).toList();
    int int64 = ByteData.sublistView(Uint8List.fromList(first8Bytes))
        .getUint64(0, Endian.big);

    // perform the modulo operation
    return ((int64 * numPositions) >> 64).toInt();
  }

  static List<String> pubkeysFromPrivkey(String privkey) {
    // This is a placeholder implementation.
    return ['public_key1_dummy', 'public_key2_dummy'];
  }

  static int dustLimit(int length) {
    // This is a dummy implementation.
    return 500;
  }

  static Address getAddressFromOutputScript(Uint8List scriptpubkey) {
    // Dummy implementation...

    // Throw exception if this is not a standard P2PKH address!

    return Address.fromString('dummy_address');
  }

  static bool schnorrVerify(
      ECPoint pubkey, List<int> signature, Uint8List messageHash) {
    // Implementation needed: actual Schnorr signature verification
    return true;
  }

  static String formatSatoshis(sats, {int numZeros = 8}) {
    // To implement
    return "";
  }

  static void updateWalletLabel(String txid, String label) {
    // Call the wallet layer.
  }

  static Uint8List getRandomBytes(int length) {
    final rand = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = rand.nextInt(256);
    }
    return bytes;
  }

  static List<List<T>> zip<T>(List<T> list1, List<T> list2) {
    int length = min(list1.length, list2.length);
    return List<List<T>>.generate(length, (i) => [list1[i], list2[i]]);
  }

  static List<int> calcInitialHash(int tier, Uint8List covertDomainB,
      int covertPort, bool covertSsl, double beginTime) {
    // Converting int to bytes in BigEndian order
    ByteData tierBytes = ByteData(8)..setInt64(0, tier, Endian.big);
    ByteData covertPortBytes = ByteData(4)..setInt32(0, covertPort, Endian.big);
    ByteData beginTimeBytes = ByteData(8)
      ..setInt64(0, beginTime.toInt(), Endian.big);

    // Define constants
    const version = Protocol.VERSION;
    const cashFusionSession = "Cash Fusion Session";

    // Creating the list of bytes
    List<int> elements = [];
    elements.addAll(utf8.encode(cashFusionSession));
    elements.addAll(utf8.encode(version));
    elements.addAll(tierBytes.buffer.asInt8List());
    elements.addAll(covertDomainB);
    elements.addAll(covertPortBytes.buffer.asInt8List());
    elements.add(covertSsl ? 1 : 0);
    elements.addAll(beginTimeBytes.buffer.asInt8List());

    // Hashing the concatenated elements
    crypto.Digest digest = crypto.sha256.convert(elements);

    return digest.bytes;
  }

  static List<int> calcRoundHash(
      List<int> lastHash,
      List<int> roundPubkey,
      int roundTime,
      List<List<int>> allCommitments,
      List<List<int>> allComponents) {
    return listHash([
      utf8.encode('Cash Fusion Round'),
      lastHash,
      roundPubkey,
      bigIntToBytes(BigInt.from(roundTime)),
      listHash(allCommitments),
      listHash(allComponents),
    ]);
  }

  static List<int> listHash(Iterable<List<int>> iterable) {
    List<int> bytes = <int>[];

    for (List<int> x in iterable) {
      ByteData length = ByteData(4)..setUint32(0, x.length, Endian.big);
      bytes.addAll(length.buffer.asUint8List());
      bytes.addAll(x);
    }
    return crypto.sha256.convert(bytes).bytes;
  }

  static Uint8List get_current_genesis_hash() {
    String GENESIS =
        "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f";
    List<int> _lastGenesisHash = hexToBytes(GENESIS).reversed.toList();
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
    // Initialize the EC domain parameters for secp256k1
    ECDomainParameters params = ECDomainParameters('secp256k1');

    // Generate a private key using secure random values and curve's bit length
    BigInt privKeyBigInt = _generatePrivateKey(params.n.bitLength);

    // Calculate the public key point using elliptic curve multiplication
    ECPoint? pubKeyPoint = params.G * privKeyBigInt;

    // Check for any errors in public key generation
    if (pubKeyPoint == null) {
      throw Exception("Error generating public key.");
    }

    // Convert the private and public keys to Uint8List format
    Uint8List privKey = bigIntToBytes(privKeyBigInt);
    Uint8List pubKey = pubKeyPoint.getEncoded(true);

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

  /// Converts a BigInt to a Uint8List.
  ///
  /// The returned Uint8List is padded to 32 bytes if necessary.
  ///
  /// Returns:
  ///   A Uint8List representing the given BigInt.
  static Uint8List bigIntToBytes(BigInt bigInt) {
    // Convert the BigInt to a hexadecimal string and pad it to 32 bytes
    return Uint8List.fromList(
        bigInt.toRadixString(16).padLeft(32, '0').codeUnits);
  }

  /// Parses a BigInt from a Uint8List.
  ///
  /// The function assumes that the bytes in the Uint8List are in big-endian order.
  ///
  /// Returns:
  ///   A BigInt parsed from the given Uint8List.
  static BigInt parseBigIntFromBytes(Uint8List bytes) {
    // Convert the bytes to a hexadecimal string
    return BigInt.parse(
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
  }

  /// Converts a Uint8List to a hexadecimal string representation.
  ///
  /// Takes a Uint8List [bytes] and converts each byte to its hexadecimal
  /// representation. The resulting hexadecimal values are concatenated
  /// into a single string.
  ///
  /// Parameters:
  ///   - [bytes]: The Uint8List to be converted.
  ///
  /// Returns:
  ///   A String containing the hexadecimal representation of the input [bytes].
  static String bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Converts a hexadecimal string to a Uint8List.
  ///
  /// The function assumes that the input string is a valid hexadecimal string
  /// with an even number of characters.
  ///
  /// Returns:
  ///   A Uint8List containing the bytes represented by the input hex string.
  static Uint8List hexToBytes(String hex) {
    // Initialize the result Uint8List with a length of half the hex string
    Uint8List result = Uint8List(hex.length ~/ 2);

    // Loop through the hex string, two characters at a time
    for (int i = 0; i < hex.length; i += 2) {
      // Parse the next byte from the hex string
      int byte = int.parse(hex.substring(i, i + 2), radix: 16);

      // Place the parsed byte into the result Uint8List
      result[i ~/ 2] = byte;
    }
    return result;
  }

  /// Converts a BigInt to a Uint8List.
  ///
  /// Takes a Uint8List [bytes] and converts it into a BigInt.
  /// The input [bytes] are first converted to a hexadecimal string,
  /// which is then parsed into a BigInt object.
  ///
  /// Parameters:
  ///   - [bytes]: The Uint8List to be converted.
  ///
  /// Returns:
  ///   A BigInt object representing the numerical value of the input [bytes].
  static BigInt bytesToBigInt(Uint8List bytes) {
    String hexString = bytesToHex(bytes);
    return BigInt.parse(hexString, radix: 16);
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
  /// Returns:
  ///   A Uint8List containing [nbytes] random bytes.
  static Uint8List tokenBytes([int nbytes = 32]) {
    final Random _random = Random.secure();

    return Uint8List.fromList(
        List<int>.generate(nbytes, (i) => _random.nextInt(256)));
  }

  /// Calculates the component fee based on size and feerate.
  ///
  /// The function calculates the fee required for a component of a given size
  /// when the feerate is known. The feerate should be specified in sat/kB.
  /// Fee is always rounded up to the nearest integer value.
  ///
  /// Parameters:
  ///   size: The size of the component in bytes.
  ///   feerate: The fee rate in sat/kB.
  ///
  /// Returns:
  ///   The calculated fee for the component in satoshis.
  static int componentFee(int size, int feerate) {
    // feerate is provided in sat/kB (satoshi per kilobyte)
    // size is the size of the component in bytes

    // Calculate the fee and round up to the nearest integer value
    return ((size * feerate) + 999) ~/ 1000;
  }

  static ECPoint serToPoint(
      Uint8List serializedPoint, ECDomainParameters params) {
    ECPoint? point = params.curve.decodePoint(serializedPoint);
    if (point == null) {
      throw FormatException('Point decoding failed');
    }
    return point;
  }

  static Uint8List pointToSer(ECPoint point, bool compress) {
    return point.getEncoded(compress);
  }

  static BigInt secureRandomBigInt(int bitLength) {
    final random = Random.secure();
    final bytes = (bitLength + 7) ~/ 8; // ceil division
    final Uint8List randomBytes = Uint8List(bytes);

    for (int i = 0; i < bytes; i++) {
      randomBytes[i] = random.nextInt(256);
    }

    BigInt randomNumber = BigInt.parse(
        randomBytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);
    return randomNumber;
  }

  static ECPoint combinePubKeys(List<ECPoint> pubKeys) {
    if (pubKeys.isEmpty) throw ArgumentError('pubKeys cannot be empty');

    ECPoint combined = pubKeys.first.curve.infinity!;
    for (ECPoint pubKey in pubKeys) {
      combined = (combined + pubKey)!;
    }

    if (combined.isInfinity) {
      throw Exception('Combined point is at infinity');
    }

    return combined;
  }

  static bool isPointOnCurve(ECPoint point, ECCurve curve) {
    // TODO validate these null assertions
    BigInt? x = point.x!.toBigInteger()!;
    BigInt? y = point.y!.toBigInteger()!;
    BigInt? a = curve.a!.toBigInteger()!;
    BigInt? b = curve.b!.toBigInteger()!;

    // Calculate the left and right sides of the equation
    BigInt? left = y * y;
    BigInt? right = (x * x * x) + (a * x) + b;

    // Check if the point is on the curve
    return left == right;
  }
}

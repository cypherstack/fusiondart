import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bitcoindart/bitcoindart.dart' as btc;
import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:pointycastle/ecc/api.dart';

import 'models/address.dart';

/// A utility class that provides various helper functions.
class Utilities {
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

  /// Generates public keys from a given private key.
  ///
  /// TODO implement.
  ///
  /// Parameters:
  /// - [privkey] A private key in String format.
  ///
  /// Returns:
  ///   A list of public keys.
  static List<String> pubkeysFromPrivkey(String privkey) {
    // This is a placeholder implementation.
    return ['public_key1_dummy', 'public_key2_dummy'];
  }

  /// Determines the dust limit based on the length of the transaction.
  ///
  /// TODO implement.
  ///
  /// Parameters:
  /// - [length] The length of the transaction.
  ///
  /// Returns:
  ///   The calculated dust limit.
  static int dustLimit(int length) {
    // TODO implement; dummy implementation.
    return 500;
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
    //
    // TODO use one of the libraries we already have for this.
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
          addr: btc
              .P2PKH(
                  data: btc.PaymentData(
                    pubkey: pubKey,
                  ),
                  network: bitcoincash)
              .toString());
    } else {
      throw Exception(
          'fusiondart getAddressFromOutputScript: Not a P2PKH script.');
    }
  }

  /// Verifies a Schnorr signature.
  ///
  /// TODO implement.
  ///
  /// Parameters:
  /// - [pubkey] The public key as an ECPoint.
  /// - [signature] The signature as a List<int>.
  /// - [messageHash] The hash of the message as a Uint8List.
  ///
  /// Returns:
  ///   True if the verification succeeds, otherwise false.
  static bool schnorrVerify(
      ECPoint pubkey, List<int> signature, Uint8List messageHash) {
    // TODO implement; dummy implementation.
    return true;
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
    return "";
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

  static Uint8List getCurrentGenesisHash() {
    // TODO feed in from wallet.
    String genesis =
        "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"; // Bitcoin genesis hash
    List<int> _lastGenesisHash = hexToBytes(genesis).reversed.toList();
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

  /// Parses a BigInt from a Uint8List [bytes].
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

  /// Converts a Uint8List [bytes] to a hexadecimal string representation.
  ///
  /// Takes a Uint8List [bytes] and converts each byte to its hexadecimal
  /// representation. The resulting hexadecimal values are concatenated
  /// into a single string.
  ///
  /// Returns:
  ///   A String containing the hexadecimal representation of the input [bytes].
  static String bytesToHex(Uint8List bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Converts a hexadecimal string [hex] to a Uint8List.
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

  /// Converts a BigInt [bytes] to a Uint8List.
  ///
  /// Takes a Uint8List [bytes] and converts it into a BigInt.
  /// The input [bytes] are first converted to a hexadecimal string,
  /// which is then parsed into a BigInt object.
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
  /// Fee is always rounded up to the nearest integer value.
  ///
  /// Returns:
  ///   The calculated fee for the component in satoshis.
  static int componentFee(int size, int feerate) {
    // feerate is provided in sat/kB (satoshi per kilobyte)
    // size is the size of the component in bytes

    // Calculate the fee and round up to the nearest integer value
    return ((size * feerate) + 999) ~/ 1000;
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
    BigInt randomNumber = BigInt.parse(
        randomBytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);
    return randomNumber;
  }

  /// Combines multiple public keys into a single public key.
  ///
  /// Parameters:
  /// - [pubKeys] A list of `ECPoint` representing the public keys to combine.
  ///
  /// Returns:
  ///   The combined public key as an `ECPoint`.
  static ECPoint combinePubKeys(List<ECPoint> pubKeys) {
    if (pubKeys.isEmpty) throw ArgumentError('pubKeys cannot be empty');

    // Initialize with the point at infinity.
    ECPoint combined = pubKeys.first.curve.infinity!;

    // Combine the points.
    for (ECPoint pubKey in pubKeys) {
      combined = (combined + pubKey)!;
    }

    // Validate the combined point.
    if (combined.isInfinity) {
      throw Exception('Combined point is at infinity');
    }

    return combined;
  }

  /// Checks if a given point lies on a specified elliptic curve.
  ///
  /// Parameters:
  /// - [point] The `ECPoint` to be checked.
  /// - [curve] The `ECCurve` representing the elliptic curve.
  ///
  /// Returns:
  ///   `true` if the point is on the curve, `false` otherwise.
  static bool isPointOnCurve(ECPoint point, ECCurve curve) {
    // TODO validate these null assertions
    BigInt? x = point.x!.toBigInteger()!;
    BigInt? y = point.y!.toBigInteger()!;
    BigInt? a = curve.a!.toBigInteger()!;
    BigInt? b = curve.b!.toBigInteger()!;

    // Calculate the left and right sides of the equation.
    BigInt? left = y * y;
    BigInt? right = (x * x * x) + (a * x) + b;

    // Check if the point is on the curve.
    return left == right;
  }
}

/// An extension on the `List<int>` class that adds a `toHex` method.
extension HexEncoding on List<int> {
  String toHex() {
    return map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

// Bitcoincash Network
final bitcoincash = btc.NetworkType(
    messagePrefix: '\x18Bitcoin Signed Message:\n',
    bech32: 'bc',
    bip32: btc.Bip32Type(public: 0x0488b21e, private: 0x0488ade4),
    pubKeyHash: 0x00,
    scriptHash: 0x05,
    wif: 0x80);

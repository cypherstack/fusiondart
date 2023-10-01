import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';

/// A class representing a blind signature request.
///
/// This class is used to create a blind signature request, which is then sent
/// to the server.  The server will respond with a blind signature, which can
/// then be unblinded to get the actual signature.
///
/// The blind signature request is created by generating a random number `a`
/// and calculating `Rnew = R + (G * a) + (pubkey * b)`.  The request is then
/// sent to the server, which will respond with `e` and `enew`.  The actual
/// signature is calculated as `snew = (c * (s + a)) % order`, where `c` is
/// calculated as `c = jacobi(Rnew.y)`.  The final signature is then
/// `sig = (Rxnew, snew)`.
///
/// The `finalize` method is used to unblind the signature.  It takes the
/// signature `sBytes` and calculates `snew = (c * (s + a)) % order`.  It then
/// returns the final signature as a `Uint8List`.
///
/// The `check` parameter to `finalize` is used to verify the signature before
/// returning it.  If `check` is `true` (the default), then the signature is
/// verified before returning it.  If `check` is `false`, then the signature is
/// returned without being verified.
///
/// The `check` parameter should only be set to `false` if the signature has
/// already been verified.  This is useful when the signature is being verified
/// by the server, which is the case when the server is signing a transaction.
///
/// The `check` parameter should be set to `true` when the signature is being
/// verified by the client.  This is the case when the client is signing a
/// transaction.
///
/// Attributes:
/// - [order]: The order of the ECDSA curve.
/// - [fieldsize]: The field size of the ECDSA curve.
/// - [pubkey]: The public key as a Uint8List.
/// - [R]: The R value as a Uint8List.
/// - [messageHash]: The message hash as a Uint8List.
class BlindSignatureRequest {
  // Curve properties.
  final BigInt order; // ECDSA curve order.
  final BigInt fieldsize; // ECDSA curve field size.

  // Other fields needed for blind signature generation.
  late final Uint8List pubkey;
  late final Uint8List R;
  late final Uint8List messageHash;

  // Private variables used in calculations.
  late BigInt a;
  late BigInt b;
  late BigInt c;
  late BigInt e;
  late BigInt eNew;

  // Storage for intermediary and final results.
  late Uint8List pointRxNew;
  late Uint8List pubKeyCompressed;

  /// Constructor: Initializes various fields and performs initial calculations.
  BlindSignatureRequest(
      {required this.pubkey, required this.R, required this.messageHash})
      : order = Utilities.secp256k1Params.n,
        fieldsize = BigInt.from(Utilities.secp256k1Params.curve.fieldSize) {
    // Check argument validity
    if (pubkey.length != 33 || R.length != 33 || messageHash.length != 32) {
      throw ArgumentError('Invalid argument lengths.');
    }

    // Generate random `BigInt`s `a` and `b`.
    a = _randomBigInt(order);
    b = _randomBigInt(order);

    // Perform initial calculations.
    _calcInitial();

    // Calculate `e` and `eNew`.
    final digest =
        crypto.sha256.convert(pointRxNew + pubKeyCompressed + messageHash);
    final eHash = BigInt.parse(digest.toString(), radix: 16);
    e = (c * eHash + b) % order;
    eNew = eHash % order;
  }

  /// Generates a random BigInt value, up to [maxValue]
  ///
  /// TODO move this to the Utilities class
  ///
  /// Parameters:
  /// - [maxValue]: The maximum value for the random BigInt
  ///
  /// Returns:
  /// - A random BigInt value, up to [maxValue]
  BigInt _randomBigInt(BigInt maxValue) {
    final random = Random.secure();

    // Calculate the number of bytes needed
    int byteLength = (maxValue.bitLength + 7) ~/ 8;

    BigInt result;
    do {
      final bytes = List<int>.generate(byteLength, (i) => random.nextInt(256));
      result = Uint8List.fromList(bytes).toBigInt;
    } while (result >= maxValue);

    return result;
  }

  /// Performs initial calculations needed for blind signature generation.
  void _calcInitial() {
    // Convert byte representations to ECPoints
    ECPoint? pointR = Utilities.serToPoint(R, Utilities.secp256k1Params);
    ECPoint? pubPoint = Utilities.serToPoint(pubkey, Utilities.secp256k1Params);

    // Compress public key
    pubKeyCompressed = Utilities.pointToSer(pubPoint, true);

    // Calculate intermediateR
    ECPoint? intermediateR = pointR + (Utilities.secp256k1Params.G * a);

    // Check that intermediateR is not null
    if (intermediateR == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation pointR + (params.G * a).');
    }

    // Calculate pointRnew
    ECPoint? pointRnew = intermediateR + (pubPoint * b);

    // Check that pointRnew is not null
    if (pointRnew == null || pointRnew.x?.toBigInteger() == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation intermediateR + (pubPoint * b).');
    }

    // Convert pointRnew.x to bytes
    pointRxNew = pointRnew.x!.toBigInteger()!.toBytes;

    // Calculate y for the Jacobi symbol c
    BigInt? y = pointRnew.y?.toBigInteger();

    // Check that y is not null
    if (y == null) {
      throw ArgumentError('Y-coordinate of the new R point is null.');
    }

    // Calculate Jacobi symbol c
    c = BigInt.from(jacobi(y, fieldsize));
  }

  /// Jacobi function of [a] and [n].
  ///
  /// TODO use something built in rather than implementing here.
  ///
  /// Parameters:
  /// - [a]: The first BigInt value.
  /// - [n]: The second BigInt value.
  ///
  /// Returns:
  ///   The Jacobi symbol of [a] and [n]
  int jacobi(BigInt a, BigInt n) {
    // Check that n is positive and odd.
    assert(n > BigInt.zero && n.isOdd);

    // Initialize the result variable t to 1.
    BigInt t = BigInt.one;

    // Main loop to process `a` until it becomes zero.
    while (a != BigInt.zero) {
      // Remove all the factors of 2 in `a` and adjust `t` based on `n`.
      while (a.isEven) {
        a = a >> 1; // Divide a by 2.

        // Calculate n mod 8.
        BigInt r = n % BigInt.from(8);

        // If r is 3 or 5, then flip the sign of t.
        if (r == BigInt.from(3) || r == BigInt.from(5)) {
          t = -t;
        }
      }

      // Swap the values of `a` and `n`.
      BigInt temp = a;
      a = n;
      n = temp;

      // Special case: If both a and n give remainder 3 when divided by 4,
      // flip the sign of t.
      if (a % BigInt.from(4) == BigInt.from(3) &&
          n % BigInt.from(4) == BigInt.from(3)) {
        t = -t;
      }

      // Reduce `a` modulo `n`
      a = a % n;
    }

    // If `n` became 1, return the Jacobi symbol as int.
    if (n == BigInt.one) {
      return t.toInt();
    } else {
      // If 'n' is not 1, then return 0 as Jacobi symbol is defined only for n = 1.
      return 0;
    }
  }

  /// Converts a byte array [bytes] to a BigInt.
  ///
  /// TODO move this to the Utilities class.
  ///
  /// Parameters:
  /// - [bytes]: The byte array to convert.
  ///
  /// Returns:
  ///   The BigInt representation of [bytes]
  BigInt bytesToBigInt(Uint8List bytes) {
    // Return the BigInt representation of bytes
    return BigInt.parse(
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);
  }

  /// Returns the request as a Uint8List.
  ///
  /// Returns:
  ///   The request as a Uint8List
  Uint8List get request {
    // Return the request as a Uint8List
    return e.toBytes;
  }

  /// Finalizes the blind signature request.
  ///
  /// The signature is calculated as `snew = (c * (s + a)) % order`, where `c` is
  /// calculated as `c = jacobi(Rnew.y)`.  The final signature is then
  /// `sig = (Rxnew, snew)`.
  ///
  /// The `check` parameter is used to verify the signature before returning it.
  /// If `check` is `true` (the default), then the signature is verified before
  /// returning it.  If `check` is `false`, then the signature is returned
  /// without being verified.
  ///
  /// The `check` parameter should only be set to `false` if the signature has
  /// already been verified.  This is useful when the signature is being
  /// verified by the server, which is the case when the server is signing a
  /// transaction.
  ///
  /// The `check` parameter should be set to `true` when the signature is being
  /// verified by the client.  This is the case when the client is signing a
  /// transaction.
  ///
  /// Parameters:
  /// - [sBytes]: The signature as a Uint8List.
  /// - [check]: Whether or not to verify the signature before returning it.
  ///
  /// Returns:
  ///  The signature as a Uint8List.
  Uint8List finalize(Uint8List sBytes, {bool check = true}) {
    // Check argument validity
    if (sBytes.length != 32) {
      throw ArgumentError('Invalid length for sBytes');
    }

    // Calculate snew.
    BigInt s = bytesToBigInt(sBytes);
    BigInt snew = (c * (s + a)) % order;

    // Calculate the final signature.
    List<int> sig = pointRxNew + snew.toBytes;

    // Verify the signature if requested.
    ECPoint? pubPoint = Utilities.serToPoint(pubkey, Utilities.secp256k1Params);

    // Check that pubPoint is not null.
    if (check && !Utilities.schnorrVerify(pubPoint, sig, messageHash)) {
      throw Exception('Blind signature verification failed.');
    }

    return Uint8List.fromList(sig.toList());
  }
}

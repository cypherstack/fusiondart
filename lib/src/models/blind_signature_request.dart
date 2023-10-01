import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';

/// Schnorr blind signature creator for the requester side.
///
/// This is set up with two elliptic curve points
/// (serialized as bytes) - the Blind signer's public key, and
/// a nonce point whose secret is known by the signer. Also, the
/// 32-byte message_hash should be provided.
///
/// Upon construction, this creates and remembers the blinding factors,
/// and also performs the expensive math needed to create the blind
/// signature request. Once initialized, use `get_request` method to obtain
/// the 32-byte request that should be sent to the signer. After receiving
/// the 32-byte response from the signer, call `finalize`.
///
/// The resultant Schnorr signatures follow the standard BCH Schnorr
/// convention (using Jacobi symbol, pubkey prefixing, and SHA256).
///
/// Internally, two random blinding factors a, b are used. Due to the jacobi
/// property, a signflip factor c = +/- 1 is also included.
///
/// [signer provides: R = k*G]
/// R' = c*(R + a*G + b*P)
/// Choose c = +1 or -1 such that jacobi(R'.y(), fieldsize) = +1
/// e' = Hash(R'.x | ser_compressed(P) | message32)
/// e = c*e' + b mod n
/// [send to signer: e]
/// [signer provides: s = k + e*x]
/// s' = c*(s + a) mod n
///
/// The resulting unblinded signature is: (R'.x, s')
///
/// Reference: [https://blog.cryptographyengineering.com/a-note-on-blind-signature-schemes/]
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

  Uint8List get request {
    // Return the request as a Uint8List
    return e.toBytes;
  }

  /// Generates a random BigInt value, up to [maxValue]
  ///
  /// TODO move this to the Utilities class?
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

  /// Finalizes the blind signature request.
  ///
  /// Expects 32 bytes s value, returns 64 byte finished signature.
  /// If check=True (default) this will perform a verification of the result.
  /// Upon failure it raises RuntimeError. The cause for this error is that
  /// the blind signer has provided an incorrect blinded s value.
  Uint8List finalize(Uint8List sBytes, {bool check = true}) {
    // Check argument validity
    if (sBytes.length != 32) {
      throw ArgumentError('Invalid length for sBytes');
    }

    // Calculate snew.
    BigInt s = sBytes.toBigInt;
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

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
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
  final BigInt _order; // ECDSA curve order.
  final BigInt _fieldSize; // ECDSA curve field size.

  // Other fields needed for blind signature generation.
  final Uint8List pubkey;
  final Uint8List R;
  final Uint8List messageHash;

  // Private variables used in calculations.
  late BigInt _a;
  late BigInt _b;
  late BigInt _c;
  late BigInt _e;

  // written to but never read?
  late BigInt _eNew;

  // Storage for intermediary and final results.
  late Uint8List _pointRxNew;
  late Uint8List _pubKeyCompressed;

  /// Constructor: Initializes various fields and performs initial calculations.
  BlindSignatureRequest({
    required this.pubkey,
    required this.R,
    required this.messageHash,
  })  : _order = Utilities.secp256k1Params.n,
        _fieldSize = BigInt.from(Utilities.secp256k1Params.curve.fieldSize) {
    // Check argument validity
    if (pubkey.length != 33 || R.length != 33 || messageHash.length != 32) {
      throw ArgumentError('Invalid argument lengths.');
    }

    // Generate random `BigInt`s `a` and `b`.
    _a = _randomBigInt(_order);
    _b = _randomBigInt(_order);

    // Perform initial calculations.
    _calcInitial();

    // Calculate `e` and `eNew`.
    final digest =
        crypto.sha256.convert(_pointRxNew + _pubKeyCompressed + messageHash);
    final eHash = digest.toString().toBigIntFromHex;
    _e = (_c * eHash + _b) % _order;
    _eNew = eHash % _order;
  }

  Uint8List get request {
    // Return the request as a Uint8List
    return _e.toBytes;
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

    // Calculate sNew.
    BigInt s = sBytes.toBigInt;
    BigInt sNew = (_c * (s + _a)) % _order;

    // Calculate the final signature.
    List<int> sig = _pointRxNew + sNew.toBytes;

    // Verify the signature if requested.
    ECPoint? pubPoint = Utilities.serToPoint(pubkey, Utilities.secp256k1Params);

    // Check that pubPoint is not null.
    if (check && !Utilities.schnorrVerify(pubPoint, sig, messageHash)) {
      throw Exception('Blind signature verification failed.');
    }

    return Uint8List.fromList(sig.toList());
  }

  // ================== Private functions ======================================

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
    final pointR = Utilities.serToPoint(R, Utilities.secp256k1Params);
    final pubPoint = Utilities.serToPoint(pubkey, Utilities.secp256k1Params);

    // Compress public key
    _pubKeyCompressed = Utilities.pointToSer(pubPoint, true);

    // Calculate intermediateR
    final intermediateR = pointR + (Utilities.secp256k1Params.G * _a);

    // Check that intermediateR is not null
    if (intermediateR == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation pointR + (params.G * a).');
    }

    // Calculate pointRNew
    final pointRNew = intermediateR + (pubPoint * _b);

    // Check that pointRNew is not null
    if (pointRNew == null || pointRNew.x?.toBigInteger() == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation intermediateR + (pubPoint * b).');
    }

    // Convert pointRNew.x to bytes
    _pointRxNew = pointRNew.x!.toBigInteger()!.toBytes;

    // Calculate y for the Jacobi symbol c
    final y = pointRNew.y?.toBigInteger();

    // Check that y is not null
    if (y == null) {
      throw ArgumentError('Y-coordinate of the new R point is null.');
    }

    // Calculate Jacobi symbol c
    _c = _jacobi(y, _fieldSize);
  }

  /// port of https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash/schnorr.py#L61
  BigInt _jacobi(BigInt a, BigInt n) {
    final negOne = BigInt.from(-1);
    final three = BigInt.from(3);
    final seven = BigInt.from(7);

    assert(n >= three);
    assert(n & BigInt.one == BigInt.one);

    a = a % n;
    BigInt s = BigInt.one;

    while (a > BigInt.one) {
      BigInt a1 = a;
      BigInt e = BigInt.zero;

      while (a1 & BigInt.one == BigInt.zero) {
        a1 = a1 >> 1;
        e = e + BigInt.one;
      }

      if (!(e & BigInt.one == BigInt.zero || n & seven == BigInt.one) ||
          n & seven == seven) {
        s = s * negOne;
      }

      if (a1 == BigInt.one) {
        return s;
      }

      if (n & three == three && a1 & three == three) {
        s = s * negOne;
      }

      a = a1;
      n = n % a1;
    }

    if (a == BigInt.zero) {
      return BigInt.zero;
    } else if (a == BigInt.one) {
      return s;
    } else {
      throw Exception("jacobi() Unexpected a value of $a");
    }
  }
}

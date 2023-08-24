import 'dart:math';
import 'dart:typed_data';

import 'package:fusiondart/src/encrypt.dart';
import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

class BlindSignatureRequest {
  final BigInt order; // ECDSA curve order
  final BigInt fieldsize; // ECDSA curve field size
  late final Uint8List pubkey;
  late final Uint8List R;
  late final Uint8List messageHash;
  late BigInt a;
  late BigInt b;
  late BigInt c;
  late BigInt e;
  late BigInt enew;
  late Uint8List Rxnew;
  late Uint8List pubkeyCompressed;

  BlindSignatureRequest(this.pubkey, this.R, this.messageHash)
      : order = ECCurve_secp256r1().n,
        fieldsize = BigInt.from(ECCurve_secp256r1().curve.fieldSize) {
    if (pubkey.length != 33 || R.length != 33 || messageHash.length != 32) {
      throw ArgumentError('Invalid argument lengths.');
    }

    a = _randomBigInt(order);
    b = _randomBigInt(order);

    _calcInitial();

    // calculate e and enew
    var crypto;
    final digest =
        crypto.sha256.convert(Rxnew + pubkeyCompressed + messageHash);
    final eHash = BigInt.parse(digest.toString(), radix: 16);
    e = (c * eHash + b) % order;
    enew = eHash % order;
  }

  BigInt _randomBigInt(BigInt maxValue) {
    // final int maxInt =
    //     9223372036854775807; // maximum int value in Dart (2^63 - 1)
    //
    // if (maxValue > BigInt.from(maxInt)) {
    //   throw ArgumentError('maxValue is too large to fit in an int.');
    //   // TODO implement support for larger BigInt values
    // }

    final random = Random.secure();
    return BigInt.from(
        random.nextInt(maxValue.toInt())); // assuming maxValue < maxInt
  }

  void _calcInitial() {
    ECPoint? Rpoint = Util.serToPoint(R, params);
    ECPoint? pubpoint = Util.serToPoint(pubkey, params);

    pubkeyCompressed = Util.pointToSer(pubpoint, true);

    ECPoint? intermediateR = Rpoint + (params.G * a);
    if (intermediateR == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation Rpoint + (params.G * a).');
    }

    ECPoint? Rnew = intermediateR + (pubpoint * b);
    if (Rnew == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation intermediateR + (pubpoint * b).');
    }

    Rxnew = Util.bigIntToBytes(Rnew.x!.toBigInteger()!); // TODO check for null
    BigInt? y = Rnew.y?.toBigInteger();

    if (y == null) {
      throw ArgumentError('Y-coordinate of the new R point is null.');
    }

    c = BigInt.from(jacobi(y, fieldsize));
  }

  // TODO use something built in rather than implementing here
  int jacobi(BigInt a, BigInt n) {
    assert(n > BigInt.zero && n.isOdd);

    BigInt t = BigInt.one;
    while (a != BigInt.zero) {
      while (a.isEven) {
        a = a >> 1;
        BigInt r = n % BigInt.from(8);
        if (r == BigInt.from(3) || r == BigInt.from(5)) {
          t = -t;
        }
      }

      BigInt temp = a;
      a = n;
      n = temp;

      if (a % BigInt.from(4) == BigInt.from(3) &&
          n % BigInt.from(4) == BigInt.from(3)) {
        t = -t;
      }
      a = a % n;
    }

    if (n == BigInt.one) {
      return t.toInt();
    } else {
      return 0;
    }
  }

  BigInt bytesToBigInt(Uint8List bytes) {
    return BigInt.parse(
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);
  }

  Uint8List get request {
    return Util.bigIntToBytes(e);
  }

  Uint8List finalize(Uint8List sBytes, {bool check = true}) {
    if (sBytes.length != 32) {
      throw ArgumentError('Invalid length for sBytes');
    }

    BigInt s = bytesToBigInt(sBytes);
    BigInt snew = (c * (s + a)) % order;

    List<int> sig = Rxnew + Util.bigIntToBytes(snew);

    ECPoint? pubPoint = Util.serToPoint(pubkey, params);

    if (check && !Util.schnorrVerify(pubPoint, sig, messageHash)) {
      throw Exception('Blind signature verification failed.');
    }

    return Uint8List.fromList(sig.toList());
  }
}

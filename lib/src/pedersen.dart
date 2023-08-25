import 'dart:typed_data';

import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';

/// Fetches the default parameters for the secp256k1 curve
///
/// Returns:
///   An ECDomainParameters object representing the secp256k1 curve
ECDomainParameters getDefaultParams() {
  return ECDomainParameters("secp256k1");
}

// Custom exception classes to provide detailed error information.
class NullPointError implements Exception {
  /// Returns a string representation of the error.
  String errMsg() => 'NullPointError: Either Hpoint or HGpoint is null.';
}

/// Represents an error when the nonce value is not within a valid range.
class NonceRangeError implements Exception {
  /// The error message String.
  final String message;

  /// Creates a new [NonceRangeError] with an optional error [message].
  NonceRangeError(
      [this.message = "Nonce value must be in the range 0 < nonce < order"]);

  /// Returns a string representation of the error.
  @override
  String toString() => "NonceRangeError: $message";
}

/// Represents an error when the result is at infinity.
class ResultAtInfinity implements Exception {
  /// The error message String.
  final String message;

  /// Creates a new [ResultAtInfinity] with an optional error [message].
  ResultAtInfinity([this.message = "Result is at infinity"]);

  /// Returns a string representation of the error.
  @override
  String toString() => "ResultAtInfinity: $message";
}

/// Represents an error when the H point has a known discrete logarithm.
class InsecureHPoint implements Exception {
  /// The error message String.
  final String message;

  /// Creates a new [InsecureHPoint] with an optional error [message].
  InsecureHPoint(
      [this.message =
          "The H point has a known discrete logarithm, which means the commitment setup is broken"]);

  /// Returns a string representation of the error.
  @override
  String toString() => "InsecureHPoint: $message";
}

/// Class responsible for setting up a Pedersen commitment.
class PedersenSetup {
  late final ECPoint _pointH;
  late ECPoint _pointHG;
  late ECDomainParameters _params;

  /// Get the EC parameters for the setup.
  ECDomainParameters get params => _params;

  /// Constructor initializes the Pedersen setup with a given H point.
  ///
  /// Parameters:
  /// - [_H]: An EC point to initialize the Pedersen setup.
  PedersenSetup(this._pointH) {
    _params = ECDomainParameters("secp256k1");
    // validate H point
    if (!Util.isPointOnCurve(_pointH, _params.curve)) {
      throw Exception('H is not a valid point on the curve');
    }
    _pointHG = Util.combinePubKeys([_pointH, _params.G]);
  }

  // Getter methods to fetch _H and _HG points as Uint8Lists.
  Uint8List get pointH => _pointH.getEncoded(false);
  Uint8List get pointHG => _pointHG.getEncoded(false);

  /// Create a new commitment.
  ///
  /// Parameters:
  /// - [amount]: The amount to be committed.
  /// - [nonce]: Optional. A BigInt representing the nonce.
  /// - [PUncompressed]: Optional. The uncompressed representation of point P.
  ///
  /// Returns:
  ///   A new `Commitment` object.
  Commitment commit(BigInt amount,
      {BigInt? nonce, Uint8List? pointPUncompressed}) {
    return Commitment(this, amount,
        nonce: nonce, pointPUncompressed: pointPUncompressed);
  }
}

/// Class to encapsulate the Pedersen commitment
///
/// Parameters:
/// - [setup]: The Pedersen setup object.
/// - [amountMod]: The amount to be committed.
/// - [nonce]: A BigInt representing the nonce.
/// - [pointPUncompressed]: The uncompressed representation of point P.
///
class Commitment {
  // Private instance variables
  late PedersenSetup setup; // Added setup property to Commitment class
  late BigInt amountMod;
  late BigInt nonce;
  late Uint8List pointPUncompressed;

  /// Constructor for Commitment
  Commitment(this.setup, BigInt amount,
      {BigInt? nonce, Uint8List? pointPUncompressed}) {
    this.nonce = nonce ?? Util.secureRandomBigInt(setup.params.n.bitLength);
    amountMod = amount % setup.params.n;

    if (this.nonce <= BigInt.zero || this.nonce >= setup.params.n) {
      throw NonceRangeError();
    }

    ECPoint? pointH = setup._pointH;
    ECPoint? pointHG = setup._pointHG;

    if (pointH == null || pointHG == null) {
      throw NullPointError();
    }

    BigInt multiplier1 = (amountMod - this.nonce) % setup.params.n;
    BigInt multiplier2 = this.nonce;

    ECPoint? HpointMultiplied = pointH * multiplier1;
    ECPoint? HGpointMultiplied = pointHG * multiplier2;

    ECPoint? Ppoint = HpointMultiplied != null && HGpointMultiplied != null
        ? HpointMultiplied + HGpointMultiplied
        : null;

    if (Ppoint == setup.params.curve.infinity) {
      throw ResultAtInfinity();
    }

    this.pointPUncompressed =
        pointPUncompressed ?? Ppoint?.getEncoded(false) ?? Uint8List(0);
  }

  void calcInitial(PedersenSetup setup, BigInt amount) {
    amountMod = amount % setup.params.n;
    nonce = Util.secureRandomBigInt(setup.params.n.bitLength);

    ECPoint? Hpoint = setup._pointH;
    ECPoint? HGpoint = setup._pointHG;

    if (nonce <= BigInt.zero || nonce >= setup.params.n) {
      throw NonceRangeError();
    }

    if (Hpoint == null || HGpoint == null) {
      throw NullPointError();
    }

    BigInt multiplier1 = amountMod;
    BigInt multiplier2 = nonce;

    ECPoint? HpointMultiplied = Hpoint * multiplier1;
    ECPoint? HGpointMultiplied = HGpoint * multiplier2;

    ECPoint? Ppoint = HpointMultiplied != null && HGpointMultiplied != null
        ? HpointMultiplied + HGpointMultiplied
        : null;

    if (Ppoint == setup.params.curve.infinity) {
      throw ResultAtInfinity();
    }

    pointPUncompressed = Ppoint?.getEncoded(false) ?? Uint8List(0);
  }

  static Uint8List add_points(Iterable<Uint8List> pointsIterable) {
    ECDomainParameters params =
        getDefaultParams(); // Using helper function here
    List<ECPoint> pointList =
        pointsIterable.map((pser) => Util.serToPoint(pser, params)).toList();

    if (pointList.isEmpty) {
      throw ArgumentError('Empty list');
    }

    ECPoint pSum =
        pointList.first; // Initialize pSum with the first point in the list

    for (int i = 1; i < pointList.length; i++) {
      pSum = (pSum + pointList[i])!;
    }

    if (pSum == params.curve.infinity) {
      throw Exception('Result is at infinity');
    }

    return Util.pointToSer(pSum, false);
  }

  Commitment addCommitments(Iterable<Commitment> commitmentIterable) {
    BigInt ktotal = BigInt.zero; // Changed to BigInt from int
    BigInt atotal = BigInt.zero; // Changed to BigInt from int
    List<Uint8List> points = [];
    List<PedersenSetup> setups = []; // Changed Setup to PedersenSetup
    for (Commitment c in commitmentIterable) {
      ktotal += c.nonce;
      atotal += c.amountMod; // Changed from amount to amountMod
      points.add(c.pointPUncompressed);
      setups.add(c.setup);
    }

    if (points.isEmpty) {
      throw ArgumentError('Empty list');
    }

    PedersenSetup setup = setups[0]; // Changed Setup to PedersenSetup
    if (!setups.every((s) => s == setup)) {
      throw ArgumentError('Mismatched setups');
    }

    ktotal = ktotal % setup.params.n; // Changed order to setup.params.n

    if (ktotal == BigInt.zero) {
      // Changed comparison from 0 to BigInt.zero
      throw Exception('Nonce range error');
    }

    Uint8List? PUncompressed;
    if (points.length < 512) {
      try {
        PUncompressed = add_points(points);
      } on Exception {
        PUncompressed = null;
      }
    } else {
      PUncompressed = null;
    }
    return Commitment(setup, atotal,
        nonce: ktotal, pointPUncompressed: PUncompressed);
  }
}

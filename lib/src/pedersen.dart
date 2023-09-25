import 'dart:typed_data';

import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';

/// Fetches the default parameters for the secp256k1 curve.
///
/// Returns:
///   An ECDomainParameters object representing the secp256k1 curve.
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
    if (!Utilities.isPointOnCurve(_pointH, _params.curve)) {
      throw Exception('H is not a valid point on the curve');
    }
    _pointHG = Utilities.combinePubKeys([_pointH, _params.G]);
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

/// Class to encapsulate the Pedersen commitment.
///
/// Parameters:
/// - [setup]: The Pedersen setup object.
/// - [amountMod]: The amount to be committed.
/// - [nonce]: A BigInt representing the nonce.
/// - [pointPUncompressed]: The uncompressed representation of point P.
class Commitment {
  // Private instance variables
  late PedersenSetup setup; // Added setup property to Commitment class
  late BigInt amountMod;
  late BigInt nonce;
  late Uint8List pointPUncompressed;

  /// Constructor for Commitment.
  ///
  /// Parameters:
  /// - [setup]: The Pedersen setup object.
  /// - [amount]: The amount to be committed.
  /// - [nonce] (optional). A BigInt representing the nonce.
  /// - [pointPUncompressed] (optional). The uncompressed representation of point P.
  Commitment(this.setup, BigInt amount,
      {BigInt? nonce, Uint8List? pointPUncompressed}) {
    // Initialize nonce with a secure random value if not provided.
    this.nonce =
        nonce ?? Utilities.secureRandomBigInt(setup.params.n.bitLength);

    // Take the modulus of the amount to ensure it fits within the group order.
    amountMod = amount % setup.params.n;

    // Check if nonce is within acceptable range.
    if (this.nonce <= BigInt.zero || this.nonce >= setup.params.n) {
      throw NonceRangeError();
    }

    // Retrieve curve points H and HG.
    ECPoint? pointH = setup._pointH;
    ECPoint? pointHG = setup._pointHG;

    // Ensure points H and HG are not null.
    if (pointH == null || pointHG == null) {
      throw NullPointError();
    }

    // Compute multipliers for points H and HG.
    BigInt multiplier1 = (amountMod - this.nonce) % setup.params.n;
    BigInt multiplier2 = this.nonce;

    // Multiply curve points by multipliers.
    ECPoint? pointHMultiplied = pointH * multiplier1;
    ECPoint? pointHGMultiplied = pointHG * multiplier2;

    // Add the multiplied points to get the commitment point P.
    ECPoint? pointP = pointHMultiplied != null && pointHGMultiplied != null
        ? pointHMultiplied + pointHGMultiplied
        : null;

    // Check if point P ends up at infinity, which shouldn't happen.
    if (pointP == setup.params.curve.infinity) {
      throw ResultAtInfinity();
    }

    // Set pointPUncompressed to the uncompressed encoding of point P.
    this.pointPUncompressed =
        pointPUncompressed ?? pointP?.getEncoded(false) ?? Uint8List(0);

    // Do initial calculation of point P and nonce.
    calcInitial(setup, amount);
  }

  /// Calculate the initial point and nonce for a given setup and amount.
  ///
  /// Parameters:
  /// - [setup]: The Pedersen setup object.
  /// - [amount]: The amount to be committed.
  ///
  /// Returns:
  ///   void
  void calcInitial(PedersenSetup setup, BigInt amount) {
    // Initialize nonce with a secure random number if not provided as an argument.
    nonce = Utilities.secureRandomBigInt(setup.params.n.bitLength);

    // Take amount modulo n to ensure it fits within the group order.
    amountMod = amount % setup.params.n;

    // Validate that nonce is within the allowed range (0, n).
    if (nonce <= BigInt.zero || nonce >= setup.params.n) {
      throw NonceRangeError();
    }

    // Retrieve the curve points H and HG from the Pedersen setup.
    ECPoint? pointH = setup._pointH;
    ECPoint? pointHG = setup._pointHG;

    // Ensure neither point is null.
    if (pointH == null || pointHG == null) {
      throw NullPointError();
    }

    // Calculate multipliers for both H and HG.
    BigInt k = nonce;
    BigInt a = amountMod;

    // Multiply the curve points H and HG by their respective multipliers.
    ECPoint? pointHMultiplied =
        pointH * ((a - k) % setup.params.n); // setup.params.n is order.
    ECPoint? pointHGMultiplied = pointHG * k;

    // Sum the two multiplied points to get the final point P.
    ECPoint? Ppoint = pointHMultiplied != null && pointHGMultiplied != null
        ? pointHMultiplied + pointHGMultiplied
        : null;

    // Check if the resulting point P is at infinity, which should not occur.
    if (Ppoint == setup.params.curve.infinity) {
      throw ResultAtInfinity();
    }

    // Store the uncompressed form of the point P, either provided or newly calculated.
    pointPUncompressed = Ppoint?.getEncoded(false) ?? Uint8List(0);
  }

  /// Method to add points together.
  ///
  /// Parameters:
  /// - [pointsIterable]: An iterable of Uint8List objects representing points.
  ///
  /// Returns:
  ///   A Uint8List representing the sum of the points.
  static Uint8List addPoints(Iterable<Uint8List> pointsIterable) {
    // Get default elliptic curve parameters.
    ECDomainParameters params =
        getDefaultParams(); // Using helper function here.

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

  /// Add multiple Commitments together.
  ///
  /// Parameters:
  /// - [commitmentIterable]: An iterable of Commitment objects.
  ///
  /// Returns:
  ///   A new Commitment object.
  Commitment addCommitments(Iterable<Commitment> commitmentIterable) {
    BigInt ktotal = BigInt.zero; // Changed to `BigInt` from `int`.
    BigInt atotal = BigInt.zero; // Changed to `BigInt` from `int`.
    List<Uint8List> points = [];
    List<PedersenSetup> setups = []; // Changed Setup to PedersenSetup.

    // Loop through each commitment to sum up nonces and amounts.
    for (Commitment c in commitmentIterable) {
      ktotal += c.nonce;
      atotal += c.amountMod; // Changed from amount to amountMod.
      points.add(c.pointPUncompressed);
      setups.add(c.setup);
    }

    // Check for empty list of points.
    if (points.isEmpty) {
      throw ArgumentError('Empty list');
    }

    // Check if all setups are the same.
    PedersenSetup setup = setups[0]; // Changed Setup to PedersenSetup
    if (!setups.every((s) => s == setup)) {
      throw ArgumentError('Mismatched setups');
    }

    // Compute sum of nonces modulo group order.
    ktotal = ktotal % setup.params.n; // Changed order to setup.params.n

    // Check if summed nonce is zero.
    if (ktotal == BigInt.zero) {
      // Changed comparison from 0 to `BigInt.zero`.
      throw Exception('Nonce range error');
    }

    // Compute the sum of points if possible, else set to `null`.
    Uint8List? pointPUncompressed;
    if (points.length < 512) {
      try {
        pointPUncompressed = addPoints(points);
      } on Exception {
        pointPUncompressed = null;
      }
    } else {
      pointPUncompressed = null;
    }

    // Return new Commitment object with summed values.
    return Commitment(setup, atotal,
        nonce: ktotal, pointPUncompressed: pointPUncompressed);
  }
}

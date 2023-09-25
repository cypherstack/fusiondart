import 'dart:typed_data';

import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';

///
/// File private default parameters for the secp256k1 curve.
///
final ECDomainParameters _secp256k1ECDomainParameters =
    ECDomainParameters("secp256k1");

/// Class responsible for setting up a Pedersen commitment.
class PedersenSetup {
  final ECPoint _pointH;
  late final ECPoint _pointHG;

  /// Constructor initializes the Pedersen setup with a given H point.
  ///
  /// Parameters:
  /// - [_H]: An EC point to initialize the Pedersen setup.
  PedersenSetup(this._pointH) {
    // Validate H point.
    if (!Utilities.isPointOnCurve(
        _pointH, _secp256k1ECDomainParameters.curve)) {
      throw Exception('H is not a valid point on the curve');
    }

    _pointHG = Utilities.combinePubKeys(
      [
        _pointH,
        _secp256k1ECDomainParameters.G,
      ],
    );

    if (!Utilities.isPointOnCurve(
        _pointHG, _secp256k1ECDomainParameters.curve)) {
      throw Exception('HG is not a valid point on the curve');
    }
    if (_pointHG == _secp256k1ECDomainParameters.curve.infinity) {
      // This happens if H = -G.
      throw Exception('HG is at infinity');
    }
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
  Commitment commit(
    BigInt amount, {
    BigInt? nonce,
    Uint8List? pointPUncompressed,
  }) {
    return Commitment(
      this,
      amount,
      nonce: nonce,
      pointPUncompressed: pointPUncompressed,
    );
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
  final PedersenSetup setup; // Added setup property to Commitment class

  late final BigInt nonce;

  Uint8List get pointPUncompressed => _pointPUncompressed;

  late final BigInt _amountMod;
  late final Uint8List _pointPUncompressed;

  /// Constructor for Commitment.
  ///
  /// Parameters:
  /// - [setup]: The Pedersen setup object.
  /// - [amount]: The amount to be committed.
  /// - [nonce] (optional). A BigInt representing the nonce.
  /// - [pointPUncompressed] (optional). The uncompressed representation of point P.
  Commitment(
    this.setup,
    BigInt amount, {
    BigInt? nonce,
    Uint8List? pointPUncompressed,
  }) {
    // Initialize nonce with a secure random value if not provided.
    this.nonce = nonce ??
        Utilities.secureRandomBigInt(_secp256k1ECDomainParameters.n.bitLength);

    // Validate that nonce is within the allowed range (0, n).
    if (this.nonce <= BigInt.zero ||
        this.nonce >= _secp256k1ECDomainParameters.n) {
      throw NonceRangeError();
    }

    // Take the modulus of the amount to ensure it fits within the group order.
    _amountMod =
        amount % _secp256k1ECDomainParameters.n; // setup.params.n is order.

    // Retrieve curve points H and HG.
    final pointH = setup._pointH;
    final pointHG = setup._pointHG;

    // Compute multipliers for points H and HG.
    BigInt a = _amountMod;
    BigInt k = this.nonce;

    // Multiply curve points by multipliers.
    ECPoint? pointHMultiplied =
        pointH * ((a - k) % _secp256k1ECDomainParameters.n);
    ECPoint? pointHGMultiplied = pointHG * k;

    // Add the multiplied points to get the commitment point P.
    ECPoint? pointP = pointHMultiplied != null && pointHGMultiplied != null
        ? pointHMultiplied + pointHGMultiplied
        : null;

    // Check if point P ends up at infinity, which shouldn't happen.
    if (pointP == _secp256k1ECDomainParameters.curve.infinity) {
      throw ResultAtInfinity();
    }

    // Do initial calculation of point P and nonce.
    _calcInitial(setup, amount);
  }

  /// Calculate the initial point and nonce for a given setup and amount.
  ///
  /// Parameters:
  /// - [setup]: The Pedersen setup object.
  /// - [amount]: The amount to be committed.
  ///
  /// Returns:
  ///   void
  void _calcInitial(PedersenSetup setup, BigInt amount) {
    // Retrieve the curve points H and HG from the Pedersen setup.
    final ECPoint pointH = setup._pointH;
    final ECPoint pointHG = setup._pointHG;

    // Legwork towards calculating the point P.
    BigInt k = nonce;
    BigInt a = _amountMod;
    ECPoint? pointHMultiplied = pointH *
        ((a - k) % _secp256k1ECDomainParameters.n); // setup.params.n is order.
    ECPoint? pointHGMultiplied = pointHG * k;

    if (pointHMultiplied == null || pointHGMultiplied == null) {
      throw NullPointError();
    }

    // Sum the two multiplied points to get the final point P.
    ECPoint pointP = ((pointHMultiplied) + (pointHGMultiplied))!;

    // Check if the resulting point P is at infinity, which should not occur.
    if (pointP == _secp256k1ECDomainParameters.curve.infinity) {
      throw ResultAtInfinity();
    }

    // Store the uncompressed form of the point P, either provided or newly calculated.
    _pointPUncompressed = pointP.getEncoded(false);
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
      atotal += c._amountMod; // Changed from amount to amountMod.
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
    ktotal = ktotal %
        _secp256k1ECDomainParameters.n; // Changed order to setup.params.n

    // Check if summed nonce is zero.
    if (ktotal == BigInt.zero) {
      // Changed comparison from 0 to `BigInt.zero`.
      throw Exception('Nonce range error');
    }

    // Compute the sum of points if possible, else set to `null`.
    Uint8List? pointPUncompressed;
    if (points.length < 512) {
      try {
        pointPUncompressed = Utilities.addPoints(
          points,
          _secp256k1ECDomainParameters,
        );
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

// ======================== Custom Exceptions ==================================

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

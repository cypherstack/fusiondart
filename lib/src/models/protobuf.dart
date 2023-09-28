/// Nongenerated protobuf helpers/wrappers

import 'dart:typed_data';

import 'package:fusiondart/src/protobuf/fusion.pb.dart';

/// Helper class to wrap the protobuf ComponentResult.
///
/// Attributes:
/// - [commitment]: The commitment as a Uint8List.
/// - [counter]: An integer counter.
/// - [component]: The component as a Uint8List.
/// - [proof]: The proof object.
/// - [privateKey]: The private key as a Uint8List.
/// - [pedersenAmount] (optional): The Pedersen commitment amount.
/// - [pedersenNonce] (optional): The Pedersen commitment nonce.
class ComponentResult {
  final Uint8List commitment; // Commitment for this component.
  final int counter; // Counter for this component.
  final Uint8List component; // Actual component as Uint8List.
  final Proof proof; // Proof for this component.
  final Uint8List privateKey; // Private key for this component.

  /// Constructor for the ComponentResult class.
  ComponentResult(
    this.commitment,
    this.counter,
    this.component,
    this.proof,
    this.privateKey,
  );
}

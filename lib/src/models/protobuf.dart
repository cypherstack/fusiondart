/// Nongenerated protobuf helpers/wrappers

import 'dart:typed_data';

import 'package:fusiondart/src/fusion.pb.dart';

/// Helper class to wrap the protobuf ComponentResult
class ComponentResult {
  final Uint8List commitment;
  final int counter;
  final Uint8List component;
  final Proof proof;
  final Uint8List privateKey;
  // TODO type
  final dynamic pedersenAmount;
  final dynamic pedersenNonce;

  /// Constructor for ComponentResult
  ComponentResult(this.commitment, this.counter, this.component, this.proof,
      this.privateKey,
      {this.pedersenAmount, this.pedersenNonce});
}

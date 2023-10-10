import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:fusiondart/src/models/address.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';

/// Output component class
///
/// Based on the protobuf definition of an OutputComponent.
///
/// Attributes:
/// - [value]: The value of the output in satoshis as an int.
/// - [addr]: The `Address` object representing the destination address.
class Output {
  /// Value of the output in satoshis.
  int value;

  /// Destination address.
  String address;

  /// Constructor for the Output class.
  ///
  /// Parameters:
  /// - [value] (required): The value of the output in satoshis as an int.
  /// - [address] (required): The destination address.
  Output({required this.value, required this.address});

  /// Factory method to create an Output object from an `OutputComponent`.
  ///
  /// Parameters:
  /// - [outputComponent]: The `OutputComponent` object to convert.
  ///
  /// Returns:
  ///   An `Output` object.
  static Output fromOutputComponent(
    OutputComponent outputComponent,
    coinlib.NetworkParams network,
  ) {
    // Convert the scriptpubkey to an Address object.
    Address address =
        Address.fromScriptPubKey(outputComponent.scriptpubkey, network);

    return Output(
      value: outputComponent.amount.toInt(),
      address: address.address,
    );
  }
}

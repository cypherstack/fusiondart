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
  Address addr;

  /// Constructor for the Output class.
  ///
  /// Parameters:
  /// - [value] (required): The value of the output in satoshis as an int.
  /// - [addr] (required): The destination address.
  Output({required this.value, required this.addr});

  /// Calculates the size of the output in bytes.
  ///
  /// Returns:
  ///   The size of the output in bytes.
  int sizeOfOutput() {
    // Assuming addr.toScript() returns a List<int> representing the scriptpubkey.
    List<int> scriptpubkey = addr.toScript();

    // Ensure the scriptpubkey length is less than 253 bytes.  253 is the max
    // length of a push opcode (see https://en.bitcoin.it/wiki/Script).
    assert(scriptpubkey.length < 253);

    // Return the size of the output.  9 bytes for the value and scriptpubkey
    // length, plus the length of the scriptpubkey.
    return 9 + scriptpubkey.length;
  }

  /// Factory method to create an Output object from an `OutputComponent`.
  ///
  /// Parameters:
  /// - [outputComponent]: The `OutputComponent` object to convert.
  ///
  /// Returns:
  ///   An `Output` object.
  static Output fromOutputComponent(OutputComponent outputComponent) {
    // Convert the scriptpubkey to an Address object.
    Address address = Address.fromScriptPubKey(outputComponent.scriptpubkey);

    return Output(
      value: outputComponent.amount.toInt(),
      addr: address,
    );
  }
}

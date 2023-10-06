import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/models/input.dart';
import 'package:fusiondart/src/models/output.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';

/// Class that represents a transaction.
///
/// A transaction consists of Inputs and Outputs.
class Transaction {
  List<Input> inputs = [];
  List<Output> outputs = [];

  /// Default constructor for the Transaction class.
  Transaction();

  /// Factory method to create a Transaction from components and a session hash.
  ///
  /// Parameters:
  /// - [allComponents]: The components for the transaction.
  /// - [sessionHash]: The session hash for the transaction.
  ///
  /// Returns:
  ///   A tuple containing the Transaction and a list of input indices.
  static (Transaction, List<int>) txFromComponents(
    List<List<int>> allComponents,
    List<int> sessionHash,
  ) {
    // Initialize a new Transaction.
    Transaction tx = Transaction();

    final List<int> inputIndices = [];
    final comps =
        allComponents.map((e) => Component()..mergeFromBuffer(e)).toList();

    for (int i = 0; i < comps.length; i++) {
      final comp = comps[i];
      if (comp.hasInput()) {
        final inp = comp.input;
        if (inp.prevTxid.length != 32) {
          throw FusionError("bad component prevout");
        }

        final input = Input.fromInputComponent(inp);
        tx.inputs.add(input);
        inputIndices.add(i);
      } else if (comp.hasOutput()) {
        final output = Output.fromOutputComponent(comp.output);
        tx.outputs.add(output);
      } else if (!comp.hasBlank()) {
        throw FusionError("bad component");
      }
    }

    return (tx, inputIndices);
  }

  /// Serializes the preimage of the transaction.
  ///
  /// TODO implement.
  ///
  /// Parameters:
  /// - [index]: The index of the input.
  /// - [hashType]: The type of hash.
  /// - [useCache] (optional): Whether to use cached data.
  ///
  /// Returns:
  ///   A list of integers representing the serialized preimage.
  List<int> serializePreimage(int index, int hashType, {bool useCache = true}) {
    // Returning an empty byte array placeholder for now
    return [];
  }

  /// Serializes the transaction.
  ///
  /// TODO implement.
  ///
  /// Returns:
  ///   A string representing the serialized transaction.
  String serialize() {
    // Placeholder for now.
    return "";
  }

  /// Checks if the transaction is complete.
  ///
  /// TODO implement.
  ///
  /// Returns:
  ///   A boolean value indicating if the transaction is complete.
  bool isComplete() {
    // Placeholder for now.
    return true;
  }

  /// Gets the transaction ID.
  ///
  /// TODO implement.
  ///
  /// Returns:
  ///   A string representing the transaction ID.
  String txid() {
    // Placeholder for now.
    return "";
  }
}

import 'package:fusiondart/src/models/input.dart';
import 'package:fusiondart/src/models/output.dart';

class Transaction {
  List<Input> Inputs = [];
  List<Output> Outputs = [];

  Transaction();

  // TODO type
  static (Transaction, List<int>) txFromComponents(
      List<dynamic> allComponents, List<dynamic> sessionHash) {
    Transaction tx = Transaction(); // Initialize a new Transaction
    // TODO This should be based on wallet layer... implement the logic of constructing the transaction from components
    // For now, it just initializes Inputs and Outputs as empty lists
    tx.Inputs = [];
    tx.Outputs = [];

    // For now, just returning an empty list for inputIndices
    List<int> inputIndices = [];

    return (tx, inputIndices);
  }

  List<int> serializePreimage(int index, int hashType, {bool useCache = true}) {
    // Add implementation here
    // For now, returning an empty byte array
    return [];
  }

  String serialize() {
    // To implement...
    return "";
  }

  bool isComplete() {
    // implement based on wallet.
    return true;
  }

  String txid() {
    // To implement...
    return "";
  }
}

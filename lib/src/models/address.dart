import 'dart:convert';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:convert/convert.dart';
import 'package:fusiondart/src/util.dart';

/// A class representing a cryptocurrency address (Bitcoin Cash specifically for
/// CashFusion).
///
///
/// Attributes:
/// - [addr]: The address as a String.
/// - [publicKey] (optional): The public key as a List<int>.
/// - [derivationPath] (optional): The derivation path as a DerivationPath.
class Address {
  /// The address as a String.
  ///
  /// This is the only required parameter for the constructor. Can be used with
  /// _db.getAddress to get any of the other parameters below.
  final String address;

  /// The public key as a List<int>
  final List<int>? publicKey;

  /// The derivation path as a DerivationPath
  DerivationPath? derivationPath;

  /// Constructor for Address.
  Address({
    required this.address,
    this.publicKey,
    this.derivationPath,
  });

  /// Creates an Address from a script public key
  static Address fromScriptPubKey(List<int> scriptPubKey) {
    return Utilities.getAddressFromOutputScript(
        Uint8List.fromList(scriptPubKey));
  }

  /// Public constructor for testing. Calls private constructor `_create`.
  static Address fromString(String address, coinlib.NetworkParams network) {
    final addr = coinlib.Address.fromString(address, network);
    return Address(
      address: addr.toString(),
      publicKey: addr.program.script.compiled, // TODO: verify
    );
  }

  /// Converts the Address to its script form
  Uint8List toScript(coinlib.NetworkParams network) {
    if (publicKey == null) {
      throw Exception("Address must have a public key");
    }

    coinlib.ECPublicKey ecPublicKey =
        coinlib.ECPublicKey.fromHex(hex.encode(Uint8List.fromList(publicKey!)));

    coinlib.P2PKHAddress p2pkhAddress = coinlib.P2PKHAddress.fromPublicKey(
      ecPublicKey,
      version: network.p2pkhPrefix,
    );

    return p2pkhAddress.program.script.compiled;
  }

  /// Returns a JSON-String representation of the Address for easier debugging.
  @override
  String toString() => toJsonString();

  /// Converts the Address to a JSON-formatted String
  String toJsonString() => jsonEncode({
        "addr": address,
        "publicKey": publicKey,
        "derivationPath": derivationPath?.value,
      });

  /// Creates an Address from a JSON-formatted String
  static Address fromJsonString(String jsonString) {
    try {
      final json = jsonDecode(jsonString);
      final DerivationPath derivationPath =
          DerivationPath(json["derivationPath"] as String);
      return Address(
        address: json["addr"] as String,
        publicKey: List<int>.from(json["publicKey"] as List),
        derivationPath: derivationPath,
      );
    } catch (_) {
      throw Exception(
        "Failed to parse and instance of Address from $jsonString",
      );
    }
  }
}

/// A class representing a derivation path.
///
/// Attributes:
/// - [value]: The derivation path as a String.
class DerivationPath {
  // Holds the derivation path string
  final String value;

  // Constructor: Initializes 'value' with the given string
  DerivationPath(this.value);

  /// Splits the derivation path string into its components
  List<String> getComponents() => value.split("/");

  /// Extracts the 'purpose' from the derivation path components
  String getPurpose() => getComponents()[1];

  /// Overridden `toString` method for easier debugging
  @override
  toString() => value;

  /// Equality operator
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DerivationPath && value == other.value;

  /// hashCode implementation for use in collections
  @override
  int get hashCode => value.hashCode;
}

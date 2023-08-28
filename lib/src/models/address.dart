import 'dart:convert';

/// A class representing a cryptocurrency address (Bitcoin Cash specifically for
/// CashFusion).
///
/// Attributes:
/// - [addr]: The address as a String.
/// - [publicKey] (optional): The public key as a List<int>.
/// - [derivationPath] (optional): The derivation path as a DerivationPath.
class Address {
  // The address as a String.
  //
  // This is the only required parameter for the constructor. Can be used with
  // _db.getAddress to get any of the other parameters below.
  final String addr;

  // The public key as a List<int>
  late List<int>? publicKey;

  // The derivation path as a DerivationPath
  late DerivationPath? derivationPath;

  /// Constructor for Address.
  Address({
    required this.addr, // Constructor updated to accept addr as a named parameter
    this.publicKey,
    this.derivationPath,
  });

  // Private constructor used for creating an Address from a String.
  Address._create({required this.addr});

  /// Creates an Address from a script public key
  ///
  /// TODO implement
  static Address fromScriptPubKey(List<int> scriptPubKey) {
    // Placeholder code, 'addr' should be computed from 'scriptPubKey'
    String addr = "";
    return Address(addr: addr);
  }

  /// Public constructor for testing. Calls private constructor `_create`.
  static Address fromString(String address) {
    return Address._create(addr: address);
  }

  /// Converts the Address to its script form
  ///
  /// TODO implement
  List<int> toScript() {
    return [];
  }

  /// Returns a JSON-String representation of the Address for easier debugging.
  ///
  /// TODO use Dart's JSON encoder instead of implementing our own
  @override
  String toString() => "{ "
      "addr: $addr, "
      "publicKey: $publicKey, "
      "derivationPath: $derivationPath, "
      "}";

  /// Converts the Address to a JSON-formatted String
  ///
  /// TODO use Dart's JSON encoder instead of implementing our own
  String toJsonString() {
    final Map<String, dynamic> result = {
      "addr": addr,
      "publicKey": publicKey,
      "derivationPath":
          derivationPath?.value, // see also DerivationPath.getComponents()
    };
    return jsonEncode(result);
  }

  /// Creates an Address from a JSON-formatted String
  ///
  /// TODO use Dart's JSON decoder instead of implementing our own
  static Address fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString);
    final DerivationPath derivationPath =
        DerivationPath(json["derivationPath"] as String);
    return Address(
      addr: json["addr"] as String,
      publicKey: List<int>.from(json["publicKey"] as List),
      derivationPath: derivationPath,
    );
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

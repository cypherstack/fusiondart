import 'dart:convert';

class Address {
  final String
      addr; // can be used with _db.getAddress to get any of the other parameters below
  late List<int>? publicKey;
  late DerivationPath? derivationPath;

  Address({
    required this.addr, // Constructor updated to accept addr as a named parameter
    this.publicKey,
    this.derivationPath,
  });

  Address._create({required this.addr});

  static Address fromScriptPubKey(List<int> scriptPubKey) {
    // This is just a placeholder code
    String addr = ""; // This should be computed from the scriptPubKey
    return Address(addr: addr);
  }

  // Public constructor for testing
  static Address fromString(String address) {
    return Address._create(addr: address);
  }

  List<int> toScript() {
    return [];
  }

  @override
  String toString() => "{ "
      "addr: $addr, "
      "publicKey: $publicKey, "
      "derivationPath: $derivationPath, "
      "}";

  String toJsonString() {
    final Map<String, dynamic> result = {
      "addr": addr,
      "publicKey": publicKey,
      "derivationPath":
          derivationPath?.value, // see also DerivationPath.getComponents()
    };
    return jsonEncode(result);
  }

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

class DerivationPath {
  DerivationPath(this.value);

  final String value;

  List<String> getComponents() => value.split("/");

  String getPurpose() => getComponents()[1];

  @override
  toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DerivationPath && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

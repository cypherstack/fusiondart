import 'dart:convert';
import 'dart:typed_data';

// import 'package:dart_bs58/dart_bs58.dart';
// import 'package:dart_bs58check/dart_bs58check.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:hex/hex.dart';

extension Uint8ListExtensions on Uint8List {
  String get toUtf8String => utf8.decode(this);

  String get toHex {
    return HEX.encode(this);
  }

  // String get toBase58Encoded {
  //   return bs58.encode(this);
  // }
  //
  // String get toBase58CheckEncoded {
  //   return bs58check.encode(this);
  // }

  BigInt get toBigInt {
    BigInt number = BigInt.zero;
    for (final byte in this) {
      number = (number << 8) | BigInt.from(byte & 0xff);
    }
    return number;
  }
}

void f() {
  final c = InputComponent();

  final u = Uint8List.fromList(c.prevTxid.reversed.toList()).toHex;
}

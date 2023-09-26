import 'dart:typed_data';

import 'package:fusiondart/src/encrypt.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:test/test.dart';

void main() {
  final aPriv =
      '0000000000000000000000000000000000000000000000000000000000000005'
          .toUint8ListFromHex;
  final aPub =
      '022f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe4'
          .toUint8ListFromHex;

  test('short message', () async {
    final msg12 = 'test message'.toUint8ListFromUtf8;
    expect(msg12.length, 12);

    Uint8List e12 = await encrypt(msg12, aPub);
    expect(e12.length, 65);
  });
}

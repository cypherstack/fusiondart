import 'dart:typed_data';

import 'package:fusiondart/src/encrypt.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:test/test.dart';

// based on https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/tests/test_encrypt.py

void main() {
  late final Uint8List aPriv;
  late final Uint8List aPub;
  late final Uint8List msg12;

  setUp(() {
    aPriv = '0000000000000000000000000000000000000000000000000000000000000005'
        .toUint8ListFromHex;
    aPub = '022f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe4'
        .toUint8ListFromHex;
    msg12 = 'test message'.toUint8ListFromUtf8;
  });

  test('encrypt.dart tests', () async {
    // ============== short message ============================================

    expect(msg12.length, 12);

    Uint8List e12 = await encrypt(msg12, aPub);
    expect(e12.length, 65);

    e12 = await encrypt(msg12, aPub, padToLength: 16);
    expect(e12.length, 65);

    final result = await decrypt(e12, aPriv);

    final k = result.symmetricKey;
    Uint8List d12 = result.decrypted;

    expect(d12.toString(), msg12.toString());

    d12 = await decryptWithSymmkey(e12, k);
    expect(d12.toString(), msg12.toString());

    // ============== tweak the nonce point's oddness bit ======================

    Uint8List e12Bad = Uint8List.fromList(e12); // create copy to modify
    e12Bad[0] = e12Bad[0] ^ 1;

    Object? e;
    try {
      await decrypt(e12Bad, aPriv);
    } catch (err) {
      e = err;
    }
    expect(e, isA<DecryptionFailed>());

    d12 = await decryptWithSymmkey(e12Bad, k);
    expect(d12.toString(), msg12.toString());

    // ============== tweak the hmac ===========================================

    e12Bad = Uint8List.fromList(e12); // create copy to modify
    e12Bad[e12Bad.length - 1] = e12Bad[e12Bad.length - 1] ^ 1;

    e = null;
    try {
      await decrypt(e12Bad, aPriv);
    } catch (err) {
      e = err;
    }
    expect(e, isA<DecryptionFailed>());

    e = null;
    try {
      await decryptWithSymmkey(e12Bad, k);
    } catch (err) {
      e = err;
    }
    expect(e, isA<DecryptionFailed>());

    // ============== tweak the nonce point's oddness bit ======================

    // TODO

    // ============== tweak the nonce point's oddness bit ======================

    // TODO
  });
}

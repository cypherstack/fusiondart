import 'dart:convert';
import 'dart:typed_data';

import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:test/test.dart';

void main() {
  group('EC Point Tests', () {
    late Uint8List hBytes;
    late ECDomainParameters params;
    ECPoint? H;
    ECPoint? HG;

    setUp(() {
      // Set up Pedersen setup instance.
      Uint8List prefix = Uint8List.fromList([0x02]);
      List<int> stringBytes = utf8.encode('CashFusion gives us fungibility.');
      hBytes = Uint8List.fromList([...prefix, ...stringBytes]);

      // Use secp256k1 curve.
      params = ECDomainParameters('secp256k1');

      // Deserialize hBytes to get point H.
      H = params.curve.decodePoint(hBytes);
    });

    test('Decode point H', () {
      expect(H, isNotNull, reason: 'Failed to decode point');
    });

    test('Validate H is on the curve', () {
      expect(Utilities.isPointOnCurve(H!, params.curve), isTrue,
          reason: 'H is not a valid point on the curve');
    });

    test('Calculate H + G', () {
      HG = H! + params.G;
      expect(HG, isNotNull, reason: 'Failed to compute HG');
      expect(HG, equals(Utilities.combinePubKeys([H!, params.G])),
          reason: 'HG computation inconsistency');
    });

    test('Validate HG is on the curve', () {
      expect(Utilities.isPointOnCurve(HG!, params.curve), isTrue,
          reason: 'HG is not a valid point on the curve');
    });
  });
}

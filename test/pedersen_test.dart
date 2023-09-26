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
      // This setup will be overridden in each test
      params = ECDomainParameters('secp256k1');
    });

    void commonTests() {
      // Deserialize hBytes to get point H.
      H = params.curve.decodePoint(hBytes);

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
    }

    test('hBytes using codeUnits', () {
      hBytes = Uint8List.fromList(
          [0x02] + 'CashFusion gives us fungibility.'.codeUnits);
      commonTests();
    });

    test('hBytes using utf8.encode', () {
      hBytes = Uint8List.fromList(
          [0x02, ...utf8.encode('CashFusion gives us fungibility.')]);
      commonTests();
    });

    test('hBytes using utf8.encode with prefix', () {
      hBytes = Uint8List.fromList(
          [...utf8.encode('\x02CashFusion gives us fungibility.')]);
      commonTests();
    });

    test('hBytes using separate prefix and utf8.encode', () {
      Uint8List prefix = Uint8List.fromList([0x02]);
      List<int> stringBytes = utf8.encode('CashFusion gives us fungibility.');
      hBytes = Uint8List.fromList([...prefix, ...stringBytes]);
      commonTests();
    });
  });
}

import 'dart:typed_data';

import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:fusiondart/src/pedersen.dart';
import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:test/test.dart';

void main() {
  group('PedersenSetup Tests', () {
    test('TestBadSetup', () {
      final invalidHPointHex1 =
          "0379be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
      final invalidHPointHex2 =
          "0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798b7c52588d95c3b9aa25b0403f1eef75702e84bb7597aabe663b82f6f04ef2777";

      expect(
        () => PedersenSetup(invalidHPointHex1.toUint8ListFromHex),
        throwsA(isA<InsecureHPoint>()),
        reason: 'Should raise InsecureHPoint exception for invalid H point 1',
      );

      expect(
        () => PedersenSetup(invalidHPointHex2.toUint8ListFromHex),
        throwsA(isA<InsecureHPoint>()),
        reason: 'Should raise InsecureHPoint exception for invalid H point 2',
      );

      final nonPointHex =
          "030000000000000000000000000000000000000000000000000000000000000007";

      expect(
        () => PedersenSetup(nonPointHex.toUint8ListFromHex),
        throwsA(isA<ArgumentError>()),
        reason: 'Should raise ArgumentError for non-point input',
      );
    });
  });

  group('EC Point Tests', () {
    late Uint8List hBytes;
    late ECDomainParameters params;
    ECPoint? H;
    ECPoint? HG;

    setUp(() {
      // Set up Pedersen setup instance.
      // Uint8List hBytes = Uint8List.fromList(
      //     [0x02] + 'CashFusion gives us fungibility.'.codeUnits);
      // Uint8List hBytes = Uint8List.fromList(
      //     [0x02, ...utf8.encode('CashFusion gives us fungibility.')]);
      // Uint8List hBytes = Uint8List.fromList(
      //     [...utf8.encode('\x02CashFusion gives us fungibility.')]);
      final Uint8List prefix = Uint8List.fromList([0x02]);
      final Uint8List stringBytes =
          'CashFusion gives us fungibility.'.toUint8ListFromUtf8;
      hBytes = Uint8List.fromList([...prefix, ...stringBytes]);

      // Deserialize hBytes to get point H.
      H = Utilities.secp256k1Params.curve.decodePoint(hBytes);
    });

    test('Decode point H', () {
      expect(
        H,
        isNotNull,
        reason: 'Failed to decode point',
      );
    });

    test('Validate H is on the curve', () {
      expect(
        Utilities.isPointOnCurve(H!, Utilities.secp256k1Params.curve),
        isTrue,
        reason: 'H is not a valid point on the curve',
      );
    });

    test('Calculate H + G', () {
      HG = H! + Utilities.secp256k1Params.G;
      expect(
        HG,
        isNotNull,
        reason: 'Failed to compute HG',
      );
      expect(
        HG,
        equals(H! + Utilities.secp256k1Params.G),
        reason: 'HG computation inconsistency',
      );
    });

    test('Validate HG is on the curve', () {
      expect(
        Utilities.isPointOnCurve(HG!, Utilities.secp256k1Params.curve),
        isTrue,
        reason: 'HG is not a valid point on the curve',
      );
    });
  });

  // group("PedersenSetup", () {
  //   test("Constructor", () {
  //     final setup = PedersenSetup(_pointH)
  //   });
  // });
}

ECPoint decodeHex(String hex) {
  final curve = ECCurve_secp256k1();
  final decoder = curve.curve.decodePoint;
  final bytes = hexToBytes(hex);
  final decoded = decoder(bytes);
  if (decoded == null) {
    throw ArgumentError('Failed to decode point');
  }
  return decoded;
}

Uint8List hexToBytes(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    final hexByte = hex.substring(i, i + 2);
    bytes[i ~/ 2] = int.parse(hexByte, radix: 16);
  }
  return bytes;
}

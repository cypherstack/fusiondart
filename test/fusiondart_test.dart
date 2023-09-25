import 'dart:io';

import 'package:fusiondart/fusiondart.dart';
import 'package:test/test.dart';

void main() {
  test('create Fusion instance just to test compile time warnings/errors', () {
    // create instance just to test compile time warnings/errors
    final f = Fusion(
      getAddresses: () async => [],
      getInputsByAddress: (_) async => [],
      getTransactionsByAddress: (_) async => [],
      getUnusedReservedChangeAddresses: (_) async => [],
      getSocksProxyAddress: () async =>
          (host: InternetAddress.loopbackIPv4, port: 42),
    );

    expect(f, isA<Fusion>());
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' show loadCoinlib;
import 'package:fixnum/fixnum.dart';
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:test/test.dart';

/// secp256k1's generator point, compressed.
final _pubKey = [
  0x02, 0x79, 0xbe, 0x66, 0x7e, 0xf9, 0xdc, 0xbb, 0xac, 0x55, 0xa0, //
  0x62, 0x95, 0xce, 0x87, 0x0b, 0x07, 0x02, 0x9b, 0xfc, 0xdb, 0x2d,
  0xce, 0x28, 0xd9, 0x59, 0xf2, 0x81, 0x5b, 0x16, 0xf8, 0x17, 0x98,
];

UtxoDTO _coin(int i, int value) => UtxoDTO(
      txid: i.toRadixString(16).padLeft(64, '0'),
      vout: 0,
      value: value,
      pubKey: _pubKey,
      address: 'address$i',
    );

/// A CashFusion server that greets each client, then hangs up on JoinPools.
Future<({int port, List<JoinPools> joins})> _server() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final joins = <JoinPools>[];
  server.listen((client) {
    final buffer = <int>[];
    client.listen((bytes) {
      buffer.addAll(bytes);
      while (buffer.length >= 12) {
        final length = ByteData.sublistView(Uint8List.fromList(buffer), 8, 12)
            .getUint32(0);
        if (buffer.length < 12 + length) break;
        final message =
            ClientMessage.fromBuffer(buffer.sublist(12, 12 + length));
        buffer.removeRange(0, 12 + length);
        if (message.hasClienthello()) {
          final reply = ServerMessage(
            serverhello: ServerHello(
              tiers: [10000, 100000, 1000000].map(Int64.new),
              numComponents: 23,
              componentFeerate: Int64(1000),
              minExcessFee: Int64(10),
              maxExcessFee: Int64(10000),
            ),
          ).writeToBuffer();
          final header = ByteData(4)..setUint32(0, reply.length);
          client.add([
            ...Connection.magic,
            ...header.buffer.asUint8List(),
            ...reply,
          ]);
        } else if (message.hasJoinpools()) {
          joins.add(message.joinpools);
          client.destroy();
        }
      }
    }, onError: (Object _) {});
  });
  return (port: server.port, joins: joins);
}

Future<Fusion> _fusion(int port) async {
  final fusion = Fusion(FusionParams(
    serverHost: InternetAddress.loopbackIPv4.address,
    serverPort: port,
    serverSsl: false,
    genesisHashHex:
        '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f',
    mode: FusionMode.normal,
    torForOvert: false,
  ));
  await fusion.initFusion(
    getTransactionsByAddress: (_) async => [],
    getUnusedReservedChangeAddresses: (_) async => [],
    getSocksProxyAddress: () async =>
        (host: InternetAddress.loopbackIPv4, port: 9050),
    getChainHeight: () async => 800000,
    updateStatusCallback: ({required status, info}) {},
    getTransactionJson: (_) async => {},
    getPrivateKeyForPubKey: (_) async => Uint8List(32),
    broadcastTransaction: (_) async => '',
    unReserveAddresses: (_) async {},
    checkUtxoExists: (_, __, ___) async => true,
  );
  return fusion;
}

void main() {
  final tooSmall = [_coin(0, 600)];

  // Fusion needs coinlib's native secp256k1: `dart run coinlib:build_<os>`.
  String? noSecp256k1;
  setUpAll(() async {
    try {
      await loadCoinlib();
    } catch (e) {
      noSecp256k1 = 'secp256k1 unavailable ($e)';
    }
  });
  void needSecp256k1() {
    if (noSecp256k1 != null) markTestSkipped(noSecp256k1!);
  }

  test('fuse() stops when allocating outputs fails', () async {
    needSecp256k1();
    if (noSecp256k1 != null) return;
    final server = await _server();
    final fusion = await _fusion(server.port);

    await expectLater(
        fusion.fuse(inputsFromWallet: tooSmall, network: Utilities.mainNet),
        throwsA(isA<FusionError>()));
    expect(server.joins, isEmpty);
    expect(fusion.status.status, FusionStatus.failed);
  });

  test('a failed allocation does not reuse the previous one', () async {
    needSecp256k1();
    if (noSecp256k1 != null) return;
    final server = await _server();
    final fusion = await _fusion(server.port);

    // Allocates, joins pools, then loses the connection.
    final coins = [for (var i = 1; i <= 5; i++) _coin(i, 1000000 + i)];
    await expectLater(
        fusion.fuse(inputsFromWallet: coins, network: Utilities.mainNet),
        throwsA(anything));
    expect(server.joins, hasLength(1));

    await expectLater(
        fusion.fuse(inputsFromWallet: tooSmall, network: Utilities.mainNet),
        throwsA(isA<FusionError>()));
    expect(server.joins, hasLength(1));
  });
}

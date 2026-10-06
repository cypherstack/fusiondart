import 'dart:io';

import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/covert/covert_connection.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:test/test.dart';

void main() {
  test('a failed ping is reported to the caller', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) => addTearDown(peer.destroy));

    final connection =
        await Connection.openConnection(host: 'localhost', port: server.port);
    await connection.close();
    final covert = CovertConnection()..connection = connection;
    await expectLater(covert.ping(), throwsA(isA<FusionError>()));
  });
}

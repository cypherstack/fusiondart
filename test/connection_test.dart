@TestOn('linux || mac-os || windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:fusiondart/src/connection.dart';
import 'package:test/test.dart';

const _frameOverhead = 12; // magic + length

/// A SOCKS5 proxy that accepts one CONNECT and then counts tunnel bytes.
///
/// [onTunnel] runs once the CONNECT reply is sent, with the tunnel peer and
/// its input subscription. The returned future completes with the byte count
/// when the client's side of the tunnel ends.
Future<({int port, Future<int> received})> _proxy(
    FutureOr<void> Function(Socket peer, StreamSubscription<List<int>> input)
        onTunnel) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final received = Completer<int>();
  server.listen((peer) {
    addTearDown(peer.destroy);
    // A small SO_RCVBUF keeps a large frame queued on the sending side.
    peer.setRawOption(RawSocketOption.fromInt(
        RawSocketOption.levelSocket, Platform.isLinux ? 8 : 0x1002, 65536));
    final buffer = <int>[];
    var tunnel = false;
    var count = 0;
    late StreamSubscription<List<int>> input;
    input = peer.listen((bytes) {
      if (tunnel) {
        count += bytes.length;
        return;
      }
      buffer.addAll(bytes);
      if (buffer.length == 3) {
        peer.add([5, 0]);
      } else if (buffer.length > 8 && buffer.length == 10 + buffer[7]) {
        tunnel = true;
        peer.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        onTunnel(peer, input);
      }
    }, onDone: () {
      if (!received.isCompleted) received.complete(count);
    }, onError: (Object _) {});
  });
  return (port: server.port, received: received.future);
}

Future<Connection> _connect(int proxyPort) => Connection.openConnection(
      host: 'localhost',
      port: 8787,
      proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxyPort),
    );

void main() {
  test('a proxied send survives the server closing its side', () async {
    const size = 8 * 1024 * 1024;
    // The tunnel peer half-closes, then reads slowly.
    final proxy = await _proxy((peer, input) async {
      input.pause();
      await peer.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      input.resume();
    });

    final connection = await _connect(proxy.port);
    addTearDown(() => connection.close(force: true));
    // Fusion keeps a receive pending, so the server's EOF is seen mid-send.
    final reply = expectLater(connection.recvMessage(), throwsA(anything));
    await connection.sendMessage(List.filled(size, 1),
        timeout: const Duration(seconds: 10));
    await reply;
    await connection.close();
    expect(await proxy.received.timeout(const Duration(seconds: 10)),
        _frameOverhead + size);
  });

  test('a send still queued when the server closes its side is delivered',
      () async {
    const size = 8 * 1024 * 1024;
    // The tunnel peer half-closes, then reads slowly.
    final proxy = await _proxy((peer, input) async {
      input.pause();
      await peer.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      input.resume();
    });

    final connection = await _connect(proxy.port);
    addTearDown(() => connection.close(force: true));
    final reply = expectLater(connection.recvMessage(), throwsA(anything));
    final first = connection.sendMessage(List.filled(size, 1),
        timeout: const Duration(seconds: 10));
    // This frame stays queued until the first finishes after the server's EOF.
    final second =
        connection.sendMessage([1], timeout: const Duration(seconds: 10));
    await first;
    await second;
    await reply;
    await connection.close();
    expect(await proxy.received.timeout(const Duration(seconds: 10)),
        2 * _frameOverhead + size + 1);
  });

  test('closing a proxied connection after a failed send completes', () async {
    // The proxy resets the tunnel once the client starts sending.
    final proxy = await _proxy((peer, _) {
      Future<void>.delayed(const Duration(milliseconds: 50), peer.destroy);
    });

    final connection = await _connect(proxy.port);
    Future<void> sendUntilFailure() async {
      while (true) {
        await connection.sendMessage(List.filled(1024 * 1024, 1),
            timeout: const Duration(seconds: 10));
      }
    }

    await expectLater(sendUntilFailure(), throwsA(anything));
    await connection.close();
  });

  test('close() sends the frames still queued', () async {
    final proxy = await _proxy((_, __) {});

    final connection = await _connect(proxy.port);
    final first = connection.sendMessage([1]);
    final second = connection.sendMessage([2, 3]);
    await connection.close();
    await first;
    await second;
    expect(await proxy.received.timeout(const Duration(seconds: 10)),
        2 * _frameOverhead + 3);
    await expectLater(connection.sendMessage([4]), throwsStateError);
  });

  test('close(force: true) does not wait for a stalled send', () async {
    // The tunnel peer never reads.
    final proxy = await _proxy((_, input) => input.pause());

    final connection = await _connect(proxy.port);
    final send = connection.sendMessage(List.filled(8 * 1024 * 1024, 1),
        timeout: const Duration(seconds: 30));
    final failed = expectLater(send, throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await connection.close(force: true).timeout(const Duration(seconds: 5));
    await failed;
  });

  test('close(force: true) fails a pending direct send', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    // The server never reads.
    server.listen((peer) {
      addTearDown(peer.destroy);
      peer.listen(null, onError: (Object _) {}).pause();
    });

    final connection =
        await Connection.openConnection(host: 'localhost', port: server.port);
    final send = connection.sendMessage(List.filled(8 * 1024 * 1024, 1),
        timeout: const Duration(seconds: 30));
    final failed = expectLater(send, throwsA(isA<SocketException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await connection.close(force: true);
    await failed;
  });

  test('a timed-out send aborts the connection', () async {
    // The tunnel peer never reads.
    final proxy = await _proxy((_, input) => input.pause());

    final connection = await _connect(proxy.port);
    await expectLater(
        connection.sendMessage(List.filled(8 * 1024 * 1024, 1),
            timeout: const Duration(milliseconds: 500)),
        throwsA(isA<TimeoutException>()));
    // Nothing is left for close() to wait on.
    await connection.close().timeout(const Duration(seconds: 5));
  });

  test('a send that times out while queued is dropped', () async {
    const size = 8 * 1024 * 1024;
    // The tunnel peer stops reading for 2 s.
    final proxy = await _proxy((_, input) {
      input.pause();
      Timer(const Duration(seconds: 2), input.resume);
    });

    final connection = await _connect(proxy.port);
    addTearDown(() => connection.close(force: true));
    final first = connection.sendMessage(List.filled(size, 1),
        timeout: const Duration(seconds: 20));
    await expectLater(
        connection.sendMessage([1], timeout: const Duration(milliseconds: 500)),
        throwsA(isA<TimeoutException>()));
    await first;
    // Give a late second frame time to arrive.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await connection.close();
    expect(await proxy.received.timeout(const Duration(seconds: 10)),
        _frameOverhead + size);
  });

  test('a send may outlast socks_socket\'s default 30 s operation timeout',
      () async {
    const size = 8 * 1024 * 1024;
    // The tunnel peer stops reading for 32 s.
    final proxy = await _proxy((_, input) {
      input.pause();
      Timer(const Duration(seconds: 32), input.resume);
    });

    final connection = await _connect(proxy.port);
    addTearDown(() => connection.close(force: true));
    await connection.sendMessage(List.filled(size, 1),
        timeout: const Duration(seconds: 40));
    await connection.close();
    expect(await proxy.received.timeout(const Duration(seconds: 10)),
        _frameOverhead + size);
  }, timeout: const Timeout(Duration(seconds: 60)), tags: 'slow');
}

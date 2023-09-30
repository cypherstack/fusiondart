import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:fusiondart/src/socketwrapper.dart';
import 'package:fusiondart/src/util.dart';
import 'package:socks_socket/socks_socket.dart';

// TODO
// This file might need some fixing up because each time we call fillBuf, we're trying to
// remove data from a buffer but its a local copy , might not actually
// remove the data from the socket buffer.  We may need a wrapper class for the buffer??

/// Class to handle a connection.
///
/// This class is used to send and receive messages over a socket.
///
/// Attributes:
/// - [timeout]: The timeout duration.
/// - [socket]: The socket object.
class Connection {
  // Default timeout of 1 second.
  Duration timeout = Duration(seconds: 1);

  // The actual socket object.
  Socket? socket;

  // Buffer to store incoming data, initialized to zero-length.
  final Uint8List recvbuf = Uint8List(0);

  // Defines the maximum length allowed for a message in [bytes], set to 200 KB.
  static const int MAX_MSG_LENGTH = 200 * 1024;

  // Magic bytes used for protocol identification.
  static final Uint8List magic =
      Uint8List.fromList([0x76, 0x5b, 0xe8, 0xb4, 0xe4, 0x39, 0x6d, 0xcf]);

  /// Constructor to initialize a Connection object with a socket.
  ///
  /// Parameters:
  /// - [socket]: The socket to use.
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Connection object.
  Connection({required this.socket, this.timeout = const Duration(seconds: 1)});

  /// Constructor to initialize a Connection object without a socket.
  ///
  /// Parameters:
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Connection object.
  Connection.withoutSocket({this.timeout = const Duration(seconds: 1)});

  /// Asynchronous function to open a new connection.
  ///
  /// Parameters:
  /// - [host]: The host to connect to.
  /// - [port]: The port to connect to.
  /// - [connTimeout] (optional): The connection timeout duration.
  /// - [defaultTimeout] (optional): The default timeout duration.
  /// - [ssl] (optional): Whether to use SSL.
  /// - [proxyInfo] (optional): Socks options.
  ///
  /// Returns:
  ///  A Future<Connection> object.
  static Future<Connection> openConnection({
    required String host,
    required int port,
    Duration connTimeout = const Duration(seconds: 5),
    Duration defaultTimeout = const Duration(seconds: 5),
    bool ssl = false,
    ({InternetAddress host, int port})? proxyInfo,
  }) async {
    // Before we connect to host and port, if proxyInfo is not null, we should connect to the proxy first.
    if (proxyInfo != null) {
      try {
        /*
        // CoPilot suggested this code!  It might actually work.  I thought SocketWrapper was
        // for this anyways, but I was going to use socks_socket...  I should probably try this
        // out and see if it or similar works.  Better to have less dependencies.  Anyways...

        // Connect to the proxy.
        final SocketWrapper socketwrapper =
        SocketWrapper(proxyInfo.host.address, proxyInfo.port);
        await socketwrapper.connect();

        // Send the CONNECT message.
        final msg = <int>[]
          ..addAll([0x05, 0x01, 0x00])
          ..addAll([0x03, host.length])
          ..addAll(utf8.encode(host)) // import convert.
          ..addAll([port >> 8, port & 0xff]);
        await socketwrapper.send(msg);

        // Receive the response.
        final response = await socketwrapper.receive(10);
        if (response[0] != 0x05 || response[1] != 0x00) {
          throw 'Failed to connect to proxy: ${hex.encode(response)}';
        }

        // Connect to the host and port through the proxy.
        socketwrapper.connectTo(host, port); // connectTo doesn't exist.  So close, CoPilot.
        */

        // From https://github.com/cypherstack/tor/blob/53b1c97a41542956fc6887878ba3147abae20ccd/example/lib/main.dart#L166

        // Instantiate a socks socket at localhost and on the port selected by the tor service.
        var socksSocket = await SOCKSSocket.create(
          proxyHost: proxyInfo.host.address,
          proxyPort: proxyInfo.port,
          sslEnabled: ssl,
        );

        // Connect to the socks instantiated above.
        await socksSocket.connect();

        // Connect to CashFusion server.
        await socksSocket.connectTo(host, port);

        return Connection(
          socket:
              socksSocket.socket, // This might not "just work", but it might.
          timeout: defaultTimeout,
        );
        // TODO Close the socket.
        // await socksSocket.close();
      } catch (e, s) {
        Utilities.debugPrint(s);
        throw 'openConnection(): Failed to open proxied connection: $e';
      }
    } else {
      try {
        // Connect to host and port.
        //
        // Dart's Socket class handles connection timeout internally.
        final Socket socket;
        if (ssl) {
          socket = await SecureSocket.connect(host, port);
        } else {
          socket = await Socket.connect(host, port);
        }

        // Create a Connection object and return it.
        return Connection(
          socket: socket,
          timeout: defaultTimeout,
        );
      } catch (e) {
        throw 'openConnection(): Failed to open direct connection: $e';
      }
    }
  }

  /// Asynchronous method to send a message with a socket wrapper.
  ///
  /// Parameters:
  /// - [socketwrapper]: The socket wrapper to use.
  /// - [msg]: The message to send.
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Future<void> object.
  Future<void> sendMessageWithSocketWrapper(
      SocketWrapper socketwrapper, List<int> msg,
      {Duration? timeout}) async {
    // Use class-level timeout if no argument-level timeout is provided.
    timeout ??= this.timeout;

    // Prepare the 4-byte length header for the message.
    Utilities.debugPrint("DEBUG sendmessage msg sending ");
    Utilities.debugPrint(msg);
    final lengthBytes = Uint8List(4);
    final byteData = ByteData.view(lengthBytes.buffer);
    byteData.setUint32(0, msg.length, Endian.big);

    // Construct the frame to send. The frame includes:
    // - The "magic" bytes for validation
    // - The 4-byte length header
    // - The message itself
    final frame = <int>[]
      ..addAll(Connection.magic)
      ..addAll(lengthBytes)
      ..addAll(msg);

    // Send the frame.
    try {
      await socketwrapper.send(frame);
      // TODO should this be unawaited?
    } on SocketException catch (e) {
      throw TimeoutException('Socket write timed out ($e)', timeout);
    }
  }

  /// Asynchronous method to send a message.
  ///
  /// Parameters:
  ///  - [msg]: The message to send.
  ///  - [timeout]: The timeout duration.
  ///
  /// Returns:
  ///   A Future<void> object.
  Future<void> sendMessage(List<int> msg, {Duration? timeout}) async {
    // Use class-level timeout if no argument-level timeout is provided.
    timeout ??= this.timeout;

    // Prepare the 4-byte length header for the message.
    final lengthBytes = Uint8List(4);
    final byteData = ByteData.view(lengthBytes.buffer);
    byteData.setUint32(0, msg.length, Endian.big);

    // Construct the frame to send. The frame includes:
    // - The "magic" bytes for validation
    // - The 4-byte length header
    // - The message itself
    Utilities.debugPrint(Connection.magic);
    final frame = <int>[]
      ..addAll(Connection.magic)
      ..addAll(lengthBytes)
      ..addAll(msg);

    // Send the frame using the Dart Stream API.
    try {
      StreamController<List<int>> controller = StreamController();

      controller.stream.listen((data) {
        socket?.add(data);
      });

      try {
        controller.add(frame);
        // Remove the socket.flush() if it doesn't help.
        /*await socket?.flush();*/
      } catch (e) {
        Utilities.debugPrint('Error when adding to controller: $e');
      } finally {
        await controller.close();
      }
    } on SocketException catch (e) {
      throw TimeoutException('Socket write timed out ($e)', timeout);
    }
  }

  /// Asynchronous close a socket.
  ///
  /// Returns:
  ///   A Future<dynamic> object.
  Future<dynamic>? close() {
    return socket?.close();
  }

  /// Fill a buffer with data from a socket.
  ///
  /// Parameters:
  /// - [socketwrapper]: The socket wrapper to use.
  /// - [recvBuf]: The buffer to fill.
  /// - [n]: The number of bytes to read.
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Future<List<int>> object.
  Future<List<int>> fillBuf2(
      SocketWrapper socketwrapper, List<int> recvBuf, int n,
      {Duration? timeout}) async {
    // Sets the time when this operation should timeout.
    final maxTime = timeout != null ? DateTime.now().add(timeout) : null;

    // Listen for incoming data from the socket
    await for (List<int> data in socketwrapper.socket!.cast<List<int>>()) {
      // Checks for timeout.
      Utilities.debugPrint("DEBUG fillBuf2 1 - new data received: $data");
      if (maxTime != null && DateTime.now().isAfter(maxTime)) {
        throw SocketException('Timeout');
      }

      // Checks for unexpected end of connection.
      if (data.isEmpty) {
        if (recvBuf.isNotEmpty) {
          throw SocketException('Connection ended mid-message.');
        } else {
          throw SocketException('Connection ended while awaiting message.');
        }
      }

      // Adds incoming data to the buffer.
      recvBuf.addAll(data);
      Utilities.debugPrint(
          "DEBUG fillBuf2 2 - data added to recvBuf, new length: ${recvBuf.length}");

      // Breaks out of the loop if the buffer has enough data.
      if (recvBuf.length >= n) {
        Utilities.debugPrint(
            "DEBUG fillBuf2 3 - breaking loop, recvBuf is big enough");
        break;
      }
    }

    return recvBuf;
  }

  /// Fill a buffer with data from a socket.
  ///
  /// [DEPRECATED]
  ///
  /// Parameters:
  /// - [n]: The number of bytes to read.
  /// - [timeout] (optional): The timeout duration.
  Future<List<int>> fillBuf(int n, {Duration? timeout}) async {
    List<int> recvBuf = <int>[];
    socket?.listen((data) {
      Utilities.debugPrint('Received from server: $data');
    }, onDone: () {
      Utilities.debugPrint('Server closed connection.');
      socket?.destroy();
    }, onError: (dynamic error) {
      Utilities.debugPrint('Error: $error');
      socket?.destroy();
    });
    return recvBuf;

    StreamSubscription<List<int>>? subscription; // Declaration moved here.
    subscription = socket!.listen(
      (List<int> data) {
        recvBuf.addAll(data);
        if (recvBuf.length >= n) {
          subscription?.cancel();
        }
      },
      onError: (dynamic e) {
        subscription?.cancel();
        if (e is Exception) {
          throw e;
        } else {
          throw Exception(e ?? 'Error in `subscription` socket!.listen');
        }
      },
      onDone: () {
        Utilities.debugPrint("DEBUG ON DONE");
        if (recvBuf.length < n) {
          throw SocketException(
              'Connection closed before enough data was received');
        }
      },
    );

    if (timeout != null) {
      Future.delayed(timeout, () {
        if (recvBuf.length < n) {
          subscription?.cancel();
          throw SocketException('Timeout');
        }
      });
    }

    return recvBuf;
  }

  /// Receive a message with a socket wrapper.
  ///
  /// Parameters:
  /// - [socketwrapper]: The socket wrapper to use.
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Future<List<int>> object.
  Future<List<int>> recvMessage2(SocketWrapper socketwrapper,
      {Duration? timeout}) async {
    Utilities.debugPrint("START OF RECV2");
    // Use class-level timeout if no argument-level timeout is provided.
    timeout ??= this.timeout;

    // Calculate the absolute max time for this operation based on the timeout.
    final maxTime = DateTime.now().add(timeout);

    // Initialize a buffer to store received data.
    List<int> recvBuf = [];

    // Variable to track the number of bytes read so far.
    int bytesRead = 0;

    Utilities.debugPrint("DEBUG recv_message2 1 - about to read the header");

    try {
      // Loop to read incoming data from the socket.
      await for (List<int> data in socketwrapper.receiveStream) {
        // Check if the operation has timed out.
        if (DateTime.now().isAfter(maxTime)) {
          throw SocketException('Timeout');
        }

        // Check if the connection has ended.
        if (data.isEmpty) {
          if (recvBuf.isNotEmpty) {
            throw SocketException('Connection ended mid-message.');
          } else {
            throw SocketException('Connection ended while awaiting message.');
          }
        }

        // Append received data to the receive buffer.
        recvBuf.addAll(data);

        // Update the bytesRead count.
        if (bytesRead < 12) {
          bytesRead += data.length;
        }

        // Check if we've received enough bytes to start processing the header.
        if (recvBuf.length >= 12) {
          // Extract and validate the magic bytes from the received data.
          final magic = recvBuf.sublist(0, 8);

          if (!ListEquality<dynamic>().equals(magic, Connection.magic)) {
            throw BadFrameError('Bad magic in frame: ${hex.encode(magic)}');
          }

          // Extract the message length from the received data.
          final byteData =
              ByteData.view(Uint8List.fromList(recvBuf.sublist(8, 12)).buffer);
          final messageLength = byteData.getUint32(0, Endian.big);

          // Validate the message length.
          if (messageLength > MAX_MSG_LENGTH) {
            throw BadFrameError(
                'Got a frame with msg_length=$messageLength > $MAX_MSG_LENGTH (max)');
          }

          Utilities.debugPrint(
              "DEBUG recv_message2 3 - about to read the message body, messageLength: $messageLength");

          Utilities.debugPrint("DEBUG recvfbuf len is ");
          Utilities.debugPrint(recvBuf.length);
          Utilities.debugPrint("bytes read is ");
          Utilities.debugPrint(bytesRead);
          Utilities.debugPrint("message length is ");
          Utilities.debugPrint(messageLength);

          // Check if the entire message has been received.
          if (recvBuf.length == bytesRead && bytesRead == 12 + messageLength) {
            // Extract and return the received message.
            final message = recvBuf.sublist(12, 12 + messageLength);

            Utilities.debugPrint(
                "DEBUG recv_message2 4 - message received, length: ${message.length}");
            Utilities.debugPrint(
                "DEBUG recv_message2 5 - message content: $message");
            // Utilities.debugPrint(utf8.decode(message));
            Utilities.debugPrint("END OF RECV2");
            return message;
          } else {
            // Throwing exception if the length doesn't match
            throw Exception(
                'Message length mismatch: expected ${12 + messageLength} bytes, received ${recvBuf.length} bytes.');
          }
        }
      }
    } on SocketException catch (e) {
      // Handle any SocketExceptions that may occur.
      rethrow;
      // Disable this rethrow if it causes too many issues, previously we just printed the exception
      // Utilities.debugPrint('Socket exception: $e');
    }

    // This is a default return in case of exceptions.
    return [];
  }

  /// Receive a message.
  ///
  /// [DEPRECATED]
  ///
  /// Parameters:
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Future<List<int>> object.
  Future<List<int>> recvMessage({Duration? timeout}) async {
    // DEPRECATED
    return [];
  }
} // end of Connection class.

/// Class to handle a bad frame error.
///
/// Attributes:
/// - [message]: The error message String.
class BadFrameError extends Error {
  /// The error message String.
  final String message;

  /// Constructor to initialize a BadFrameError object.
  BadFrameError(this.message);

  /// Returns a string representation of this object.
  @override
  String toString() => message;
}

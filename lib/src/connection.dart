import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:fusiondart/src/extensions/on_list_int.dart';
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
  final Socket socket;

  final Stream<List<int>> receiveStream;

  // Defines the maximum length allowed for a message in [bytes], set to 200 KB.
  static const int MAX_MSG_LENGTH = 200 * 1024;

  // Magic bytes used for protocol identification.
  static final magic = [0x76, 0x5b, 0xe8, 0xb4, 0xe4, 0x39, 0x6d, 0xcf];

  // Message length instance variable.
  int messageLength = 0;

  /// Constructor to initialize a Connection object with a socket.
  ///
  /// Parameters:
  /// - [socket]: The socket to use.
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Connection object.
  Connection._({
    required this.socket,
    this.timeout = const Duration(seconds: 1),
  }) : receiveStream = socket.asBroadcastStream();

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

        return Connection._(
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
        return Connection._(
          socket: socket,
          timeout: defaultTimeout,
        );
      } catch (e) {
        throw 'openConnection(): Failed to open direct connection: $e';
      }
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
    final frame = [...Connection.magic, ...lengthBytes, ...msg];

    socket.add(frame);
    await socket.flush().timeout(timeout, onTimeout: () {
      throw TimeoutException('sendMessage Socket write timed out', timeout);
    });
  }

  /// Asynchronous close a socket.
  ///
  /// Returns:
  ///   A Future<dynamic> object.
  Future<void> close() {
    return socket.close();
  }

  /// Receive a message with a socket wrapper.
  ///
  /// Parameters:
  /// - [socketwrapper]: The socket wrapper to use.
  /// - [timeout] (optional): The timeout duration.
  ///
  /// Returns:
  ///   A Future<List<int>> object.
  Future<List<int>> recvMessage({
    Duration? timeout,
  }) async {
    Utilities.debugPrint("START OF RECV2");
    // Use class-level timeout if no argument-level timeout is provided.
    timeout ??= this.timeout;

    // Calculate the absolute max time for this operation based on the timeout.
    final maxTime = DateTime.now().add(timeout);

    // Initialize a buffer to store received data.
    List<int> recvBuf = [];

    int? messageLength;

    try {
      // Loop to read incoming data from the socket.
      await for (List<int> data in receiveStream) {
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

        // Check if we've received enough bytes to start processing the header.
        if (recvBuf.length >= 12) {
          // Check if we've already read the message length.
          if (messageLength == null) {
            // No, so read the header to get the message length.
            Utilities.debugPrint(
                "DEBUG recv_message2 1 - about to read the header");
            // Extract and validate the magic bytes from the received data.
            final magic = recvBuf.sublist(0, 8);

            if (!magic.equals(Connection.magic)) {
              throw BadFrameError('Bad magic in frame: ${hex.encode(magic)}');
            }
            // Extract the message length from the received data.
            final byteData = ByteData.view(
                Uint8List.fromList(recvBuf.sublist(8, 12)).buffer);
            messageLength = byteData.getUint32(0, Endian.big);

            // Validate the message length.
            if (messageLength > MAX_MSG_LENGTH) {
              throw BadFrameError(
                  'Got a frame with msg_length=$messageLength > $MAX_MSG_LENGTH (max)');
            }
          }

          // Check if the entire message has been received.
          if (recvBuf.length == 12 + messageLength) {
            // Extract and return the received message.
            final message = recvBuf.sublist(12, 12 + messageLength);

            Utilities.debugPrint(
                "DEBUG recv_message2 4 - message received, length: ${message.length}");
            Utilities.debugPrint(
                "DEBUG recv_message2 5 - message content: $message");
            // Utilities.debugPrint(utf8.decode(message));
            Utilities.debugPrint("END OF RECV2");
            return message;
          } else if (recvBuf.length > 12 + messageLength) {
            // We've received more than the entire message, throw an exception.
            throw Exception(
              'Message length mismatch: expected $messageLength bytes, received ${recvBuf.length} bytes.',
            );
          }
        }
      }
    } catch (e, s) {
      // Handle any SocketExceptions that may occur.
      Utilities.debugPrint('recvMessage exception: $e\n$s');
      rethrow;
      // Disable this rethrow if it causes too many issues, previously we just printed the exception
    }

    throw Exception('recvMessage(): Should not reach this point');
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

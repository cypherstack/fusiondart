import 'dart:io';

class SocketWrapper {
  // Declare a late-initialized Socket object.
  Socket? _socket;

  // Server IP and port are passed as constructor parameters.
  final String serverIP;
  final int serverPort;

  // Declare a broadcast stream to handle incoming data.
  late Stream<List<int>>
      _receiveStream; // create a field for the broadcast stream.

  // Constructor to initialize serverIP and serverPort.
  SocketWrapper(this.serverIP, this.serverPort);

  // Getter to expose the underlying Socket object.
  Socket? get socket => _socket;

  // Getter to expose the broadcast stream.
  Stream<List<int>> get receiveStream =>
      _receiveStream; // expose the stream with a getter.

  // Asynchronously connect to the server.
  Future<void> connect() async {
    // Establish a connection to the server.
    _socket = await Socket.connect(serverIP, serverPort);

    // Initialize the broadcast stream for receiving data.
    if (_socket != null) {
      _receiveStream = _socket!.asBroadcastStream().cast<
          List<int>>(); // Explicitly cast the stream elements to List<int>
    }

    // Register an event handler for socket close event.
    await _socket?.done.then((_) {
      print('... Socket has been closed');
      // Override the socket with a null value.
      _socket = null;
    });

    // Register an error handler
    _socket?.handleError((error) {
      print('Socket error: $error');
      throw Exception('SocketWrapper.connect(): Socket error: $error');
    });
  }

  /// Print the connection status of the socket
  ///
  /// TODO return something or set a status value instead of printing
  ///
  /// Throws:
  ///   Exception: if the socket is not connected
  void status() {
    final _socket = this._socket;
    if (_socket != null) {
      print(
          "Socket connected to ${_socket.remoteAddress.address}:${_socket.remotePort}");
      // TODO return something or set a status value instead of printing
    } else {
      // print("SocketWrapper.status(): Socket is not connected");
      throw Exception('SocketWrapper.status(): Socket is not connected');
    }
  }

  /// Asynchronously send data over the socket
  ///
  /// Parameters:
  /// - [data]: a List<int> of data to send
  ///
  /// Returns:
  ///   A Future<void> that completes when the data is sent
  ///
  /// Throws:
  ///   Exception: if the socket is not connected
  Future<void> send(List<int> data) async {
    if (_socket != null) {
      // Add data to the socket and flush the buffer
      _socket?.add(data);
      await _socket?.flush();
    } else {
      throw Exception('SocketWrapper.send(): Socket is not connected');
      // TODO handle error when the socket is not connected.  Remove this throw if it causes issues
    }
  }

  /// Close the socket connection
  ///
  /// Returns:
  ///   A Future<void> that completes when the socket is closed
  Future<void> close() async {
    return _socket?.close();
  }
}

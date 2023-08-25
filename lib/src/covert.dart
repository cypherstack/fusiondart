import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fusiondart/src/comms.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:protobuf/protobuf.dart' as pb;
import 'package:protobuf/protobuf.dart';

const int TOR_COOLDOWN_TIME = 660;
const int TIMEOUT_INACTIVE_CONNECTION = 120;

class FusionError implements Exception {
  String cause;
  FusionError(this.cause);
}

class Unrecoverable extends FusionError {
  Unrecoverable(String cause) : super(cause);
}

/// Checks if a specific port on a host is running a Tor service.
///
/// This function tries to connect to a given a [host] and [port],
/// and then sends a "GET" request to check for the typical Tor error message.
/// This is a simple heuristic to identify Tor.
///
/// Returns:
///   A `Future` that resolves to `true` if the port appears to be running Tor,
///   and `false` otherwise.
Future<bool> isTorPort(String host, int port) async {
  // Validate the port range
  if (port < 0 || port > 65535) {
    return false;
  }

  try {
    // Attempt to connect to the host and port within a 100ms timeout.
    Socket sock =
        await Socket.connect(host, port, timeout: Duration(milliseconds: 100));

    // Send a "GET" request to trigger the server's response.
    sock.write("GET\n");

    // Wait for the first data packet from the server.
    List<int> data = await sock.first;

    // Destroy the socket as it's no longer needed.
    sock.destroy();

    // Decode the server's response and check if it contains the typical Tor error message.
    if (utf8.decode(data).contains("Tor is not an HTTP Proxy")) {
      return true;
    }
  } on SocketException {
    // Catch any SocketException that occurs (e.g., timeout, host unreachable)
    return false;
  }

  // Default return value if all the checks fail.
  return false;
}

/// A rate limiter for Tor connections.
///
/// This class maintains a queue of timestamps to keep track of the usage.
/// It cleans up the old timestamps and limits the usage based on a lifetime value.
class TorLimiter {
  Queue<DateTime> deque = Queue<DateTime>();
  int lifetime;

  // Internal count to track the number of operations.
  // Declare a lock here, may need a special Dart package for this... how about a mutex?
  int _count = 0;

  /// Constructor that initializes the limiter with a given [lifetime].
  TorLimiter(this.lifetime);

  /// Cleans up old timestamps from the queue.
  /// This method is currently not implemented.
  void cleanup() {}

  /// Getter for the current count of operations.
  ///
  /// For now, it returns a default value of zero.
  int get count {
    // return some default value for now
    return 0;
  }

  /// Increases the internal count.
  /// This method is currently not implemented.
  void bump() {}
}

// Placeholder for the value of TOR_COOLDOWN_TIME. Replace as necessary.
TorLimiter limiter = TorLimiter(TOR_COOLDOWN_TIME);

/// Generates a random number based on a trapezoidal distribution.
///
/// Uses a random number generator [rng].
double randTrap(Random rng) {
  final sixth = 1.0 / 6;
  final f = rng.nextDouble();
  final fc = 1.0 - f;

  if (f < sixth) {
    return sqrt(0.375 * f);
  } else if (fc < sixth) {
    return 1.0 - sqrt(0.375 * fc);
  } else {
    return 0.75 * f + 0.125;
  }
}

/// Represents a covert connection.
///
/// This class maintains state information for a covert connection, including ping times and delays.
class CovertConnection {
  Connection? connection;
  int? slotNum;
  DateTime? tPing;
  int? connNumber;
  Completer<bool> wakeup = Completer();
  double? delay;

  /// Waits for the connection to wake up or for a timeout.
  ///
  /// Waits until time at which the connection should wake up [t].
  Future<bool> waitWakeupOrTime(DateTime? t) async {
    if (t == null) {
      return false;
    }

    int remTime = t.difference(DateTime.now()).inMilliseconds;
    remTime = remTime > 0 ? remTime : 0;

    await Future.delayed(Duration(milliseconds: remTime));
    wakeup.complete(true);

    bool wasSet = await wakeup.future;
    wakeup = Completer();
    return wasSet;
  }

  /// Sends a ping message to keep the connection alive.
  void ping() {
    if (this.connection != null) {
      sendPb(this.connection!, CovertMessage, Ping(),
          timeout: Duration(seconds: 1));
    }

    tPing = null;
  }

  /// Indicates the connection is inactive and throws an unrecoverable error.
  ///
  /// This method is currently not implemented.
  void inactive() {
    throw Unrecoverable("Timed out from inactivity (this is a bug!)");
  }
}

/// Represents a slot in a covert communication setup.
///
/// This class maintains state information for work to be done in a given slot of a covert system.
class CovertSlot {
  int submitTimeout;
  pb.GeneratedMessage? subMsg; // The work to be done.
  bool done; // Whether last work requested is done.
  CovertConnection?
      covConn; // which CovertConnection is assigned to work on this slot.

  /// Constructor that initializes the covert slot with a given submission timeout.
  CovertSlot(this.submitTimeout) : done = true;
  DateTime? t_submit;

  /// Getter for the time of the last submit action.
  DateTime? get tSubmit => t_submit;

  /// Submits the work to be done within the slot.
  ///
  /// This method is responsible for sending a message for the work to be
  /// performed, waiting for a response, and then setting the state accordingly.
  Future<void> submit() async {
    // Attempt to get the connection object from the covert connection.
    Connection? connection = covConn?.connection;

    // Throw an unrecoverable exception if the connection is null.
    if (connection == null) {
      throw Unrecoverable('connection is null');
    }

    // Send a Protocol Buffers message to initiate the work,
    // and set a timeout based on the submitTimeout property.
    await sendPb(connection, CovertMessage, subMsg!,
        timeout: Duration(seconds: submitTimeout));

    // Receive a Protocol Buffers message as a response.
    (GeneratedMessage, String) result = await recvPb(
        connection, CovertResponse, ['ok', 'error'],
        timeout: Duration(seconds: submitTimeout));

    // TODO make a valid error check
    // This should throw an unrecoverable exception if an error is received, but
    // isn't a valid check.
    if (result.$1 == 'error') {
      throw Unrecoverable('error from server: ${result.$2}');
    }

    // Set the done flag to true to indicate that the work has been completed.
    done = true;

    // Update the time of the last submit action.
    t_submit = DateTime.fromMillisecondsSinceEpoch(0);

    // Reset the ping time for the associated covert connection.
    // If a submission has been successfully made, no ping is needed.
    covConn?.tPing = DateTime.fromMillisecondsSinceEpoch(
        0); // if a submission is done, no ping is needed.
  }
}

class PrintError {
  // Declare properties here
}

class CovertSubmitter extends PrintError {
  // Declare properties here
  List<CovertSlot> slots;
  bool done = true;
  String failure_exception = "";
  int num_slots;

  bool stopping = false;
  Map<String, dynamic>? proxyOpts;
  String? randtag;
  String? destAddr;
  int? destPort;
  bool ssl = false;
  Object lock = Object();
  int countFailed = 0;
  int countEstablished = 0;
  int countAttempted = 0;
  Random rng = Random.secure();
  int? randSpan;
  DateTime? stopTStart;
  List<CovertConnection> spareConnections = [];
  String? failureException;
  int submit_timeout = 0;

  CovertSubmitter(
      String dest_addr,
      int dest_port,
      bool ssl,
      String tor_host,
      int tor_port,
      this.num_slots,
      double randSpan, // changed from int to double
      double submit_timeout) // changed from int to double
      : slots = List<CovertSlot>.generate(
            num_slots, (index) => CovertSlot(submit_timeout.toInt())) {
    // constructor body...
  }

  void wakeAll() {
    for (CovertSlot s in slots) {
      if (s.covConn != null) {
        s.covConn!.wakeup.complete();
      }
    }
    for (CovertConnection c in spareConnections) {
      c.wakeup.complete();
    }
  }

  void setStopTime(int tstart) {
    stopTStart = DateTime.fromMillisecondsSinceEpoch(tstart * 1000);
    if (stopping) {
      wakeAll();
    }
  }

  void stop([Exception? exception]) {
    if (stopping) {
      // already requested!
      return;
    }
    failureException = exception?.toString();
    stopping = true;
    var timeRemaining = stopTStart?.difference(DateTime.now()).inSeconds ?? 0;
    print(
        "Stopping; connections will close in approximately $timeRemaining seconds");
    wakeAll();
  }

// PYTHON USES MULTITHREADING, WHICH ISNT IMPLEMENTED HERE YET
  void scheduleConnections(DateTime tStart, Duration tSpan,
      {int numSpares = 0, int connectTimeout = 10}) {
    List<CovertConnection> newConns = <CovertConnection>[];

    for (int sNum = 0; sNum < slots.length; sNum++) {
      CovertSlot s = slots[sNum];
      if (s.covConn == null) {
        s.covConn = CovertConnection();
        s.covConn?.slotNum = sNum;
        CovertConnection? myCovConn = s.covConn;
        if (myCovConn != null) {
          newConns.add(myCovConn);
        }
      }
    }

    int numNewSpares = max(0, numSpares - spareConnections.length);
    List<CovertConnection> newSpares =
        List.generate(numNewSpares, (index) => CovertConnection());
    spareConnections = [...newSpares, ...spareConnections];

    newConns.addAll(newSpares);

    for (CovertConnection covConn in newConns) {
      covConn.connNumber = countAttempted;
      countAttempted++;
      DateTime connTime = tStart
          .add(Duration(seconds: (tSpan.inSeconds * randTrap(rng)).round()));
      double randDelay = (randSpan ?? 0) * randTrap(rng);

      runConnection(
          covConn, connTime.millisecondsSinceEpoch, randDelay, connectTimeout);
    }
  }

  void scheduleSubmit(
      int slotNum, DateTime tStart, pb.GeneratedMessage subMsg) {
    CovertSlot slot = slots[slotNum];

    assert(slot.done, "tried to set new work when prior work not done");

    slot.subMsg = subMsg;
    slot.done = false;
    slot.t_submit = tStart;
    CovertConnection? covConn = slot.covConn;
    if (covConn != null) {
      covConn.wakeup.complete();
    }
  }

  void scheduleSubmissions(DateTime tStart, List<dynamic> slotMessages) {
    // Convert to list (Dart does not have tuples)
    slotMessages = List.from(slotMessages);

    // Ensure that the number of slot messages equals the number of slots
    assert(slotMessages.length == slots.length);

    // First, notify the spare connections that they will need to make a ping.
    // Note that Dart does not require making a copy of the list before iteration,
    // since Dart does not support mutation during iteration.
    for (CovertConnection c in spareConnections) {
      c.tPing = tStart;
      c.wakeup.complete();
    }

    // Then, notify the slots that there is a message to submit.
    for (int i = 0; i < slots.length; i++) {
      CovertSlot slot = slots[i];
      GeneratedMessage? subMsg = slotMessages[i] as pb.GeneratedMessage;
      CovertConnection covConn = slot.covConn as CovertConnection;

      if (covConn != null) {
        if (subMsg == null) {
          covConn.tPing = tStart;
        } else {
          slot.subMsg = subMsg;
          slot.done = false;
          slot.t_submit = tStart;
        }
        covConn.wakeup.complete();
      }
    }
  }

  Future runConnection(CovertConnection covConn, int connTime, double randDelay,
      int connectTimeout) async {
    // Main loop for connection thread
    DateTime connDateTime =
        DateTime.fromMillisecondsSinceEpoch(connTime * 1000);
    while (await covConn.waitWakeupOrTime(connDateTime)) {
      // if we are woken up before connection and stopping is happening, then just don't make a connection at all
      if (this.stopping) {
        return;
      }

      final tBegin = DateTime.now().millisecondsSinceEpoch;

      try {
        // STATE 1 - connecting
        Map<String, dynamic> proxyOpts;

        if (this.proxyOpts == null) {
          proxyOpts = {};
        } else {
          final unique = 'CF${this.randtag}_${covConn.connNumber}';
          proxyOpts = {
            'proxy_username': unique,
            'proxy_password': unique,
          };
          proxyOpts.addAll(this.proxyOpts!);
        }

        limiter.bump();

        try {
          final connection = await openConnection(
              this.destAddr!, this.destPort!,
              connTimeout: connectTimeout.toDouble(),
              ssl: this.ssl,
              socksOpts: proxyOpts);
          covConn.connection = connection;
        } catch (e) {
          this.countFailed++;

          final tEnd = DateTime.now().millisecondsSinceEpoch;

          print(
              'could not establish connection (after ${((tEnd - tBegin) / 1000).toStringAsFixed(3)}s): $e');
          rethrow;
        }

        this.countEstablished++;

        final tEnd = DateTime.now().millisecondsSinceEpoch;

        print(
            '[${covConn.connNumber}] connection established after ${((tEnd - tBegin) / 1000).toStringAsFixed(3)}s');

        covConn.delay = (randTrap(this.rng) ?? 0) * (this.randSpan ?? 0);

        int lastActionTime = DateTime.now().millisecondsSinceEpoch;

        // STATE 2 - working
        while (!this.stopping) {
          DateTime? nextTime;
          final slotNum = covConn.slotNum;
          Function()? action; // callback to hold the action function

          // Second preference: submit something
          if (slotNum != null) {
            CovertSlot slot = this.slots[slotNum];
            nextTime = slot.tSubmit;
            action = slot.submit;
          }
          // Third preference: send a ping
          if (nextTime == null && covConn.tPing != null) {
            nextTime = covConn.tPing;
            action = covConn.ping;
          }
          // Last preference: wait doing nothing
          if (nextTime == null) {
            nextTime = DateTime.now()
                .add(Duration(seconds: TIMEOUT_INACTIVE_CONNECTION));
            action = covConn.inactive;
          }

          nextTime = nextTime.add(Duration(seconds: randDelay.toInt()));

          if (await covConn.waitWakeupOrTime(nextTime)) {
            // got woken up ... let's go back and reevaluate what to do
            continue;
          }

          // reached action time, time to do it
          final label = "[${covConn.connNumber}-$slotNum]";
          try {
            await action?.call();
          } catch (e) {
            print("$label error $e");
            rethrow;
          } finally {
            print("$label done");
          }

          lastActionTime = DateTime.now().millisecondsSinceEpoch;
        }

        // STATE 3 - stopping
        while (true) {
          final stopTime =
              this.stopTStart?.add(Duration(seconds: randDelay.toInt())) ??
                  DateTime.now();

          if (!(await covConn.waitWakeupOrTime(stopTime))) {
            break;
          }
        }

        print("[${covConn.connNumber}] closing from stop");
      } catch (e) {
        // in case of any problem, record the exception and if we have a slot, reassign it.
        final exception = e;

        final slotNum = covConn.slotNum;
        if (slotNum != null) {
          try {
            final spare = this.spareConnections.removeLast();
            // Found a spare.
            this.slots[slotNum].covConn = spare;
            spare.slotNum = slotNum;
            spare.wakeup
                .complete(); // python code is using set, possibly dealing wiht multi thread...double check this is ok.

            covConn.slotNum = null;
          } catch (e) {
            // We failed, and there are no spares. Party is over!

            if (exception is Exception) {
              this.stop(exception);
            } else {
              // Handle the case where the exception is not an instance of Exception
            }
          }
        }
      } finally {
        covConn.connection?.close();
      }
    }
  }

  void checkOk() {
    // Implement checkOk logic here
    var e = failure_exception;
    if (e != null) {
      throw FusionError('Covert connections failed: ${e.runtimeType} $e');
    }
  }

  void checkConnected() {
    // Implement checkConnected logic here
    checkOk();
    var numMissing = slots.where((s) => s.covConn?.connection == null).length;
    if (numMissing > 0) {
      throw FusionError(
          "Covert connections were too slow ($numMissing incomplete out of ${slots.length}).");
    }
  }

  void checkDone() {
    // Implement checkDone logic here
    this.checkOk();
    int numMissing = slots.where((s) => !s.done).length;
    if (numMissing > 0) {
      throw FusionError(
          "Covert submissions were too slow ($numMissing incomplete out of ${slots.length}).");
    }
  }
}

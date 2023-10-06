import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fusiondart/src/comms.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/util.dart';
import 'package:protobuf/protobuf.dart' as pb;
import 'package:protobuf/protobuf.dart';

import 'exceptions.dart';

// Cool down time for Tor connections, in seconds.
const int torCoolDownTime = 660;

// Timeout for inactive connections, in seconds.
const int TIMEOUT_INACTIVE_CONNECTION = 120;

/// Represents a covert connection.
class CovertConnection {
  Connection? connection;
  int? slotNum;
  DateTime? tPing;
  int? connNumber;
  Completer<bool> wakeup = Completer();
  double? delay;

  /// Waits for the connection to wake up or for a timeout.
  Future<bool> waitWakeupOrTime(DateTime? t) async {
    // Check `t`'s validity.
    if (t == null) {
      return false;
    }

    // Calculate the remaining time until `t`.
    int remTime = t.difference(DateTime.now()).inMilliseconds;
    remTime = remTime > 0 ? remTime : 0;

    // wait for the first one of the following futures to complete
    await Future.any([
      Future<void>.delayed(Duration(milliseconds: remTime)).then((_) {
        if (!wakeup.isCompleted) {
          wakeup.complete(true);
        }
      }),
      wakeup.future,
    ]);

    // Return whether the connection was woken up.
    final wasSet = await wakeup.future;
    wakeup = Completer();
    return wasSet;
  }

  /// Sends a ping message to keep the connection alive.
  void ping() {
    // If the connection exists, send a `Ping` message.
    if (connection != null) {
      Comms.sendPb(
        connection!,
        CovertMessage()..ping = Ping(),
        timeout: Duration(seconds: 1),
      );
    }

    // Reset the ping time, as a ping has just been sent.
    tPing = null;
  }

  /// Indicates the connection is inactive and throws an unrecoverable error.
  void inactive() {
    throw Unrecoverable("Timed out from inactivity (this is a bug!)");
  }
}

/// Represents a slot in a covert communication setup.
class CovertSlot {
  /// Constructor that initializes the covert slot with a given submission timeout.
  CovertSlot(this.submitTimeout) : done = true;

  final Duration submitTimeout;
  bool done; // Whether last work requested is done.

  pb.GeneratedMessage? subMsg; // The work to be done.
  CovertConnection?
      covConn; // which CovertConnection is assigned to work on this slot.
  DateTime? _tSubmit;

  /// Getter for the time of the last submit action.
  DateTime? get tSubmit => _tSubmit;

  /// Submits the work to be done within the slot.
  Future<void> submit() async {
    // Attempt to get the connection object from the covert connection.
    Connection? connection = covConn!.connection;

    // Throw an unrecoverable exception if the connection is null.
    if (connection == null) {
      throw Unrecoverable('connection is null');
    }

    // TODO: this is probably not the right way to handle this?
    final message = CovertMessage();
    switch (subMsg!.runtimeType) {
      case CovertComponent:
        message.component = subMsg as CovertComponent;
      case CovertTransactionSignature:
        message.signature = subMsg as CovertTransactionSignature;
      case Ping:
        message.ping = subMsg as Ping;

      default:
        throw Exception("CTRL+F this error text and see TODO message");
    }

    // Start the work.
    //
    // Send a Protocol Buffers message to initiate the work,
    // and set a timeout based on the submitTimeout property.
    await Comms.sendPb(connection, message, timeout: submitTimeout);

    // throws on error ( aka if not 'ok' )
    await Comms.recvPb(
      ['ok'],
      connection: connection,
      covert: true,
      timeout: submitTimeout,
    );

    // Set the done flag to true to indicate that the work has been completed.
    done = true;

    _tSubmit = null;

    // Reset the ping time for the associated covert connection.
    // If a submission has been successfully made, no ping is needed.
    covConn!.tPing = null; // if a submission is done, no ping is needed.
  }
}

/// Manages submission of covert tasks.
///
/// This class manages the submission of covert tasks to a server.
class CovertSubmitter {
  final String destAddr;
  final int destPort;
  final bool ssl;
  final ({InternetAddress host, int port}) proxyInfo;
  final int numSlots;
  final int randSpan;
  final int submitTimeout = 0;

  /// A list of slots that can take covert tasks.
  final List<CovertSlot> slots;

  /// More instance variables.
  String? failureException;
  bool stopping = false;
  String? randTag;
  int countFailed = 0;
  int countEstablished = 0;
  int countAttempted = 0;
  final Random rng = Random.secure();
  DateTime? stopTStart;
  List<CovertConnection> spareConnections = [];

  /// Constructor to initialize the CovertSubmitter.
  CovertSubmitter({
    required this.destAddr,
    required this.destPort,
    required this.ssl,
    required this.proxyInfo,
    required this.numSlots,
    required this.randSpan,
    required Duration submitTimeout,
  }) : slots = List<CovertSlot>.generate(
            numSlots, (index) => CovertSlot(submitTimeout));

  /// Wakes all connections for tasks.
  ///
  /// Returns:
  ///  `void`
  void wakeAll() {
    // Wake up all the connections.
    for (CovertSlot s in slots) {
      if (s.covConn != null) {
        // Wake up the connection associated with the slot.
        s.covConn!.wakeup
            .complete(true); // TODO make sure passing `true` is correct
      }
    }

    // Wake up all the spare connections, too.
    for (CovertConnection c in spareConnections) {
      c.wakeup.complete(true); // TODO make sure passing `true` is correct
    }
  }

  /// Sets the time to stop all tasks.
  void setStopTime(int tStart) {
    // Set the time at which to stop.
    stopTStart = DateTime.fromMillisecondsSinceEpoch(tStart * 1000);

    // Wake up all the connections.
    if (stopping) {
      wakeAll();
    }
  }

  /// Stops all tasks and closes the connections.
  void stop([Exception? exception]) {
    if (stopping) {
      // Already requested!
      return;
    }
    failureException = exception?.toString();
    stopping = true;

    // Calculate the time remaining until the stop time.
    var timeRemaining = stopTStart?.difference(DateTime.now()).inSeconds ?? 0;
    Utilities.debugPrint(
        "Stopping; connections will close in approximately $timeRemaining seconds");

    // Wake up all the connections.
    wakeAll();
  }

  /// Schedules connections for tasks and runs them unawaited.
  ///
  /// TODO implement multithreading, which ElectronCash does in Python
  void scheduleConnectionsAndStartRunningThem(
    DateTime tStart,
    Duration tSpan, {
    int numSpares = 0,
    Duration connectTimeout = const Duration(seconds: 10),
  }) {
    // Prepare the list to store new connections.
    List<CovertConnection> newConns = <CovertConnection>[];

    // Loop through each slot and initialize a new covert connection if none exists for that slot.
    for (int sNum = 0; sNum < slots.length; sNum++) {
      CovertSlot s = slots[sNum];
      if (s.covConn == null) {
        // Initialize a new covert connection and associate it with the slot.
        s.covConn = CovertConnection()..slotNum = sNum;

        // Add the new connection to the list of new connections.
        newConns.add(s.covConn!);
      }
    }

    // Calculate the number of new spare connections needed.
    int numNewSpares = max(0, numSpares - spareConnections.length);

    // Create new spare connections.
    List<CovertConnection> newSpares =
        List.generate(numNewSpares, (index) => CovertConnection());

    // Update the list of spare connections.
    spareConnections = [...newSpares, ...spareConnections];

    // Add new spare connections to the list of new connections.
    newConns.addAll(newSpares);

    // Holds all the runConnection futures in case we want to return them at some
    // point. For now they are run unawaited.
    final List<Future<void>> runConnectionFutures = [];

    // Loop through each new connection to schedule it.
    for (CovertConnection covConn in newConns) {
      // Assign a unique connection number for tracking.
      covConn.connNumber = countAttempted;

      // Increment the total number of attempted connections.
      countAttempted++;

      // Calculate the specific DateTime to establish this connection.
      DateTime connTime = tStart
          .add(Duration(seconds: (tSpan.inSeconds * randTrap(rng)).round()));

      // Calculate a random delay to add to the connection time.
      final randDelay = Duration(seconds: (randSpan * randTrap(rng).toInt()));

      // Invoke the method to initiate and run the connection unawaited.
      runConnectionFutures.add(
        _runConnection(
          covConn,
          connTime.millisecondsSinceEpoch,
          randDelay,
          connectTimeout,
        ),
      );
    }
  }

  /// Schedules a task to be submitted.
  ///
  /// This method schedules a submission or ping task for the specified covert slot.
  void scheduleSubmit(
      int slotNum, DateTime tStart, pb.GeneratedMessage subMsg) {
    // Get the covert slot for the specified slot number.
    CovertSlot slot = slots[slotNum];

    // Ensure that the slot is done before setting new work.
    assert(slot.done, "tried to set new work when prior work not done");

    // Set the work to be done and update the time of the last submit action.
    slot.subMsg = subMsg;
    slot.done = false;
    slot._tSubmit = tStart;
    CovertConnection? covConn = slot.covConn;
    if (covConn != null) {
      // Wake up the connection associated with the slot.
      covConn.wakeup.complete(true); // TODO make sure passing `true` is correct
    }
  }

  /// Schedules tasks for all available slots.
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
      c.wakeup.complete(true); // TODO make sure passing `true` is correct
    }

    // Then, notify the slots that there is a message to submit.
    for (int i = 0; i < slots.length; i++) {
      CovertSlot slot = slots[i];
      GeneratedMessage? subMsg = slotMessages[i] as pb.GeneratedMessage;
      CovertConnection covConn = slot.covConn as CovertConnection;

      /*if (covConn != null) {
        if (subMsg == null) {
          covConn.tPing = tStart;
        } else {*/
      slot.subMsg = subMsg;
      slot.done = false;
      slot._tSubmit = tStart;
      /*}*/
      covConn.wakeup.complete(true); // TODO make sure passing `true` is correct
      /*}*/
    }
  }

  /// Runs a connection thread for the provided covert connection.
  Future<void> _runConnection(
    CovertConnection covConn,
    int connTime,
    Duration randDelay,
    Duration connectTimeout,
  ) async {
    // Main loop for connection thread
    DateTime connDateTime =
        DateTime.fromMillisecondsSinceEpoch(connTime * 1000);
    while (await covConn.waitWakeupOrTime(connDateTime)) {
      // if we are woken up before connection and stopping is happening, then just don't make a connection at all
      if (stopping) {
        return;
      }

      // Note the time at which the connection was established.
      final tBegin = DateTime.now().millisecondsSinceEpoch;

      try {
        // STATE 1 - connecting
        // Increment the total number of attempted connections.
        limiter.bump();

        // Attempt to open a connection.
        try {
          final connection = await Connection.openConnection(
            host: destAddr,
            port: destPort,
            connTimeout: connectTimeout,
            ssl: ssl,
            proxyInfo: proxyInfo,
          );
          covConn.connection = connection;
        } catch (e) {
          // Connection failed.

          // Increment the total number of failed connections.
          countFailed++;

          // Note the time at which the connection failed.
          final tEnd = DateTime.now().millisecondsSinceEpoch;

          Utilities.debugPrint(
              'could not establish connection (after ${((tEnd - tBegin) / 1000).toStringAsFixed(3)}s): $e');
          rethrow;
        }

        // Connection succeeded.

        // Increment the total number of established connections.
        countEstablished++;

        // Note the time at which the connection was established.
        final tEnd = DateTime.now().millisecondsSinceEpoch;
        Utilities.debugPrint(
            '[${covConn.connNumber}] connection established after ${((tEnd - tBegin) / 1000).toStringAsFixed(3)}s');

        // Set the ping time for the connection.
        covConn.delay = randTrap(rng) * (randSpan ?? 1);

        // Note the time at which the ping was sent.
        int lastActionTime = DateTime.now().millisecondsSinceEpoch;

        // STATE 2 - Working.
        while (!stopping) {
          DateTime? nextTime;
          final slotNum = covConn.slotNum;
          Function? action; // Callback to hold the action function.

          // Second preference: submit something.
          if (slotNum != null) {
            CovertSlot slot = slots[slotNum];
            nextTime = slot.tSubmit;
            action = slot.submit;
          }
          // Third preference: send a ping.
          if (nextTime == null && covConn.tPing != null) {
            nextTime = covConn.tPing;
            action = covConn.ping;
          }
          // Last preference: wait doing nothing.
          if (nextTime == null) {
            nextTime = DateTime.now()
                .add(Duration(seconds: TIMEOUT_INACTIVE_CONNECTION));
            action = covConn.inactive;
          }

          // Add a random delay to the next time.
          nextTime = nextTime.add(randDelay);

          // Wait until the next time.
          if (await covConn.waitWakeupOrTime(nextTime)) {
            // Got woken up...  Let's go back and reevaluate what to do.
            continue;
          }

          // Reached action time, time to do it.
          final label = "[${covConn.connNumber}-$slotNum]";

          // Call the action function.
          try {
            await action?.call();
          } catch (e) {
            Utilities.debugPrint("$label error $e");
            rethrow;
          } finally {
            Utilities.debugPrint("$label done");
          }

          // Note the time at which the action was completed.
          lastActionTime = DateTime.now().millisecondsSinceEpoch;
        }

        // STATE 3 - Stopping.
        while (true) {
          // Wait for the stop time or the next wakeup.
          final stopTime = stopTStart?.add(randDelay) ?? DateTime.now();

          // If we are woken up before the stop time, then just don't make a connection at all.
          if (!(await covConn.waitWakeupOrTime(stopTime))) {
            break;
          }
        }

        Utilities.debugPrint("[${covConn.connNumber}] closing from stop");
      } catch (e) {
        // In case of any problem, if we have a slot, reassign it.
        final slotNum = covConn.slotNum;
        if (slotNum != null) {
          try {
            final spare = spareConnections.removeLast();
            // Found a spare.
            slots[slotNum].covConn = spare;
            spare.slotNum = slotNum;
            spare.wakeup
                .complete(true); // TODO make sure passing `true` is correct.
            // TODO Python code is using set, possibly dealing with multi thread... Double check this is ok.

            // Clear the slot number for the connection.
            covConn.slotNum = null;
          } catch (e) {
            // We failed, and there are no spares.  Party is over!

            if (e is Exception) {
              // Stop the covert submitter with the exception.
              stop(e);
            } else {
              // Handle the case where the exception is not an instance of Exception.
              stop(Exception("runConnection exception: $e"));
            }
          }
        }
      } finally {
        // Close the connection.
        await covConn.connection?.close();
      }
    }
  }

  /// Checks for any failure exceptions and throws them if they exist.
  void checkOk() {
    var e = failureException;
    if (e != null) {
      throw FusionError('Covert connections failed: ${e.runtimeType} $e');
    }
  }

  /// Verifies all slots are connected.
  void checkConnected() {
    checkOk();
    var numMissing = slots.where((s) => s.covConn?.connection == null).length;
    if (numMissing > 0) {
      // throw FusionError(
      //     "Covert connections were too slow ($numMissing incomplete out of ${slots.length}).");
      Utilities.debugPrint(
          "Covert connections were too slow ($numMissing incomplete out of ${slots.length}).  TODO re-enable throw.");
    }
  }

  /// Verifies all submissions are done.
  void checkDone() {
    checkOk();
    int numMissing = slots.where((s) => !s.done).length;
    if (numMissing > 0) {
      // throw FusionError(
      //     "Covert submissions were too slow ($numMissing incomplete out of ${slots.length}).");
      Utilities.debugPrint(
          "Covert submissions were too slow ($numMissing incomplete out of ${slots.length}).  TODO re-enable throw.");
    }
  }
}

/// Checks if a specific port on a host is running a Tor service.
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
class TorLimiter {
  Queue<DateTime> deque = Queue<DateTime>();
  int lifetime;

  /// Internal count to track the number of operations.
  // Declare a lock here, may need a special Dart package for this... how about a mutex?
  int _count = 0;

  /// Getter for the current count of operations.
  int get count {
    return _count;
  }

  /// Constructor that initializes the limiter with a given [lifetime].
  TorLimiter(this.lifetime);

  /// Cleans up old timestamps from the queue.
  /// This method is currently not implemented.
  void cleanup() {}

  /// Increases the internal count.
  void bump() {
    _count++;
    // TODO decrement the count after disconnection.
  }
}

// Placeholder for the value of TOR_COOLDOWN_TIME. Replace as necessary.
TorLimiter limiter = TorLimiter(torCoolDownTime);

/// Generates a random number based on a trapezoidal distribution.
double randTrap(Random rng) {
  // Define a constant for one-sixth, which we'll use for comparisons.
  final sixth = 1.0 / 6;

  // Generate a random double between 0 and 1.
  final f = rng.nextDouble();

  // Calculate the complement of the random double.
  final fc = 1.0 - f;

  if (f < sixth) {
    // Check if the random number falls within the first one-sixth of the range.
    //
    // Calculate using the formula for the left trapezoid.
    return sqrt(0.375 * f);
  } else if (fc < sixth) {
    // Check if the random number's complement falls within the first one-sixth of the range.
    //
    // Calculate using the formula for the right trapezoid.
    return 1.0 - sqrt(0.375 * fc);
  } else {
    // For all other cases, falling within the middle trapezoid.
    //
    // Calculate using the formula for the middle trapezoid.
    return 0.75 * f + 0.125;
  }
}

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

// Cool down time for Tor connections, in seconds.
const int torCoolDownTime = 660;

// Timeout for inactive connections, in seconds.
const int TIMEOUT_INACTIVE_CONNECTION = 120;

/// Represents a covert connection.
///
/// This class maintains state information for a covert connection, including ping times and delays.
///
/// Attributes:
/// - [connection]: The Connection object for the covert connection.
/// - [slotNum]: The slot number for the covert connection.
/// - [tPing]: The time of the last ping.
/// - [connNumber]: The connection number.
/// - [delay] (optional): The delay for the connection.
class CovertConnection {
  Connection? connection;
  int? slotNum;
  DateTime? tPing;
  int? connNumber;
  Completer<bool> wakeup = Completer();
  double? delay;

  /// Waits for the connection to wake up or for a timeout.
  ///
  /// This method waits for the connection to become active again
  /// based on the given DateTime [t] or times out if [t] is null.
  ///
  /// Parameters:
  /// - [t]: The DateTime object representing the time to wait until.
  ///
  /// Returns:
  ///   A `Future<bool>` which resolves to `true` if the connection woke up;
  ///   otherwise, `false`.
  Future<bool> waitWakeupOrTime(DateTime? t) async {
    // Check `t`'s validity.
    if (t == null) {
      return false;
    }

    // Calculate the remaining time until `t`.
    int remTime = t.difference(DateTime.now()).inMilliseconds;
    remTime = remTime > 0 ? remTime : 0;

    // Wait for the connection to wake up or for the timeout to occur.
    await Future<void>.delayed(Duration(milliseconds: remTime));
    wakeup.complete(true);

    // Return whether the connection was woken up.
    bool wasSet = await wakeup.future;
    wakeup = Completer();
    return wasSet;
  }

  /// Sends a ping message to keep the connection alive.
  ///
  /// This method sends a 'Ping' message to the server to keep the connection
  /// active. It is called at intervals to ensure that the connection doesn't time out.
  ///
  /// Returns:
  ///   `void`
  void ping() {
    // If the connection exists, send a `Ping` message.
    if (connection != null) {
      sendPb(connection!, CovertMessage, Ping(), timeout: Duration(seconds: 1));
    }

    // Reset the ping time, as a ping has just been sent.
    tPing = null;
  }

  /// Indicates the connection is inactive and throws an unrecoverable error.
  ///
  /// This method is currently not implemented.
  ///
  /// TODO implement.
  void inactive() {
    throw Unrecoverable("Timed out from inactivity (this is a bug!)");
  }
}

/// Represents a slot in a covert communication setup.
///
/// This class maintains state information for work to be done in a given slot of a covert system.
///
/// Attributes:
/// - [submitTimeout]: The timeout for submitting work.
/// - [subMsg]: The work to be done.
/// - [done]: Whether the work is done.
/// - [covConn] (optional): The CovertConnection object associated with the slot.
/// - [_tSubmit] (optional): The time of the last submit action.
class CovertSlot {
  int submitTimeout;
  pb.GeneratedMessage? subMsg; // The work to be done.
  bool done; // Whether last work requested is done.
  CovertConnection?
      covConn; // which CovertConnection is assigned to work on this slot.

  /// Constructor that initializes the covert slot with a given submission timeout.
  CovertSlot(this.submitTimeout) : done = true;
  DateTime? _tSubmit;

  /// Getter for the time of the last submit action.
  DateTime? get tSubmit => _tSubmit;

  /// Submits the work to be done within the slot.
  ///
  /// This method is responsible for sending a message for the work to be
  /// performed, waiting for a response, and then setting the state accordingly.
  ///
  /// Returns:
  ///  A `Future<void>` whose resolution represents completion.
  ///
  /// Throws:
  /// - Unrecoverable: if the connection is null.
  Future<void> submit() async {
    // Attempt to get the connection object from the covert connection.
    Connection? connection = covConn?.connection;

    // Throw an unrecoverable exception if the connection is null.
    if (connection == null) {
      throw Unrecoverable('connection is null');
    }

    // Start the work.
    //
    // Send a Protocol Buffers message to initiate the work,
    // and set a timeout based on the submitTimeout property.
    await sendPb(connection, CovertMessage, subMsg!,
        timeout: Duration(seconds: submitTimeout));

    // Receive a Protocol Buffers message as a response.
    (GeneratedMessage, String) result = await recvPb(
        connection, CovertResponse, ['ok', 'error'],
        timeout: Duration(seconds: submitTimeout));

    // TODO make sure this is a valid error check
    if (result.$1.toString() == 'error') {
      throw Unrecoverable('error from server: ${result.$2}');
    }

    // Set the done flag to true to indicate that the work has been completed.
    done = true;

    // Update the time of the last submit action.
    _tSubmit = DateTime.fromMillisecondsSinceEpoch(0);

    // Reset the ping time for the associated covert connection.
    // If a submission has been successfully made, no ping is needed.
    covConn?.tPing = DateTime.fromMillisecondsSinceEpoch(
        0); // if a submission is done, no ping is needed.
  }
}

/// Class to handle errors related to printing.
class PrintError {
  // Declare properties here
}

/// Manages submission of covert tasks.
///
/// This class manages the submission of covert tasks to a server.
///
/// Attributes:
/// - [slots]: A list of slots that can take covert tasks.
/// - [numSlots]: The number of covert slots to use.
/// - [failureException] (optional): The exception that caused the stop.
/// - [proxyOpts] (optional): The proxy options for the covert communication.
/// - [randTag] (optional): The random tag for the covert communication.
/// - [destAddr] (optional): The destination address for the covert communication.
/// - [destPort] (optional): The destination port for the covert communication.
/// - [rng] (optional): The random number generator for the covert communication.
/// - [randSpan] (optional): The random span for the covert communication.
/// - [stopTStart] (optional): The start time for stopping in seconds since epoch.
class CovertSubmitter extends PrintError {
  /// A list of slots that can take covert tasks.
  List<CovertSlot> slots;
  bool done = true;
  int numSlots;
  String? failureException;

  bool stopping = false;
  Map<String, dynamic>? proxyOpts;
  String? randTag;
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
  int submitTimeout = 0;

  /// Constructor to initialize the CovertSubmitter.
  ///
  /// Parameters:
  /// - [destAddr]: The destination address for the covert communication.
  /// - [destPort]: The destination port for the covert communication.
  /// - [ssl]: Whether to use SSL for the covert communication.
  /// - [torHost]: The host address for the Tor proxy.
  /// - [torPort]: The port for the Tor proxy.
  /// - [numSlots]: The number of covert slots to use.
  /// - [randSpan]: The random span for the covert communication.
  /// - [submitTimeout]: The timeout for submitting tasks.
  CovertSubmitter(
      String destAddr,
      int destPort,
      bool ssl,
      String torHost,
      int torPort,
      this.numSlots,
      double randSpan, // Changed from `int` to `double`.
      double submitTimeout) // Changed from `int` to `double`.
      : slots = List<CovertSlot>.generate(
            numSlots, (index) => CovertSlot(submitTimeout.toInt()));

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
  ///
  /// Parameters:
  ///  - [tStart]: The start time for stopping in seconds since epoch.
  ///
  /// Returns:
  ///  `void`
  void setStopTime(int tStart) {
    // Set the time at which to stop.
    stopTStart = DateTime.fromMillisecondsSinceEpoch(tStart * 1000);

    // Wake up all the connections.
    if (stopping) {
      wakeAll();
    }
  }

  /// Stops all tasks and closes the connections.
  ///
  /// Parameters:
  ///   - [exception] (optional): The exception that caused the stop.
  ///
  /// Returns:
  ///  `void`
  void stop([Exception? exception]) {
    if (stopping) {
      // Already requested!
      return;
    }
    failureException = exception?.toString();
    stopping = true;

    // Calculate the time remaining until the stop time.
    var timeRemaining = stopTStart?.difference(DateTime.now()).inSeconds ?? 0;
    print(
        "Stopping; connections will close in approximately $timeRemaining seconds");

    // Wake up all the connections.
    wakeAll();
  }

  /// Schedules connections for tasks.
  ///
  /// This method is responsible for scheduling the connections required for covert communication.
  /// It prepares connections needed for each covert slot, as well as handling spare connections that might be used later.
  /// TODO implement multithreading, which ElectronCash does in Python
  ///
  /// Parameters:
  /// - [tStart]: The DateTime object representing the start time for scheduling.
  /// - [tSpan]: The Duration object representing the time span within which to schedule the connections.
  /// - [numSpares] (optional): The number of spare connections to maintain. Default is 0.
  /// - [connectTimeout] (optional): The timeout duration for connections in seconds. Default is 10 seconds.
  ///
  /// Returns:
  ///  `void`
  void scheduleConnections(DateTime tStart, Duration tSpan,
      {int numSpares = 0, int connectTimeout = 10}) {
    // Prepare the list to store new connections.
    List<CovertConnection> newConns = <CovertConnection>[];

    // Loop through each slot and initialize a new covert connection if none exists for that slot.
    for (int sNum = 0; sNum < slots.length; sNum++) {
      CovertSlot s = slots[sNum];
      if (s.covConn == null) {
        // Initialize a new covert connection and associate it with the slot.
        s.covConn = CovertConnection();
        s.covConn?.slotNum = sNum;
        CovertConnection? myCovConn = s.covConn;

        if (myCovConn != null) {
          // Add the new connection to the list of new connections.
          newConns.add(myCovConn);
        }
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
      double randDelay = (randSpan ?? 0) * randTrap(rng);

      // Invoke the method to initiate and run the connection.
      runConnection(
          covConn, connTime.millisecondsSinceEpoch, randDelay, connectTimeout);
    }
  }

  /// Schedules a task to be submitted.
  ///
  /// This method schedules a submission or ping task for the specified covert slot.
  ///
  /// Parameters:
  /// - [slotNum]: The slot number for the covert slot.
  /// - [tStart]: The DateTime object representing the start time for scheduling.
  /// - [subMsg]: The message to be submitted.
  ///
  /// Returns:
  ///  `void`
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
  ///
  /// This method schedules the submissions or ping tasks for all available covert slots.
  /// If a slot does not have a message to submit, a ping task will be scheduled instead.
  /// This ensures that all slots are either actively submitting a message or keeping the connection alive through a ping.
  ///
  /// Parameters:
  /// - [tStart]: The DateTime object representing the start time for scheduling tasks.
  /// - [slotMessages]: A List of messages, one for each slot, that are to be submitted.
  ///                   These messages should be of type `pb.GeneratedMessage` or null.
  ///
  /// Returns:
  ///  `void`
  ///
  /// Note:
  /// - The length of `slotMessages` must equal the number of available slots (`slots.length`).
  /// - The method updates the `t_submit` and `subMsg` fields of each `CovertSlot` as needed.
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
  ///
  /// Parameters:
  /// - [covConn] - The CovertConnection object to be handled.
  /// - [connTime] - The time for the connection in milliseconds since epoch.
  /// - [randDelay] - Random delay factor to be applied.
  /// - [connectTimeout] - Connection timeout in seconds.
  ///
  /// Returns:
  ///   A `Future<void>` whose resolution indicates completion.
  Future<void> runConnection(CovertConnection covConn, int connTime,
      double randDelay, int connectTimeout) async {
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
        Map<String, dynamic> proxyOpts;

        // Check proxy options.
        if (this.proxyOpts == null) {
          proxyOpts = {};
        } else {
          final unique = 'CF${randTag}_${covConn.connNumber}';
          proxyOpts = {
            'proxy_username': unique,
            'proxy_password': unique,
          };
          proxyOpts.addAll(this.proxyOpts!);
        }

        limiter.bump();

        // Attempt to open a connection.
        try {
          final connection = await openConnection(destAddr!, destPort!,
              connTimeout: connectTimeout.toDouble(),
              ssl: this.ssl,
              socksOpts: proxyOpts);
          covConn.connection = connection;
        } catch (e) {
          // Connection failed.

          // Increment the total number of failed connections.
          countFailed++;

          // Note the time at which the connection failed.
          final tEnd = DateTime.now().millisecondsSinceEpoch;

          print(
              'could not establish connection (after ${((tEnd - tBegin) / 1000).toStringAsFixed(3)}s): $e');
          rethrow;
        }

        // Connection succeeded.

        // Increment the total number of established connections.
        countEstablished++;

        // Note the time at which the connection was established.
        final tEnd = DateTime.now().millisecondsSinceEpoch;
        print(
            '[${covConn.connNumber}] connection established after ${((tEnd - tBegin) / 1000).toStringAsFixed(3)}s');

        // Set the ping time for the connection.
        covConn.delay = (randTrap(this.rng) ?? 0) * (this.randSpan ?? 0);

        // Note the time at which the ping was sent.
        int lastActionTime = DateTime.now().millisecondsSinceEpoch;

        // STATE 2 - Working.
        while (!stopping) {
          DateTime? nextTime;
          final slotNum = covConn.slotNum;
          dynamic action; // Callback to hold the action function.
          // TODO type

          // Second preference: submit something.
          if (slotNum != null) {
            CovertSlot slot = this.slots[slotNum];
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
          nextTime = nextTime.add(Duration(seconds: randDelay.toInt()));

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
            print("$label error $e");
            rethrow;
          } finally {
            print("$label done");
          }

          // Note the time at which the action was completed.
          lastActionTime = DateTime.now().millisecondsSinceEpoch;
        }

        // STATE 3 - Stopping.
        while (true) {
          // Wait for the stop time or the next wakeup.
          final stopTime =
              stopTStart?.add(Duration(seconds: randDelay.toInt())) ??
                  DateTime.now();

          // If we are woken up before the stop time, then just don't make a connection at all.
          if (!(await covConn.waitWakeupOrTime(stopTime))) {
            break;
          }
        }

        print("[${covConn.connNumber}] closing from stop");
      } catch (e) {
        // In case of any problem, record the exception and if we have a slot, reassign it.
        final exception = e;

        final slotNum = covConn.slotNum;
        if (slotNum != null) {
          try {
            final spare = this.spareConnections.removeLast();
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

            if (exception is Exception) {
              // Stop the covert submitter with the exception.
              stop(exception);
            } else {
              // Handle the case where the exception is not an instance of Exception.
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
  ///
  /// Returns:
  ///   `void`
  ///
  /// Throws:
  /// - FusionError: if a failure exception exists.
  void checkOk() {
    var e = failureException;
    if (e != null) {
      throw FusionError('Covert connections failed: ${e.runtimeType} $e');
    }
  }

  /// Verifies all slots are connected.
  ///
  /// Returns:
  ///   void
  ///
  /// Throws:
  ///  - FusionError: if not all slots are connected.
  void checkConnected() {
    checkOk();
    var numMissing = slots.where((s) => s.covConn?.connection == null).length;
    if (numMissing > 0) {
      throw FusionError(
          "Covert connections were too slow ($numMissing incomplete out of ${slots.length}).");
    }
  }

  /// Verifies all submissions are done.
  ///
  /// Returns:
  ///   `void`
  ///
  /// Throws:
  /// - FusionError: if not all submissions are completed.
  void checkDone() {
    checkOk();
    int numMissing = slots.where((s) => !s.done).length;
    if (numMissing > 0) {
      throw FusionError(
          "Covert submissions were too slow ($numMissing incomplete out of ${slots.length}).");
    }
  }
}

/// Checks if a specific port on a host is running a Tor service.
///
/// This function tries to connect to a given a [host] and [port],
/// and then sends a "GET" request to check for the typical Tor error message.
/// This is a simple heuristic to identify Tor.
///
/// Parameters:
///  - [host]: The host address to check.
///  - [port]: The port to check.
///
/// Returns:
///   A `Future<bool>` that resolves to `true` if the port appears to be running Tor,
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
///
/// Attributes:
/// - [lifetime]: The lifetime of the timestamps.
class TorLimiter {
  Queue<DateTime> deque = Queue<DateTime>();
  int lifetime;

  // Internal count to track the number of operations.
  // Declare a lock here, may need a special Dart package for this... how about a mutex?
  /*int _count = 0;*/

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
TorLimiter limiter = TorLimiter(torCoolDownTime);

/// Generates a random number based on a trapezoidal distribution.
///
/// Uses a random number generator [rng].
///
/// TODO move this to the Utilities class.
///
/// Parameters:
/// - [rng]: The random number generator to use.
///
/// Returns:
///   A random double based on a trapezoidal distribution.
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

/// Represents a Fusion error.
///
/// Attributes:
/// - [cause]: The cause of the error as a String.
class FusionError implements Exception {
  /// The cause of the error as a String.
  String cause;

  /// Constructor that initializes the FusionError with a given [cause].
  FusionError(this.cause);
}

/// Represents an unrecoverable Fusion error.
class Unrecoverable extends FusionError {
  /// Constructor that initializes the Unrecoverable error with a given [cause].
  Unrecoverable(String cause) : super(cause);
}

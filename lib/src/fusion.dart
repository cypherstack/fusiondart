import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:fixnum/fixnum.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/covert.dart';
import 'package:fusiondart/src/encrypt.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/io.dart';
import 'package:fusiondart/src/models/address.dart';
import 'package:fusiondart/src/models/blind_signature_request.dart';
import 'package:fusiondart/src/models/input.dart';
import 'package:fusiondart/src/models/output.dart';
import 'package:fusiondart/src/models/protobuf.dart';
import 'package:fusiondart/src/models/transaction.dart';
import 'package:fusiondart/src/models/utxo_dto.dart';
import 'package:fusiondart/src/output_handling.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:fusiondart/src/receive_messages.dart';
import 'package:fusiondart/src/socketwrapper.dart';
import 'package:fusiondart/src/status.dart';
import 'package:fusiondart/src/util.dart';
import 'package:fusiondart/src/validation.dart';
import 'package:protobuf/protobuf.dart';

final bool kDebugPrintEnabled = true;

final class FusionParams {
  // CashFusion server host.
  // Alternative host: `"fusion.servo.cash"`.

  final String serverHost = "cashfusion.stackwallet.com";

  // Server port.
  // For use with the alternative host above, use `8789`.
  final int serverPort = 8787;

  final bool serverSsl = false;
}

/// Fusion class is responsible for coordinating the CashFusion transaction process.
///
/// It maintains the state and controls the flow of a fusion operation.
class Fusion {
  final FusionParams _fusionParams;

  // Private late finals used for dependency injection.
  late final Future<List<Address>> Function() _getAddresses;
  late final Future<List<Input>> Function(String address) _getInputsByAddress;
  late final Future<List<Transaction>> Function(String address)
      _getTransactionsByAddress;
  late final Future<List<Address>> Function(int numberOfAddresses)
      _getUnusedReservedChangeAddresses;
  late final Future<({InternetAddress host, int port})> Function()
      _getSocksProxyAddress;
  late final Future<int> Function() _getChainHeight;

  /// Constructor that sets up a Fusion object.
  Fusion(this._fusionParams);

  /// Method to initialize Fusion instance with necessary wallet methods.
  /// The methods injected here are used for various operations throughout the fusion process.
  Future<void> initFusion({
    required Future<List<Address>> Function() getAddresses,
    required Future<List<Input>> Function(String address) getInputsByAddress,
    required Future<List<Transaction>> Function(String address)
        getTransactionsByAddress,
    required Future<List<Address>> Function(int numberOfAddresses)
        getUnusedReservedChangeAddresses,
    required Future<({InternetAddress host, int port})> Function()
        getSocksProxyAddress,
    required Future<int> Function() getChainHeight,
  }) async {
    _getAddresses = getAddresses;
    _getInputsByAddress = getInputsByAddress;
    _getTransactionsByAddress = getTransactionsByAddress;
    _getUnusedReservedChangeAddresses = getUnusedReservedChangeAddresses;
    _getSocksProxyAddress = getSocksProxyAddress;
    _getChainHeight = getChainHeight;

    // Load coinlib.
    await coinlib.loadCoinlib();
  }

  ///
  /// Current status of the fusion process
  ///
  ({FusionStatus status, String info}) get status => _status;
  late ({FusionStatus status, String info}) _status;
  void _updateStatus({
    required FusionStatus status,
    required String info,
  }) {
    _status = (status: status, info: info);
    // here we can do some notification when the status was updated if wanted
  }

  // TODO parameterize; should these be fed in as parameters upon construction/instantiation?

  int _covertPort = 0; // Covert connection port.
  bool _covertSSL = false; // Use SSL for covert connection?

  int _roundCount = 0; // Tracks the number of CashFusion rounds.
  String _txId = ""; // Holds a transaction ID. << you don't say!?

  // Various state variables.
  List<Input> _coins = []; // "coins"≈"inputs" in the python source.
  // List<Input> inputs = [];
  List<Output> _outputs = [];
  // List<Address> changeAddresses = [];

  bool _serverConnectedAndGreeted = false; // Have we connected to the server?
  bool _stopping = false; // Should fusion stop?
  bool _stoppingIfNotRunning = false; // Should fusion stop if it's not running?
  String _stopReason = ""; // Specifies the reason for stopping the operation.

  Connection? _connection; // Holds the active Connection object.
  // Currently holds a second parallel connection to the same as above???
  SocketWrapper? _socketWrapper;

  // int numComponents = 0; // Tracks the number of components.
  // double componentFeeRate = 0; // Defines the fee rate for each component.
  // double minExcessFee = 0; // Specifies the minimum excess fee.
  // double maxExcessFee = 0; // Specifies the maximum excess fee.
  // List<int> availableTiers = []; // Lists the available CashFusion tiers.
  ({
    int numComponents,
    int componentFeeRate,
    int minExcessFee,
    int maxExcessFee,
    List<int> availableTiers,
  })? _serverParams;

  // not used ????
  // int maxOutputs = 0; // Maximum number of outputs allowed.

  // int safetySumIn = 0; // The sum of all inputs, used for safety checks.
  // Map<int, int> safetyExcessFees = {}; // Holds safety excess fees.
  // Map<int, List<int>> tierOutputs = {}; // Associates tiers with outputs.
  // Not sure if this should be using the Output model.
  ({
    List<Input> inputs,
    Map<int, List<int>> tierOutputs,
    int safetySumIn,
    Map<int, int> safetyExcessFees,
  })? _allocatedOutputs;

  int _tier = 0; // Currently selected CashFusion tier.
  double _beginTime = 0.0; // [s] Represent time in seconds.
  List<int> _lastHash = <int>[]; // Holds the last hash used in a fusion.
  List<Address> _reservedAddresses = <Address>[]; // List of reserved addresses.
  // int safetyExcessFee = 0; // Safety excess fee for the operation.
  DateTime _tFusionBegin = DateTime.now(); // The timestamp when Fusion began.
  Uint8List _covertDomainB = Uint8List(0); // Holds the covert domain in bytes.

  // not used ???
  List<int>? _txInputIndices; // Indices for transaction inputs.

  Transaction _currentTransaction = Transaction();
  List<int> _myComponentIndexes = []; // Holds the indexes for the components.
  List<int> _myCommitmentIndexes = []; // Holds the indexes for the commitments.
  Set<int> _badComponents = {}; // The indexes of bad components.

  static const INACTIVE_TIME_LIMIT = Duration(minutes: 10);
  static const int COINBASE_MATURITY = 100; // Maturity for coinbase UTXOs.
  // https://github.com/Electron-Cash/Electron-Cash/blob/48ac434f9c7d94b335e1a31834ee2d7d47df5802/electroncash/bitcoin.py#L65
  static const int DEFAULT_MAX_COINS = 20; // Outputs to allocate for fusion.
  // https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/plugin.py#L68
  static const double KEEP_LINKED_PROBABILITY = 0.1; // Allowed linkability.
  // For semi-linked addresses (that share txids in their history), allow linking them with this probability.
  // https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/plugin.py#L62
  static const COIN_FRACTION_FUDGE_FACTOR = 10; // Heuristic factor
  // Guess that expected number of coins in wallet in equilibrium is = (this number) / fraction
  // https://github.com/Electron-Cash/Electron-Cash/blob/48ac434f9c7d94b335e1a31834ee2d7d47df5802/electroncash_plugins/fusion/plugin.py#L60

  // Not currently used. If needed, this should be made private and accessed using set/get
  // bool autofuseCoinbase = false; //   link to a setting in the wallet.
  // https://github.com/Electron-Cash/Electron-Cash/blob/48ac434f9c7d94b335e1a31834ee2d7d47df5802/electroncash_plugins/fusion/conf.py#L68

  /// Adds Unspent Transaction Outputs (UTXOs) from [utxoList] to the `coins` list as `Input`s.
  ///
  /// Given a list of UTXOs [utxoList] (as represented by the `Record(String txid, int vout, int value)`),
  /// this method converts them to `Input` objects and appends them to the internal `coins`
  /// list, which will later be used in a fusion operation.
  ///
  /// Returns:
  ///   Future<void> Returns a future that completes when the coins have been added.
  Future<void> addCoinsFromWallet(
    List<UtxoDTO> utxoList,
  ) async {
    // TODO sanity check the state of `coins` before adding to it.

    // Convert each UTXO info to an Input and add to 'coins'.
    for (final utxoInfo in utxoList) {
      _coins.add(
        Input.fromWallet(
          txId: utxoInfo.txid,
          vout: utxoInfo.vout,
          value: utxoInfo.value,
          pubKey: utxoInfo.pubKey,
        ),
      );
    }
    // TODO add validation and throw error if invalid UTXO detected
  }

  // /// Adds a change address [address] to the `changeAddresses` list.
  // ///
  // /// Takes an `Address` object and adds it to the internal `changeAddresses` list,
  // /// which is used to send back any remaining balance from a fusion operation.
  // ///
  // /// Returns:
  // ///   A future that completes when the address has been added.
  // Future<void> addChangeAddress(Address address) async {
  //   // Add address to List<Address> addresses[].
  //   changeAddresses.add(address);
  // }

  /// Executes the fusion operation.
  ///
  /// This method orchestrates the entire lifecycle of a CashFusion operation.
  ///
  /// Returns:
  ///   A `Future<void>` that resolves when the fusion operation is finished.
  ///
  /// Throws:
  /// - FusionError: If any step in the fusion operation fails.
  /// - Exception: For general exceptions.
  Future<void> fuse() async {
    Utilities.debugPrint("DEBUG FUSION 223...fusion run....");
    try {
      try {
        // Check compatibility  - This was done in python version to see if fast libsec installed.
        // For now , in dart, just pass this test.
      } on Exception catch (e) {
        // handle exception, rethrow as a custom FusionError
        throw FusionError("Incompatible: $e");
      }

      // TODO: this refactor is probably wrong... But we cannot store tor proxy info in variables as they can get updated elsewhere and then the instance of this FusionInterface will not have the updated info
      // Check if can connect to Tor proxy, if not, raise FusionError.
      final ({InternetAddress host, int port}) proxyInfo;
      try {
        proxyInfo = await _getSocksProxyAddress();
      } catch (e) {
        Utilities.debugPrint("Can't connect to Tor proxy $e");
        throw FusionError("Can't connect to Tor proxy");
      }

      try {
        // Check stop condition
        checkStop(running: false);
      } catch (e) {
        Utilities.debugPrint(e);
      }

      try {
        // Check coins
        checkCoins();
      } catch (e) {
        Utilities.debugPrint(e);
      }

      // Connect to server.
      _updateStatus(status: FusionStatus.connecting, info: "");
      try {
        _connection = await Connection.openConnection(
          _fusionParams.serverHost,
          _fusionParams.serverPort,
          connTimeout: Duration(seconds: 5),
          defaultTimeout: Duration(seconds: 5),
          ssl: _fusionParams.serverSsl,
        );
      } catch (e) {
        // TODO: _updateStatus with correct failure
        //   _updateStatus(status: FusionStatus.???, info: "");
        Utilities.debugPrint("Connect failed: $e");
        String sslstr = _fusionParams.serverSsl ? ' SSL ' : '';
        throw FusionError(
          "Could not connect to "
          "$sslstr${_fusionParams.serverHost}:${_fusionParams.serverPort}",
        );
      }

      // Once connection is successful, wrap operations inside this block.
      //
      // Within this block, version checks, downloads server params, handles coins and runs rounds.
      try {
        _socketWrapper = SocketWrapper(
          _fusionParams.serverHost,
          _fusionParams.serverPort,
        );

        if (_socketWrapper == null) {
          throw FusionError(
            "Could not connect to "
            "${_fusionParams.serverHost}:${_fusionParams.serverPort}",
          );
        }
        await _socketWrapper!.connect();

        // Version check and download server params.
        _serverParams = await IO.greet(
          connection: _connection!,
          socketWrapper: _socketWrapper!,
        );

        _socketWrapper!.status();
        _serverConnectedAndGreeted = true;
        notifyServerStatus(true);

        // In principle we can hook a pause in here -- user can insert coins after seeing server params.

        try {
          if (_coins.isEmpty) {
            throw FusionError('Started with no coins');
          }
        } catch (e) {
          Utilities.debugPrint(e);
          return;
        }

        final currentChainHeight = await _getChainHeight();

        _allocatedOutputs = await OutputHandling.allocateOutputs(
          connection: _connection!,
          socketWrapper: _socketWrapper!,
          status: status.status,
          coins: _coins,
          currentChainHeight: currentChainHeight,
          serverParams: _serverParams!,
          getTransactionsByAddress: _getTransactionsByAddress,
          getInputsByAddress: _getInputsByAddress,
          getAddresses: _getAddresses,
        );
        // In principle we can hook a pause in here -- user can tweak tier_outputs, perhaps cancelling some unwanted tiers.

        // Register for tiers, wait for a pool.
        await registerAndWait(_socketWrapper!);

        // launch the covert submitter
        CovertSubmitter covert = await startCovert();
        try {
          // Pool started. Keep running rounds until fail or complete.
          while (true) {
            _roundCount += 1;
            if (await runRound(covert)) {
              break;
            }
          }
        } finally {
          covert.stop();
        }
      } finally {
        await (_connection)?.close();
      }

      Utilities.debugPrint("RETURNING early in fuse....");
      return;

      // Wait for transaction to show up in wallet.
      for (int i = 0; i < 60; i++) {
        if (_stopping) {
          break; // not an error
        }

        if (Utilities.walletHasTransaction(_txId)) {
          break;
        }

        await Future<void>.delayed(Duration(seconds: 1));
      }

      // Set status to 'complete' with txid.
      _updateStatus(status: FusionStatus.complete, info: 'txid: $_txId');
    } on FusionError catch (err) {
      Utilities.debugPrint('Failed: $err');
      _updateStatus(status: FusionStatus.failed, info: err.toString());
    } catch (exc) {
      Utilities.debugPrint('Exception: $exc');
      _updateStatus(status: FusionStatus.exception, info: exc.toString());
    } finally {
      clearCoins();
      if (status.status != FusionStatus.complete) {
        for (Output output in _outputs) {
          // TODO implement
          /*Util.unreserve_change_address(output.addr);*/
        }
        if (!_serverConnectedAndGreeted) {
          notifyServerStatus(false, status: status);
        }
      }
    }
  } // End of `fuse()`.

  /// Notifies the server about the current status of the system using bool [b]
  /// and optional Record(String, String) status (status, message).
  ///
  /// Sends a status update to the server. The purpose and behavior of this method
  /// depend on the application's requirements.
  ///
  /// TODO implement.
  void notifyServerStatus(
    bool b, {
    ({FusionStatus status, String info})? status,
  }) {}

  /// Stops the current operation with optional String [reason] (default: "stopped")
  /// and bool [notIfRunning] (default: false).
  ///
  /// If an operation is in progress, stops it for the given reason.
  ///
  /// Parameters:
  /// - [reason] (optional): The reason for stopping the operation.
  /// - [notIfRunning] (optional): If true, the operation will not be stopped if it is running.
  ///
  /// Returns:
  ///  void
  void stop([String reason = "stopped", bool notIfRunning = false]) {
    if (_stopping) {
      return;
    }
    if (notIfRunning) {
      if (_stoppingIfNotRunning) {
        return;
      }
      _stopReason = reason;
      _stoppingIfNotRunning = true;
    } else {
      _stopReason = reason;
      _stopping = true;
    }
    // Note the reason is only overwritten if we were not already stopping this way.
  }

  /// Checks if the system should stop the current operation.
  ///
  /// This function is periodically called to determine whether the system should
  /// halt its operation.  Optional bool [running] indicates if the system is currently
  /// running (default is true).
  ///
  /// Parameters:
  /// - [running] (optional): Indicates if the system is currently running.
  ///
  /// Returns:
  /// `void`
  ///
  /// Throws:
  /// - FusionError: If the system should stop.
  void checkStop({bool running = true}) {
    // Gets called occasionally from fusion thread to allow a stop point.
    if (_stopping || (!running && _stoppingIfNotRunning)) {
      throw FusionError(_stopReason);
    }
  }

  /// Checks the status of the coins in the wallet.
  ///
  /// Verifies the integrity and validity of the coins stored in the internal wallet.
  ///
  /// TODO implement.
  void checkCoins() {
    // Implement by calling wallet layer to check the coins are ok.
    return;
  }

  /// Clears all coins from the internal `coins` list.
  ///
  /// Resets the internal coin list, effectively removing all stored coins.
  void clearCoins() {
    _coins = [];
  }

  /// Adds new coins to the internal `coins` list.
  ///
  /// Takes a list of `Input` [newCoins] objects representing new coins and appends them to the internal coin list.
  void addCoins(List<Input> newCoins) {
    _coins.addAll(newCoins);
  }

  /// Notifies the UI layer about changes to the `coins` list.
  ///
  /// Updates the UI to reflect changes in the internal list of coins.
  ///
  /// TODO implement.
  void notifyCoinsUI() {
    return;
  }

  /// Determines if the wallet is capable of participating in fusion operations.
  ///
  /// Checks various conditions to assess whether the wallet can be used for fusion.
  ///
  /// Returns:
  ///   A boolean flag indicating the wallet's capability to participate in fusion operations.
  ///
  /// TODO implement
  static bool walletCanFuse() {
    // TODO Implement logic here to return false if the wallet can't fuse (if it's read only or non P2PKH)
    return true;
  }

  /// Registers a client to a fusion server and waits for the fusion process to start.
  ///
  /// This method is responsible for the client-side setup and management of the
  /// CashFusion protocol. It sends registration messages to the server,
  /// maintains state, and listens for updates through a [socketwrapper]
  ///
  /// Returns:
  ///   A Future that resolves when the fusion process starts.
  ///
  /// Throws:
  /// - FusionError: in case of any unexpected behavior.
  Future<void> registerAndWait(SocketWrapper socketwrapper) async {
    // Initialize a stopwatch to measure elapsed time.
    Stopwatch stopwatch = Stopwatch()..start();

    // Placeholder for messages from the server.
    //
    // This used to be `dynamic`, but then recv and IO.recv were changed to return
    // a GeneratedMessage.
    GeneratedMessage msg;

    // Initialize a map to store the outputs for each tier.
    Map<int, List<int>> tierOutputs = _allocatedOutputs!.tierOutputs;

    // Sort the tiers in ascending order.
    List<int> tiersSorted = tierOutputs.keys.toList()..sort();

    // Check if tierOutputs is empty and throw an error if so.
    if (tierOutputs.isEmpty) {
      throw FusionError(
          'No outputs available at any tier (selected inputs were too small / too large).');
    }

    Utilities.debugPrint('registering for tiers: $tiersSorted');

    // Temporary initialization of some CashFusion parameters.
    int selfFuse = 1; // Temporary value for now.
    List<int> cashfusionTag = [1]; // Temporary value for now.

    // Prechecks before proceeding.
    checkStop(running: false);
    checkCoins();

    // Prepare tags for joining the pool.
    List<JoinPools_PoolTag> tags = [
      JoinPools_PoolTag(id: cashfusionTag, limit: selfFuse)
    ];

    // Create the JoinPools message.
    JoinPools joinPools =
        JoinPools(tiers: tiersSorted.map((i) => Int64(i)).toList(), tags: tags);

    // Wrap it in a ClientMessage.
    ClientMessage clientMessage = ClientMessage()..joinpools = joinPools;

    // Send the message to the server.
    await IO.send(
      clientMessage,
      socketWrapper: _socketWrapper!,
      connection: _connection!,
    );

    ({String status, String message}) status = (
      status: 'waiting',
      message: 'Registered for tiers',
    );

    // TODO make Entry class or otherwise type this section.
    Map<dynamic, String> tiersStrings = {
      for (var entry in tierOutputs.entries)
        entry.key:
            (entry.key * 1e-8).toStringAsFixed(8).replaceAll(RegExp(r'0+$'), '')
    };

    // Main loop to receive updates from the server.
    while (true) {
      Utilities.debugPrint("RECEIVE LOOP 870............DEBUG");
      msg = await IO.recv(
          [ReceiveMessages.tierStatusUpdate, ReceiveMessages.fusionBegin],
          socketWrapper: _socketWrapper!,
          connection: _connection!,
          timeout: Duration(seconds: 10));

      /*if (msg == null) continue;*/

      // Check for a FusionBegin message.
      FieldInfo<dynamic>? fieldInfoFusionBegin =
          msg.info_.byName[ReceiveMessages.fusionBegin];
      if (fieldInfoFusionBegin == null) {
        throw FusionError(
            'Expected field not found in message: $ReceiveMessages.fusionbegin');
      }

      // Validate that the received message is indeed a FusionBegin message.
      final bool messageIsFusionBegin =
          msg.hasField(fieldInfoFusionBegin.tagNumber);
      if (messageIsFusionBegin) {
        Utilities.debugPrint("DEBUG 867 Fusion Begin message...");
        break;
      } /* else {
        throw FusionError('Expected a FusionBegin message');
      }
      */

      // Prechecks before processing the received message.
      checkStop(running: false);
      checkCoins();

      // Initialize a variable to store field information for "tierstatusupdate" in the message.
      FieldInfo<dynamic>? fieldInfo =
          msg.info_.byName[ReceiveMessages.tierStatusUpdate];
      // Check if the field exists in the message, if not, throw an error.
      if (fieldInfo == null) {
        throw FusionError(
            'Expected field not found in message: $ReceiveMessages.tierstatusupdate');
      }

      // Determine if the message contains a "TierStatusUpdate"
      final bool messageIsTierStatusUpdate = msg.hasField(fieldInfo.tagNumber);
      Utilities.debugPrint("DEBUG 889 getting tier update.");

      // If the message doesn't contain a "TierStatusUpdate", throw an error.
      if (!messageIsTierStatusUpdate) {
        throw FusionError('Expected a TierStatusUpdate message');
      }

      // Initialize a map to store the statuses from the TierStatusUpdate message.
      final Map<Int64, TierStatusUpdate_TierStatus> statuses;

      // Populate the statuses map if "TierStatusUpdate" exists in the message.
      if (messageIsTierStatusUpdate) {
        /*TierStatusUpdate tierStatusUpdate = msg.tierstatusupdate;*/
        TierStatusUpdate tierStatusUpdate =
            msg.getField(fieldInfo.tagNumber) as TierStatusUpdate;
        statuses = tierStatusUpdate.statuses;
      } else {
        // TODO: Handle this differently?
        throw Exception("messageIsTierStatusUpdate is false");
      }

      // Utilities.debugPrint("DEBUG 8892 statuses: $statuses.");
      // Utilities.debugPrint("DEBUG 8893 statuses: ${statuses!.entries}.");

      // Initialize variables to store the maximum fraction and tier numbers.
      double maxfraction = 0.0;
      List<int> maxtiers = <int>[];
      int? besttime;
      int? besttimetier;

      // Loop through each entry in statuses to find the maximum fraction and best time.
      for (var entry in statuses.entries) {
        // TODO make Entry class or otherwise type this section

        // Calculate the fraction of players to minimum players.
        final double frac = ((entry.value.players.toInt())) /
            ((entry.value.minPlayers.toInt()));

        // Update 'maxfraction' and 'maxtiers' if the current fraction is greater than or equal to the current 'maxfraction'.
        if (frac >= maxfraction) {
          if (frac > maxfraction) {
            maxfraction = frac;
            maxtiers.clear();
          }
          maxtiers.add(entry.key.toInt());
        }

        // // Check if "timeRemaining" field exists and find the smallest time.
        FieldInfo<dynamic>? fieldInfoTimeRemaining =
            entry.value.info_.byName["timeRemaining"];
        /*
        if (fieldInfoTimeRemaining == null) {
          throw FusionError(
              'Expected field not found in message: timeRemaining');
        }
        */

        // Check if the field 'timeRemaining' exists in the current entry.
        if (fieldInfoTimeRemaining != null) {
          // Confirm that the message contains the 'timeRemaining' field.
          if (entry.value.hasField(fieldInfoTimeRemaining.tagNumber)) {
            // Convert 'timeRemaining' to integer
            int tr = entry.value.timeRemaining.toInt();

            // Update 'besttime' and 'besttimetier' if this is the first time or if 'tr' is smaller than the current 'besttime'
            if (besttime == null || tr < besttime) {
              besttime = tr;
              besttimetier = entry.key.toInt();
            }
          }
        }
        // TODO handle else case when timeRemaining field is missing.
      }

      // Initialize lists to store tiers for different display sections.
      List<String> displayBest = <String>[];
      List<String> displayMid = <String>[];
      List<String> displayQueued = <String>[];

      // Populate the display lists based on the tier status.
      for (int tier in tiersSorted) {
        if (statuses.containsKey(tier)) {
          String? tierStr = tiersStrings[tier];
          if (tierStr == null) {
            throw FusionError(
                'server reported status on tier we are not registered for');
          }
          if (tier == besttimetier) {
            displayBest.insert(0, '**$tierStr**');
          } else if (maxtiers.contains(tier)) {
            displayBest.add('[$tierStr]');
          } else {
            displayMid.add(tierStr);
          }
        } else {
          displayQueued.add(tiersStrings[tier]!);
        }
      }

      // Construct the final display string for tiers.
      List<String> parts = <String>[];
      if (displayBest.isNotEmpty || displayMid.isNotEmpty) {
        parts.add("Tiers: ${displayBest.join(', ')} ${displayMid.join(', ')}");
      }
      if (displayQueued.isNotEmpty) {
        parts.add("Queued: ${displayQueued.join(', ')}");
      }
      String tiersString = parts.join(' ');

      // Determine the overall status based on the best time and maximum fraction.
      if (besttime == null) {
        if (stopwatch.elapsedMilliseconds >
            INACTIVE_TIME_LIMIT.inMilliseconds) {
          throw FusionError('stopping due to inactivity');
        }
        // TODO handle else case
      }
      // TODO handle else case

      // Final status assignment based on calculated variables
      if (besttime != null) {
        status = (
          status: 'waiting',
          message: 'Starting in ${besttime}s. $tiersString',
        );
      } else if (maxfraction >= 1) {
        status = (
          status: 'waiting',
          message: 'Starting soon. $tiersString',
        );
      } else if (displayBest.isNotEmpty || displayMid.isNotEmpty) {
        status = (
          status: 'waiting',
          message: '${(maxfraction * 100).round()}% full. $tiersString',
        );
      } else {
        status = (
          status: 'waiting',
          message: tiersString,
        );
      }
    } // End of while loop.  Loop exits with a break if a FusionBegin message is received.

    // Check if the field 'fusionbegin' exists in the message.
    FieldInfo<dynamic>? fieldInfoFusionBegin =
        msg.info_.byName[ReceiveMessages.fusionBegin];
    if (fieldInfoFusionBegin == null) {
      throw FusionError(
          'Expected field not found in message: $ReceiveMessages.fusionbegin');
    }

    // Determine if the message contains a FusionBegin message.
    bool messageIsFusionBegin = msg.hasField(fieldInfoFusionBegin.tagNumber);

    // Check if the received message is a FusionBegin message.
    if (!messageIsFusionBegin) {
      throw FusionError('Expected a FusionBegin message');
    }

    // Record the time when the fusion process began.
    _tFusionBegin = DateTime.now();

    // Check if the received message is a ServerMessage.
    if (msg is! ServerMessage) {
      throw FusionError('Expected a ServerMessage');
    }

    // Retrieve the FusionBegin message from the ServerMessage.
    FusionBegin fusionBeginMsg = msg.fusionbegin;

    // Calculate how many seconds have passed since the stopwatch was started.
    int elapsedSeconds = stopwatch.elapsedMilliseconds ~/ 1000;

    // Calculate the time discrepancy between the server and the client.
    double clockMismatch = fusionBeginMsg.serverTime.toInt() -
        DateTime.now().millisecondsSinceEpoch / 1000;

    // Check if the clock mismatch exceeds the maximum allowed discrepancy.
    if (clockMismatch.abs().toDouble() > Protocol.MAX_CLOCK_DISCREPANCY) {
      throw FusionError(
          "Clock mismatch too large: ${(clockMismatch.toDouble()).toStringAsFixed(3)}.");
    }

    // Retrieve the tier in which the fusion process will occur.
    _tier = fusionBeginMsg.tier.toInt();

    // Populate covertDomainB with the received covert domain information.
    _covertDomainB = Uint8List.fromList(fusionBeginMsg.covertDomain);

    // Retrieve additional information such as port, SSL status, and server time for the fusion process.
    _covertPort = fusionBeginMsg.covertPort;
    _covertSSL = fusionBeginMsg.covertSsl;
    _beginTime = fusionBeginMsg.serverTime.toDouble();

    // Calculate the initial hash value for the fusion process
    _lastHash = Utilities.calcInitialHash(
        _tier, _covertDomainB, _covertPort, _covertSSL, _beginTime);

    // Retrieve the output amounts for the given tier and prepare the output addresses.
    List<int>? outAmounts = tierOutputs[_tier];
    List<Address> outAddrs =
        await _getUnusedReservedChangeAddresses(outAmounts?.length ?? 0);

    // Populate reservedAddresses and outputs with the prepared amounts and addresses.
    // TODO: this [reservedAddresses] is never read from????
    _reservedAddresses = outAddrs;
    _outputs = Utilities.zip(outAmounts ?? [], outAddrs)
        .map((pair) => Output(value: pair[0] as int, addr: pair[1] as Address))
        .toList();

    Utilities.debugPrint(
        "starting fusion rounds at tier $_tier: ${_coins.length} inputs and ${_outputs.length} outputs");
  }

  /// Starts a CovertSubmitter and schedules Tor connections.
  ///
  /// This method initializes a `CovertSubmitter` with the specified configuration,
  /// schedules the connections, and continuously checks the connection status.
  ///
  /// Throws:
  /// - `FusionError` if the covert domain is badly encoded or if other errors occur.
  ///
  /// Returns:
  ///   A `Future<CovertSubmitter>` that resolves to the initialized `CovertSubmitter`.
  Future<CovertSubmitter> startCovert() async {
    Utilities.debugPrint("DEBUG START COVERT!");

    // set status record/tuple.
    _updateStatus(
      status: FusionStatus.running,
      info: 'Setting up Tor connections',
    );

    // Get the Tor host and port from the wallet configuration.
    final ({InternetAddress host, int port}) proxyInfo;
    try {
      proxyInfo = await _getSocksProxyAddress();
    } catch (e) {
      throw FusionError("startCovert() can't connect to Tor proxy");
    }

    // Decode the covert domain and validate it.
    String covertDomain;
    try {
      covertDomain = utf8.decode(_covertDomainB);
    } catch (e) {
      throw FusionError('badly encoded covert domain');
    }

    // Create a new CovertSubmitter instance.
    CovertSubmitter covert = CovertSubmitter(
      covertDomain,
      _covertPort,
      _covertSSL,
      proxyInfo.host.address,
      proxyInfo.port,
      _serverParams!.numComponents,
      Protocol.COVERT_SUBMIT_WINDOW,
      Duration(seconds: Protocol.COVERT_SUBMIT_TIMEOUT),
    );
    try {
      // Schedule Tor connections for the CovertSubmitter.
      covert.scheduleConnections(
        _tFusionBegin,
        Duration(seconds: Protocol.COVERT_CONNECT_WINDOW),
        numSpares: Protocol.COVERT_CONNECT_SPARES,
        connectTimeout: Duration(
          seconds: Protocol.COVERT_CONNECT_TIMEOUT,
        ),
      );

      /*
      Utilities.debugPrint("DEBUG return early from covert");
      // Return the CovertSubmitter instance early.
      // TODO finish method.
      return covert;
      */

      // Loop a bit before we're expecting startRound, watching for status updates.
      final tend = _tFusionBegin.add(Duration(
          seconds: (Protocol.WARMUP_TIME - Protocol.WARMUP_SLOP - 1).round()));

      // Poll the status of the connections until the ending time.
      while (DateTime.now().millisecondsSinceEpoch / 1000 <
          tend.millisecondsSinceEpoch / 1000) {
        // Count the number of established main and spare connections.
        int numConnected =
            covert.slots.where((s) => s.covConn?.connection != null).length;
        int numSpareConnected =
            covert.spareConnections.where((c) => c.connection != null).length;

        // Update the status based on connection counts.
        _updateStatus(
          status: FusionStatus.running,
          info: "Setting up Tor connections "
              "($numConnected+$numSpareConnected out"
              " of ${_serverParams?.numComponents})",
        );

        // Wait for 1 second before re-checking.
        await Future<void>.delayed(Duration(seconds: 1));

        // Check the health of the CovertSubmitter and overall system.
        covert.checkOk();
        checkStop();
        checkCoins();
      }
    } catch (e) {
      // Stop the CovertSubmitter and re-throw the error.
      covert.stop();
      rethrow;
    }

    // Return the CovertSubmitter instance.
    return covert;
  }

  /// Runs a round of the Fusion protocol.
  ///
  /// This method takes care of various steps in the Fusion protocol round,
  /// including receiving and validating server messages, creating commitments,
  /// and submitting components.
  ///
  /// [covert] is a `CovertSubmitter` instance used for covert submissions.
  ///
  /// Returns:
  ///   A `Future<bool>` indicating the success or failure of the round.
  Future<bool> runRound(CovertSubmitter covert) async {
    Utilities.debugPrint("START OF RUN ROUND");

    // Initial round status and timeout calculation.
    _updateStatus(
      status: FusionStatus.running,
      info: "Starting round ${_roundCount.toString()}",
    );

    int timeoutInSeconds =
        (2 * Protocol.WARMUP_SLOP + Protocol.STANDARD_TIMEOUT).toInt();

    // Await the start of round message from the server.
    GeneratedMessage msg = await IO.recv([ReceiveMessages.startRound],
        socketWrapper: _socketWrapper!,
        connection: _connection!,
        timeout: Duration(seconds: timeoutInSeconds));

    // Initialize the covert timer base
    final covertT0 = DateTime.now().millisecondsSinceEpoch / 1000;
    double covertClock() =>
        (DateTime.now().millisecondsSinceEpoch / 1000) - covertT0;

    // Check if the received message is a ServerMessage.
    if (msg is! ServerMessage) {
      throw FusionError('Expected a ServerMessage');
    }

    // Retrieve the StartRound message from the ServerMessage.
    StartRound startRoundMsg = msg.startround;

    Int64 roundTime = startRoundMsg.serverTime;

    // Validate the server's time against our local time.
    final clockMismatch = roundTime -
        Int64((DateTime.now().millisecondsSinceEpoch / 1000).round());

    if (clockMismatch.abs() > Int64(Protocol.MAX_CLOCK_DISCREPANCY.toInt())) {
      throw FusionError(
          "Clock mismatch too large: ${clockMismatch.toInt().toStringAsPrecision(3)}.");
    }

    // Check that the warmup time was as expected.
    final lag = covertT0 -
        (_tFusionBegin.millisecondsSinceEpoch / 1000) -
        Protocol.WARMUP_TIME;
    if (lag.abs() > Protocol.WARMUP_SLOP) {
      throw FusionError(
          "Warmup period too different from expectation (|${lag.toStringAsFixed(3)}s| > ${Protocol.WARMUP_SLOP.toStringAsFixed(3)}s).");
    }
    _tFusionBegin = DateTime.now();

    Utilities.debugPrint(
        "round starting at ${DateTime.now().millisecondsSinceEpoch / 1000}");

    // Calculate fees and sums for inputs and outputs.
    final inputFees = _allocatedOutputs!.inputs.fold(
      BigInt.zero,
      (sum, input) =>
          sum +
          BigInt.from(
            Utilities.componentFee(
                input.sizeOfInput(), _serverParams!.componentFeeRate),
          ),
    );

    final outputFees = BigInt.from(
      _outputs.length *
          Utilities.componentFee(
            34, // 34 is the size of a P2PKH output.
            _serverParams!.componentFeeRate,
          ),
    ); // See https://github.com/Electron-Cash/Electron-Cash/blob/ba01323b732d1ae4ba2ca66c40e3f27bb92cee4b/electroncash_plugins/fusion/fusion.py#L820

    final sumIn = _allocatedOutputs!.inputs.fold(
      BigInt.zero,
      (sum, e) => sum + BigInt.from(e.amount),
    );
    final sumOut =
        _outputs.fold(BigInt.zero, (sum, e) => sum + BigInt.from(e.value));

    // Calculate total and excess fee for safety checks.
    final totalFee = sumIn - sumOut;
    final excessFee = totalFee - inputFees - outputFees;

    // Perform the safety checks!
    final safeties = [
      sumIn == BigInt.from(_allocatedOutputs!.safetySumIn),
      excessFee == BigInt.from(_allocatedOutputs!.safetyExcessFees[_tier] ?? 0),
      excessFee <= BigInt.from(Protocol.MAX_EXCESS_FEE),
      totalFee <= BigInt.from(Protocol.MAX_FEE),
    ];

    // Abort the round if the safety checks fail.
    if (!safeties.every((element) => element)) {
      throw Exception(
          "(BUG!) Funds re-check failed -- aborting for safety. ${safeties.toString()}");
    }

    // Extract round public key and blind nonce points from the server message.
    final roundPubKey = startRoundMsg.roundPubkey;
    final blindNoncePoints = startRoundMsg.blindNoncePoints;
    if (blindNoncePoints.length != _serverParams!.numComponents) {
      throw FusionError('blind nonce miscount');
    }

    // Generate components and related data
    int numBlanks = _serverParams!.numComponents -
        _allocatedOutputs!.inputs.length -
        _outputs.length;
    final List<ComponentResult> genComponentsResults =
        OutputHandling.genComponents(
            numBlanks, _coins, _outputs, _serverParams!.componentFeeRate);

    // Initialize lists to store various parts of the component data.
    final List<Uint8List> myCommitments = [];
    final List<int> myComponentSlots = [];
    final List<Uint8List> myComponents = [];
    final List<Proof> myProofs = [];
    final List<Uint8List> privKeys = [];
    final List<BigInt> pedersenAmount = [];

    // TODO type
    final List<dynamic> pedersenNonce = [];

    // Populate the lists with data from the generated components.
    for (ComponentResult genComponentResult in genComponentsResults) {
      myCommitments.add(genComponentResult.commitment);
      myComponentSlots.add(genComponentResult.counter);
      myComponents.add(genComponentResult.component);
      myProofs.add(genComponentResult.proof);
      privKeys.add(genComponentResult.privateKey);
      if (genComponentResult.pedersenAmount != null) {
        pedersenAmount.add(genComponentResult.pedersenAmount!);
      }
      pedersenNonce.add(genComponentResult.pedersenNonce);
    }
    // Sanity checks on the generated components.
    assert(excessFee ==
        pedersenAmount.fold(
            BigInt.zero,
            (BigInt accumulator, BigInt value) =>
                accumulator + value)); // Sum the elements
    assert(myComponents.toSet().length == myComponents.length); // no duplicates

    // Generate blind signature requests (see schnorr from Electron-Cash's schnorr.py)
    /*
    final blindSigRequests = blindNoncePoints.map((e) => Schnorr.BlindSignatureRequest(roundPubKey, e, sha256(myComponents.elementAt(e)))).toList();
    */
    List<BlindSignatureRequest> blindSigRequests =
        List.generate(blindNoncePoints.length, (index) {
      final R = blindNoncePoints[index];
      final m = myComponents[index];
      final messageHash = crypto.sha256.convert(m).bytes;

      return BlindSignatureRequest(Uint8List.fromList(roundPubKey),
          Uint8List.fromList(R), Uint8List.fromList(messageHash));
    });

    /*
    Utilities.debugPrint("RETURNING EARLY FROM run round .....");
    return true;
    */

    // Perform pre-submission checks and prepare a random number for later use.
    final randomNumber = Utilities.getRandomBytes(32);
    covert.checkOk();
    checkStop();
    checkCoins();

    // Check if _socketWrapper has been initialized.
    if (_socketWrapper == null) {
      throw FusionError('Connection not initialized');
    }

    // Send initial commitments, fees, and other data to the server.
    await IO.send(
      PlayerCommit(
        initialCommitments: myCommitments,
        excessFee: Int64.parseHex(excessFee.toHex),
        pedersenTotalNonce: pedersenNonce.cast<int>(),
        randomNumberCommitment: crypto.sha256.convert(randomNumber).bytes,
        blindSigRequests: blindSigRequests.map((r) => r.request).toList(),
      ),
      socketWrapper: _socketWrapper!,
      connection: _connection!,
    );

    // Await blind signature responses from the server
    msg = await IO.recv([ReceiveMessages.blindSigResponses],
        socketWrapper: _socketWrapper!,
        connection: _connection!,
        timeout: Duration(seconds: Protocol.T_START_COMPS));

    // Validate type and length of the received message and perform a sanity-check on it.
    if (msg is BlindSigResponses) {
      BlindSigResponses typedMsg = msg;
      assert(typedMsg.scalars.length == blindSigRequests.length);
    } else {
      // Handle the case where msg is not of type BlindSigResponses.
      throw Exception('Unexpected message type: ${msg.runtimeType}');
    }

    final blindSigs = List.generate(
      blindSigRequests.length,
      (index) {
        if (msg is BlindSigResponses) {
          BlindSigResponses typedMsg = msg;
          return blindSigRequests[index].finalize(
              Uint8List.fromList(typedMsg.scalars[index]),
              check: true);
        } else {
          // Handle the case where msg is not of type BlindSigResponses.
          throw Exception('Unexpected message type: ${msg.runtimeType}');
        }
      },
    );

    // Sleep until the covert component phase really starts, to catch covert connection failures.
    double remainingTime = Protocol.T_START_COMPS - covertClock();
    if (remainingTime < 0) {
      throw FusionError('Arrived at covert-component phase too slowly.');
    }
    await Future<void>.delayed(Duration(seconds: remainingTime.floor()));

    // Our final check to leave the fusion pool, before we start telling our
    // components. This is much more annoying since it will cause the round
    // to fail, but since we would end up killing the round anyway then it's
    // best for our privacy if we just leave now.
    // (This also is our first call to check_connected.)
    covert.checkConnected();
    checkCoins();

    // Start covert component submissions
    Utilities.debugPrint("starting covert component submission");
    _updateStatus(
      status: FusionStatus.running,
      info: "covert submission: components",
    );

    // If we fail after this point, we want to stop connections gradually and
    // randomly. We don't want to stop them all at once, since if we had already
    // provided our input components then it would be a leak to have them all drop at once.
    covert.setStopTime((covertT0 + Protocol.T_START_CLOSE).toInt());

    // Schedule covert submissions.
    List<CovertComponent?> messages = List.filled(myComponents.length, null);

    for (int i = 0; i < myComponents.length; i++) {
      messages[myComponentSlots[i]] = CovertComponent(
          roundPubkey: roundPubKey,
          signature: blindSigs[i],
          component: myComponents[i]);
    }
    if (messages.any((element) => element == null)) {
      throw FusionError('Messages list includes null values.');
    }

    final targetDateTime = DateTime.fromMillisecondsSinceEpoch(
        ((covertT0 + Protocol.T_START_COMPS) * 1000).toInt());
    covert.scheduleSubmissions(targetDateTime, messages);

    // While submitting, we download the (large) full commitment list.
    msg = await IO.recv([ReceiveMessages.allCommitments],
        socketWrapper: _socketWrapper!,
        connection: _connection!,
        timeout: Duration(seconds: Protocol.T_START_SIGS.toInt()));
    AllCommitments allCommitmentsMsg = msg as AllCommitments;
    List<InitialCommitment> allCommitments =
        allCommitmentsMsg.initialCommitments.map((commitmentBytes) {
      return InitialCommitment.fromBuffer(commitmentBytes);
    }).toList();

    // Quick check on the commitment list.
    if (allCommitments.toSet().length != allCommitments.length) {
      throw FusionError('Commitments list includes duplicates.');
    }
    try {
      List<Uint8List> allCommitmentsBytes = allCommitments
          .map((commitment) => commitment.writeToBuffer())
          .toList();
      _myCommitmentIndexes =
          myCommitments.map((c) => allCommitmentsBytes.indexOf(c)).toList();
    } on Exception {
      throw FusionError('One or more of my commitments missing.');
    }

    remainingTime = Protocol.T_START_SIGS - covertClock();
    if (remainingTime < 0) {
      throw FusionError('took too long to download commitments list');
    }

    // Once all components are received, the server shares them with us:
    msg = await IO.recv([ReceiveMessages.shareCovertComponents],
        socketWrapper: _socketWrapper!,
        connection: _connection!,
        timeout: Duration(seconds: Protocol.T_START_SIGS.toInt()));

    ShareCovertComponents shareCovertComponentsMsg =
        msg as ShareCovertComponents;
    List<List<int>> allComponents = shareCovertComponentsMsg.components;
    bool skipSignatures = msg.getField(2) as bool;

    // Critical check on server's response timing.
    if (covertClock() > Protocol.T_START_SIGS) {
      throw FusionError('Shared components message arrived too slowly.');
    }

    covert.checkDone();

    try {
      _myComponentIndexes = myComponents
          .map((c) => allComponents
              .indexWhere((element) => ListEquality<int>().equals(element, c)))
          .toList();
      if (_myComponentIndexes.contains(-1)) {
        throw FusionError('One or more of my components missing.');
      }
    } on StateError {
      throw FusionError('One or more of my components missing.');
    }

    // TODO check the components list and see if there are enough inputs/outputs
    // for there to be significant privacy.

    List<List<int>> allCommitmentsBytes = allCommitments
        .map((commitment) => commitment.writeToBuffer().toList())
        .toList();
    List<int> sessionHash = Utilities.calcRoundHash(_lastHash, roundPubKey,
        roundTime.toInt(), allCommitmentsBytes, allComponents);

    // Validate session hash to prevent mismatch error.
    if (!shareCovertComponentsMsg.sessionHash.equals(sessionHash)) {
      throw FusionError('Session hash mismatch (bug!)');
    }

    // Handle covert signature submission.
    if (!shareCovertComponentsMsg.skipSignatures) {
      Utilities.debugPrint("starting covert signature submission");
      _updateStatus(
        status: FusionStatus.running,
        info: "covert submission: signatures",
      );

      // Check for duplicate server components.
      if (allComponents.toSet().length != allComponents.length) {
        throw FusionError('Server component list includes duplicates.');
      }

      // Build transaction from components and session hash.
      (Transaction, List<int>) txData =
          Transaction.txFromComponents(allComponents, sessionHash);
      Transaction tx = txData.$1;
      List<int> inputIndices = txData.$2;

      // Initialize list to store covert transaction signature messages.
      List<CovertTransactionSignature?> covertTransactionSignatureMessages =
          List<CovertTransactionSignature?>.filled(myComponents.length, null);

      // Combine transaction input indices and their corresponding inputs.
      List<(int, Input)> myCombined = List<(int, Input)>.generate(
        inputIndices.length,
        (index) => (inputIndices[index], tx.Inputs[index]),
      );

      // Sign the covert transaction.
      for (int i = 0; i < myCombined.length; i++) {
        int cIdx = myCombined[i].$1;
        Input inp = myCombined[i].$2;

        // Skip if not my input.
        int myCompIdx = _myComponentIndexes.indexOf(cIdx);
        if (myCompIdx == -1) continue; // not my input

        // Extract public and private keys.
        // TODO fix getPubKey, getPrivKey.
        // See https://github.com/Electron-Cash/Electron-Cash/blob/master/electroncash_plugins/fusion/fusion.py#L971C44-L971C44
        String pubKey = inp.getPubKey(0); // cast/convert to PublicKey?
        String sec = inp.getPrivKey(0); // cast/convert to SecretKey?

        // Calculate sighash for signing.
        List<int> preimageBytes = tx.serializePreimage(i, 0x41, useCache: true);
        crypto.Digest sighash =
            crypto.sha256.convert(crypto.sha256.convert(preimageBytes).bytes);

        // Generate 32 random bytes for a bip340 signature.
        Uint8List aux = Utilities.getRandomBytes(32);

        // Generate signature.
        List<int> sig = utf8.encode(
            bip340.sign(sec, hex.encode(sighash.bytes), hex.encode(aux)));

        // Store the covert transaction signature
        covertTransactionSignatureMessages[myComponentSlots[myCompIdx]] =
            CovertTransactionSignature(txsignature: sig, whichInput: i);
      }

      // Schedule covert submissions.
      DateTime covertT0DateTime = DateTime.fromMillisecondsSinceEpoch(
          covertT0.toInt() * 1000); // covertT0 is in seconds
      covert.scheduleSubmissions(
          covertT0DateTime
              .add(Duration(milliseconds: Protocol.T_START_SIGS.toInt())),
          covertTransactionSignatureMessages);

      // Wait for server's fusion result within the expected time frame.
      int timeoutMillis = (Protocol.T_EXPECTING_CONCLUSION -
              Protocol.TS_EXPECTING_COVERT_COMPONENTS)
          .toInt();
      Duration timeout = Duration(milliseconds: timeoutMillis);
      msg = await IO.recv([ReceiveMessages.fusionResult],
          socketWrapper: _socketWrapper!,
          connection: _connection!,
          timeout: timeout);

      // Critical check on server's response timing.
      if (covertClock() > Protocol.T_EXPECTING_CONCLUSION) {
        throw FusionError('Fusion result message arrived too slowly.');
      }

      // Verify if the covert operation was successful.
      covert.checkDone();
      FusionResult fusionResultMsg = msg as FusionResult;
      if (fusionResultMsg.ok) {
        List<List<int>> allSigs = msg.txsignatures;

        // Assemble and complete the transaction.
        if (allSigs.length != tx.Inputs.length) {
          throw FusionError('Server gave wrong number of signatures.');
        }
        for (int i = 0; i < allSigs.length; i++) {
          List<int> sigBytes = allSigs[i];
          String sig = base64.encode(sigBytes);
          Input inp = tx.Inputs[i];
          if (sig.length != 64) {
            throw FusionError('server relayed bad signature');
          }
          inp.signatures = ['${sig}41'];
        }

        // Finalize transaction details and update wallet label.
        assert(tx.isComplete());
        String txHex = tx.serialize();

        _txId = tx.txid();
        String sumInStr = Utilities.formatSatoshis(sumIn, numZeros: 8);
        String feeStr = totalFee.toString();
        String feeLoc = 'fee';

        String label =
            "CashFusion ${_coins.length}⇢${_outputs.length}, $sumInStr BCH (−$feeStr sats $feeLoc)";

        Utilities.updateWalletLabel(_txId, label);
      } else {
        // If not successful, identify bad components.
        _badComponents = msg.badComponents.toSet();
        if (_badComponents
            .intersection(_myComponentIndexes.toSet())
            .isNotEmpty) {
          Utilities.debugPrint(
              "bad components: ${_badComponents.toList()} mine: ${_myComponentIndexes.toList()}");
          throw FusionError("server thinks one of my components is bad!");
        }
      }
    } else {
      // Case where 'skip_signatures' is True.
      Set<int> badComponents = <int>{};
    }

    // Begin Blame phase logic.

    // Set the time when this phase of the protocol should stop.
    covert.setStopTime((covertT0 + Protocol.T_START_CLOSE_BLAME).floor());

    // Update status to indicate that proofs are being sent.
    _updateStatus(
      status: FusionStatus.running,
      info: "round failed - sending proofs",
    );
    Utilities.debugPrint("sending proofs");

    // Create a list of commitment indexes, but leaving out mine.
    List<int> othersCommitmentIdxes = [];
    for (int i = 0; i < allCommitments.length; i++) {
      if (!_myCommitmentIndexes.contains(i)) {
        othersCommitmentIdxes.add(i);
      }
    }

    // Ensure that the count is accurate.
    int N = othersCommitmentIdxes.length;
    assert(N == allCommitments.length - myCommitments.length);
    if (N == 0) {
      throw FusionError(
          "Fusion failed with only me as player -- I can only blame myself.");
    }

    // Determine to whom the proofs should be sent.
    List<InitialCommitment> dstCommits = [];
    for (int i = 0; i < myCommitments.length; i++) {
      dstCommits.add(allCommitments[
          othersCommitmentIdxes[Utilities.randPosition(randomNumber, N, i)]]);
    }

    // Generate the encrypted proofs.
    List<String> encproofs = List<String>.filled(myCommitments.length, '');

    // Loop through all the destination commitments to generate encrypted proofs.
    for (int i = 0; i < dstCommits.length; i++) {
      InitialCommitment msg = dstCommits[i];
      Proof proof = myProofs[i];
      proof.componentIdx = _myComponentIndexes[i];

      try {
        // Encrypt the proof using the communication key.
        Uint8List encryptedData = await encrypt(
            proof.writeToBuffer(), Uint8List.fromList(msg.communicationKey),
            padToLength: 80);
        encproofs[i] = String.fromCharCodes(encryptedData);
      } on EncryptionFailed {
        // The communication key was bad (probably invalid x coordinate).
        // We will just send a blank.  They can't even blame us since there is no private key! :)
        continue;
      }
    }

    // Convert the list of encrypted proofs (strings) to a list of Uint8List
    // so that they can be transmitted.
    List<Uint8List> encodedEncproofs =
        encproofs.map((e) => Uint8List.fromList(e.codeUnits)).toList();

    // Send the encrypted proofs and the random number used to the server.
    // The comment is asking if this call should be awaited or not,
    // depending on whether the program needs to pause execution until the data is sent.
    // TODO should this be unawaited?
    await IO.send(
      MyProofsList(
          encryptedProofs: encodedEncproofs, randomNumber: randomNumber),
      socketWrapper: _socketWrapper!,
      connection: _connection!,
    );

    // Update the status to indicate that the program is in the process of checking proofs.
    _updateStatus(
      status: FusionStatus.running,
      info: "round failed - checking proofs",
    );

    // Receive the list of proofs from the other parties
    Utilities.debugPrint("receiving proofs");
    msg = await IO.recv([ReceiveMessages.theirProofsList],
        socketWrapper: _socketWrapper!,
        connection: _connection!,
        timeout: Duration(seconds: (2 * Protocol.STANDARD_TIMEOUT).round()));

    // Initialize a list to store proofs that should be blamed for failure.
    List<Blames_BlameProof> blames = [];

    // Initialize a counter to keep track of the number of valid input components found.
    int countInputs = 0;

    // Cast the received message to TheirProofsList for type safety.
    TheirProofsList proofsList = msg as TheirProofsList;

    // Declare variables to hold the private key and initial commitment for each proof.
    List<int>? privKey;
    InitialCommitment commitmentBlob;

    // Iterate over each received proof to validate or blame them.
    for (var i = 0; i < proofsList.proofs.length; i++) {
      TheirProofsList_RelayedProof rp = msg.proofs[i];
      try {
        // Obtain private key and commitment information for the current proof.
        privKey = privKeys[rp.dstKeyIdx];
        commitmentBlob = allCommitments[rp.srcCommitmentIdx];
      } on RangeError catch (_) {
        // If the indices are invalid, throw an error.
        throw FusionError("Server relayed bad proof indices");
      }

      final List<int> sKey;
      final Uint8List proofBlob;

      try {
        // Decrypt the proof, storing the decrypted data and the symmetric key used.
        final result = await decrypt(
          Uint8List.fromList(rp.encryptedProof),
          Uint8List.fromList(privKey),
        );
        proofBlob = result.decrypted;
        sKey = result.symmetricKey;
      } on Exception catch (_) {
        // If decryption fails, add the proof to the blame list.
        Utilities.debugPrint("found an undecryptable proof");
        blames.add(
          Blames_BlameProof(
            whichProof: i,
            privkey: privKey,
            blameReason: 'undecryptable',
          ),
        );
        continue;
      }

      // Parsing the received commitment.
      InitialCommitment commitment = InitialCommitment();
      try {
        commitment.mergeFromBuffer(
            commitmentBlob as List<int>); // Method to parse protobuf data.
      } on FormatException catch (_) {
        // If the commitment data is invalid, throw an error.
        throw FusionError("Server relayed bad commitment");
      }

      InputComponent? inpComp;

      try {
        // Validate the proof internally, adding it to the list of validated proofs if it's valid.
        // Convert allComponents to List<Uint8List>, badComponents to List<int>, and round componentFeeRate.
        List<Uint8List> allComponentsUint8 = allComponents
            .map((component) => Uint8List.fromList(component))
            .toList();
        // Convert badComponents to List<int>
        List<int> badComponentsList = _badComponents.toList();
        // Convert componentFeeRate to int if it's double.
        int componentFeerateInt = _serverParams!.componentFeeRate;

        inpComp = validateProofInternal(
          proofBlob,
          commitment,
          allComponentsUint8,
          badComponentsList,
          componentFeerateInt,
        );
      } on Exception catch (e) {
        // If the proof is invalid, add it to the blame list.
        Utilities.debugPrint("found an erroneous proof: ${e.toString()}");
        final blameProof = Blames_BlameProof();
        blameProof.whichProof = i;
        blameProof.sessionKey = sKey;
        blameProof.blameReason = e.toString();
        blames.add(blameProof);
        continue;
      }

      // If inpComp is not null, this means the proof was valid.
      if (inpComp != null) {
        countInputs++;
        try {
          // Perform additional validation by checking against the blockchain.
          Utilities.checkInputElectrumX(inpComp);
        } on Exception catch (e) {
          // If the input component doesn't match the blockchain, add the proof to the blame list.
          Utilities.debugPrint(
            "found a bad input [${rp.srcCommitmentIdx}]: "
            "$e (${(Uint8List.fromList(inpComp.prevTxid.reversed.toList())).toHex}:${inpComp.prevIndex})",
          );

          final blameProof = Blames_BlameProof();
          blameProof.whichProof = i;
          blameProof.sessionKey = sKey;
          blameProof.blameReason = 'input does not match blockchain: $e';
          blameProof.needLookupBlockchain = true;
          blames.add(blameProof);
        } catch (e) {
          // If we can't check against the blockchain for some reason, log a message.
          Utilities.debugPrint(
            "verified an input internally, but was unable to check it against blockchain: $e",
          );
        }
      }
    }
    Utilities.debugPrint(
        "checked ${msg.proofs.length} proofs, $countInputs of them inputs");

    // Send the blame list to the server
    // TODO should this be unawaited?
    await IO.send(
      Blames(blames: blames),
      socketWrapper: _socketWrapper!,
      connection: _connection!,
    );
    Utilities.debugPrint("sending blames");

    // Update the status to indicate that the program is waiting for the round to restart.
    _updateStatus(
      status: FusionStatus.running,
      info: "awaiting restart",
    );

    // Await the final 'restartround' message. It might take some time
    // to arrive since other players might be slow, and then the server
    // itself needs to check blockchain.
    await IO.recv([ReceiveMessages.restartRound],
        socketWrapper: _socketWrapper!,
        connection: _connection!,
        timeout: Duration(
            seconds: 2 *
                (Protocol.STANDARD_TIMEOUT.round() +
                    Protocol.BLAME_VERIFY_TIME.round())));

    // Return true to indicate successful execution of this part.
    return true;
  } // /run_round()
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:fixnum/fixnum.dart';
import 'package:fusiondart/src/comms.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/covert.dart';
import 'package:fusiondart/src/encrypt.dart';
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/models/address.dart';
import 'package:fusiondart/src/models/blind_signature_request.dart';
import 'package:fusiondart/src/models/input.dart';
import 'package:fusiondart/src/models/output.dart';
import 'package:fusiondart/src/models/protobuf.dart';
import 'package:fusiondart/src/models/transaction.dart';
import 'package:fusiondart/src/pedersen.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:fusiondart/src/socketwrapper.dart';
import 'package:fusiondart/src/util.dart';
import 'package:fusiondart/src/validation.dart';
import 'package:pointycastle/export.dart';
import 'package:protobuf/protobuf.dart';

/// Fusion class is responsible for coordinating the CashFusion transaction process.
///
/// It maintains the state and controls the flow of a fusion operation.
class Fusion {
  // Private late finals used for dependency injection.
  // Disabled because _getUnusedReservedChangeAddresses fulfills all requirements.
  late final Future<List<Address>> Function() _getAddresses;
  late final Future<List<Input>> Function(String address) _getInputsByAddress;
  late final Future<Set<Transaction>> Function(String address)
      _getTransactionsByAddress;
  /*late final Future<Address> Function() _createNewReservedChangeAddress;*/
  late final Future<List<Address>> Function(int numberOfAddresses)
      _getUnusedReservedChangeAddresses;
  late final Future<({InternetAddress host, int port})> Function()
      _getSocksProxyAddress;

  /// Constructor that sets up a Fusion object.
  Fusion({
    required Future<List<Address>> Function() getAddresses,
    required Future<List<Input>> Function(String address) getInputsByAddress,
    required Future<Set<Transaction>> Function(String address)
        getTransactionsByAddress,
    /*required Future<Address> Function() createNewReservedChangeAddress,*/
    required Future<List<Address>> Function(int numberOfAddresses)
        getUnusedReservedChangeAddresses,
    required Future<({InternetAddress host, int port})> Function()
        getSocksProxyAddress,
  }); /*{
    initializeConnection(host, port);
  }

  Future<void> initializeConnection(String host, int port) async {
    Socket socket = await Socket.connect(host, port);
    connection = Connection()..socket = socket;
  }
  */

  // Host and port variables.
  // TODO parameterize; should these be fed in as parameters upon construction/instantiation?
  bool serverSsl = false;

  String serverHost = "cashfusion.stackwallet.com"; // CashFusion server host.
  // Alternative host: `"fusion.servo.cash"`.

  int serverPort = 8787; // Server port.
  // For use with the alternative host above, use `8789`.

  String torHost = ""; // Tor SOCKS5 proxy host.
  // Could use InternetAddress.looopbackIPv4 or InternetAddress.loopbackIPv6
  int torPort = 0; // Tor SOCKS5 proxy port.

  int covertPort = 0; // Covert connection port.
  bool covertSSL = false; // Use SSL for covert connection?

  int roundCount = 0; // Tracks the number of CashFusion rounds.
  String txId = ""; // Holds a transaction ID.

  // Various state variables.
  Set<Input> coins = {}; // "coins"≈"inputs" in the python source.
  List<Output> outputs = [];
  List<Address> changeAddresses = [];

  bool serverConnectedAndGreeted = false; // Have we connected to the server?
  bool stopping = false; // Should fusion stop?
  bool stoppingIfNotRunning = false; // Should fusion stop if it's not running?
  String stopReason = ""; // Specifies the reason for stopping the operation.

  (String, String) status = ("", ""); // Holds the current status as a Record.
  Connection? connection; // Holds the active Connection object.

  int numComponents = 0; // Tracks the number of components.
  double componentFeeRate = 0; // Defines the fee rate for each component.
  double minExcessFee = 0; // Specifies the minimum excess fee.
  double maxExcessFee = 0; // Specifies the maximum excess fee.
  List<int> availableTiers = []; // Lists the available CashFusion tiers.

  int maxOutputs = 0; // Maximum number of outputs allowed.
  int safetySumIn = 0; // The sum of all inputs, used for safety checks.
  Map<int, int> safetyExcessFees = {}; // Holds safety excess fees.
  Map<int, List<int>> tierOutputs = {}; // Associates tiers with outputs.
  // Not sure if this should be using the Output model.

  int inactiveTimeLimit = 600000; // [ms] 10 minutes in milliseconds.
  int tier = 0; // Currently selected CashFusion tier.
  double beginTime = 0.0; // [s] Represent time in seconds.
  List<int> lastHash = <int>[]; // Holds the last hash used in a fusion.
  List<Address> reservedAddresses = <Address>[]; // List of reserved addresses.
  int safetyExcessFee = 0; // Safety excess fee for the operation.
  DateTime tFusionBegin = DateTime.now(); // The timestamp when Fusion began.
  Uint8List covertDomainB = Uint8List(0); // Holds the covert domain in bytes.

  List<int>? txInputIndices; // Indices for transaction inputs.
  Transaction tx = Transaction(); // Holds the current Transaction object.
  List<int> myComponentIndexes = []; // Holds the indexes for the components.
  List<int> myCommitmentIndexes = []; // Holds the indexes for the commitments.
  Set<int> badComponents = {}; // The indexes of bad components.

  ({InternetAddress host, int port})? proxyInfo; // Holds the proxy information.

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
  int localHeight = 0; // TODO replace with blockchain height getter.
  bool autofuseCoinbase = false; // TODO link to a setting in the wallet.
  // https://github.com/Electron-Cash/Electron-Cash/blob/48ac434f9c7d94b335e1a31834ee2d7d47df5802/electroncash_plugins/fusion/conf.py#L68

  SocketWrapper? _socketWrapper;

  /// Method to initialize Fusion instance with necessary wallet methods.
  /// The methods injected here are used for various operations throughout the fusion process.
  void initFusion({
    required Future<List<Address>> Function() getAddresses,
    required Future<List<Input>> Function(String address) getInputsByAddress,
    required Future<Set<Transaction>> Function(String address)
        getTransactionsByAddress,
    // required Future<Address> Function() createNewReservedChangeAddress,
    required Future<List<Address>> Function(int numberOfAddresses)
        getUnusedReservedChangeAddresses,
    required Future<({InternetAddress host, int port})> Function()
        getSocksProxyAddress,
  }) {
    _getAddresses = getAddresses;
    _getInputsByAddress = getInputsByAddress;
    _getTransactionsByAddress = getTransactionsByAddress;
    // _createNewReservedChangeAddress = createNewReservedChangeAddress;
    _getUnusedReservedChangeAddresses = getUnusedReservedChangeAddresses;
    _getSocksProxyAddress = getSocksProxyAddress;
  }

  /// Adds Unspent Transaction Outputs (UTXOs) from [utxoList] to the `coins` list as `Input`s.
  ///
  /// Given a list of UTXOs [utxoList] (as represented by the `Record(String txid, int vout, int value)`),
  /// this method converts them to `Input` objects and appends them to the internal `coins`
  /// list, which will later be used in a fusion operation.
  ///
  /// Returns:
  ///   Future<void> Returns a future that completes when the coins have been added.
  Future<void> addCoinsFromWallet(
    List<(String txid, int vout, int value, List<int> pubKey)> utxoList,
  ) async {
    // TODO sanity check the state of `coins` before adding to it.

    // Convert each UTXO info to an Input and add to 'coins'.
    for (final utxoInfo in utxoList) {
      coins.add(Input.fromWallet(utxoInfo));
    }
    // TODO add validation and throw error if invalid UTXO detected
  }

  /// Adds a change address [address] to the `changeAddresses` list.
  ///
  /// Takes an `Address` object and adds it to the internal `changeAddresses` list,
  /// which is used to send back any remaining balance from a fusion operation.
  ///
  /// Returns:
  ///   A future that completes when the address has been added.
  Future<void> addChangeAddress(Address address) async {
    // Add address to List<Address> addresses[].
    changeAddresses.add(address);
  }

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
    print("DEBUG FUSION 223...fusion run....");
    try {
      try {
        // Check compatibility  - This was done in python version to see if fast libsec installed.
        // For now , in dart, just pass this test.
      } on Exception catch (e) {
        // handle exception, rethrow as a custom FusionError
        throw FusionError("Incompatible: $e");
      }

      // Check if can connect to Tor proxy, if not, raise FusionError. Empty String treated as no host.
      if (torHost.isNotEmpty &&
          torPort != 0 &&
          !await isTorPort(torHost, torPort)) {
        throw FusionError("Can't connect to Tor proxy at $torHost:$torPort");
      }

      try {
        // Check stop condition
        checkStop(running: false);
      } catch (e) {
        print(e);
      }

      try {
        // Check coins
        checkCoins();
      } catch (e) {
        print(e);
      }

      // Connect to server.
      status = ("connecting", "");
      try {
        connection = await openConnection(serverHost, serverPort,
            connTimeout: 5.0, defaultTimeout: 5.0, ssl: serverSsl);
      } catch (e) {
        print("Connect failed: $e");
        String sslstr = serverSsl ? ' SSL ' : '';
        throw FusionError(
            'Could not connect to $sslstr$serverHost:$serverPort');
      }

      // Once connection is successful, wrap operations inside this block.
      //
      // Within this block, version checks, downloads server params, handles coins and runs rounds.
      try {
        _socketWrapper = SocketWrapper(serverHost, serverPort);

        if (_socketWrapper == null) {
          throw FusionError('Could not connect to $serverHost:$serverPort');
        }
        await _socketWrapper!.connect();

        // Version check and download server params.
        await greet();

        _socketWrapper!.status();
        serverConnectedAndGreeted = true;
        notifyServerStatus(true);

        // In principle we can hook a pause in here -- user can insert coins after seeing server params.

        try {
          if (coins.isEmpty) {
            throw FusionError('Started with no coins');
          }
        } catch (e) {
          print(e);
          return;
        }

        await allocateOutputs();
        // In principle we can hook a pause in here -- user can tweak tier_outputs, perhaps cancelling some unwanted tiers.

        // Register for tiers, wait for a pool.
        await registerAndWait(_socketWrapper!);

        // launch the covert submitter
        CovertSubmitter covert = await startCovert();
        try {
          // Pool started. Keep running rounds until fail or complete.
          while (true) {
            roundCount += 1;
            if (await runRound(covert)) {
              break;
            }
          }
        } finally {
          covert.stop();
        }
      } finally {
        await (connection)?.close();
      }

      print("RETURNING early in fuse....");
      return;

      // Wait for transaction to show up in wallet.
      for (int i = 0; i < 60; i++) {
        if (stopping) {
          break; // not an error
        }

        if (Utilities.walletHasTransaction(txId)) {
          break;
        }

        await Future<void>.delayed(Duration(seconds: 1));
      }

      // Set status to 'complete' with txid.
      status = ('complete', 'txid: $txId');
    } on FusionError catch (err) {
      print('Failed: ${err}');
      status = ("failed", err.toString());
    } catch (exc) {
      print('Exception: ${exc}');
      status = ("Exception", exc.toString());
    } finally {
      clearCoins();
      if (status.$1 != 'complete') {
        for (Output output in outputs) {
          // TODO implement
          /*Util.unreserve_change_address(output.addr);*/
        }
        if (!serverConnectedAndGreeted) {
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
  void notifyServerStatus(bool b, {(String, String)? status}) {}

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
    if (stopping) {
      return;
    }
    if (notIfRunning) {
      if (stoppingIfNotRunning) {
        return;
      }
      stopReason = reason;
      stoppingIfNotRunning = true;
    } else {
      stopReason = reason;
      stopping = true;
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
    if (stopping || (!running && stoppingIfNotRunning)) {
      throw FusionError(stopReason);
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
    coins = {};
  }

  /// Adds new coins to the internal `coins` list.
  ///
  /// Takes a list of `Input` [newCoins] objects representing new coins and appends them to the internal coin list.
  void addCoins(List<Input> newCoins) {
    coins.addAll(newCoins);
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

  /// Generates a non-zero random double.
  ///
  /// Produces a random double value that is guaranteed not to be zero using a
  /// `Random` object parameter [rng] used for generating random numbers.
  ///
  /// Returns:
  ///   A non-zero random double value.
  static double nextNonZeroDouble(Random rng) {
    // Start with 0.0.
    double value = 0.0;

    // Generate a random double value between 0.0 and 1.0 until the value is not 0.0.
    while (value == 0.0) {
      value = rng.nextDouble();
    }

    // Return the non-zero random double value.
    return value;
  }

  /// Generates random outputs given specific parameters.
  ///
  /// Generates a list of random integer values for output tiers, adhering to the given parameters
  /// [rng], [inputAmount], [scale], [offset], and [maxCount].
  ///
  /// Returns:
  ///   A list of integer values representing the random outputs for the tier.
  static List<int>? randomOutputsForTier(
      Random rng, int inputAmount, int scale, int offset, int maxCount) {
    // Check if the input amount is insufficient.
    if (inputAmount < offset) {
      return [];
    }

    // Initialize required variables.
    double lambd = 1.0 / scale;
    int remaining = inputAmount;
    List<double> values =
        []; // List of fractional random values without offset.
    bool didBreak =
        false; // Add this flag to detect when a break is encountered.

    // Generate random values.
    for (int i = 0; i < maxCount + 1; i++) {
      double val = -lambd * log(nextNonZeroDouble(rng));
      remaining -= (val.ceil() + offset);
      if (remaining < 0) {
        didBreak = true; // If you break, set this flag to true.
        break;
      }
      values.add(val);
    }

    // Truncate values list if needed.
    if (!didBreak && values.length > maxCount) {
      values = values.sublist(0, maxCount);
    }

    if (values.isEmpty) {
      // Our first try put us over the limit, so we have nothing to work with.
      // (most likely, scale was too large).
      return [];
    }

    int desiredRandomSum = inputAmount - values.length * offset;
    assert(desiredRandomSum >= 0, 'desiredRandomSum is less than 0');
    // Now we need to rescale and round the values so they fill up the desired.
    // input amount exactly. We perform rounding in cumulative space so that the
    // sum is exact, and the rounding is distributed fairly.

    // Dart equivalent of itertools.accumulate.
    List<double> cumsum = [];
    double sum = 0;
    for (double value in values) {
      sum += value;
      cumsum.add(sum);
    }

    double rescale = desiredRandomSum / cumsum[cumsum.length - 1];
    List<int> normedCumsum = cumsum.map((v) => (rescale * v).round()).toList();
    assert(normedCumsum[normedCumsum.length - 1] == desiredRandomSum,
        'Last element of normedCumsum is not equal to desiredRandomSum');
    List<int> differences = [];
    differences.add(normedCumsum[0]); // First element
    for (int i = 1; i < normedCumsum.length; i++) {
      differences.add(normedCumsum[i] - normedCumsum[i - 1]);
    }

    List<int> result = differences.map((d) => offset + d).toList();
    assert(result.reduce((a, b) => a + b) == inputAmount,
        'Sum of result is not equal to inputAmount');
    return result;
  }

  /// Generates the components required for a fusion transaction.
  ///
  /// Given the number of blank components [numBlanks], input components [inputs],
  /// output components [outputs], and fee rate [feerate], this method generates and
  /// returns a list of `ComponentResult` objects that include all necessary
  /// details for a fusion transaction.
  ///
  /// Returns:
  ///   A list of `ComponentResult` objects containing all the components needed for the transaction.
  static List<ComponentResult> genComponents(
      int numBlanks, Set<Input> inputs, List<Output> outputs, int feerate) {
    // Sanity check
    assert(numBlanks >= 0);

    List<(Component, int)> components = [];

    // Set up Pedersen setup instance.
    Uint8List hBytes = Uint8List.fromList(
        [0x02] + 'CashFusion gives us fungibility.'.codeUnits);

    // Use secp256k1 curve
    ECDomainParameters params = ECDomainParameters('secp256k1');

    // Decode point
    ECPoint? hMaybe = params.curve.decodePoint(hBytes);

    // Check if point is null
    if (hMaybe == null) {
      throw Exception('Failed to decode point');
    }

    // Set point
    ECPoint H = hMaybe;

    // Set up Pedersen setup
    PedersenSetup setup = PedersenSetup(H);

    // Generate components
    for (Input input in inputs) {
      // Calculate fee
      int fee = Utilities.componentFee(input.sizeOfInput(), feerate);

      // Create input component
      Component comp = Component();
      comp.input = InputComponent(
          prevTxid: Uint8List.fromList(input.txid.reversed.toList()),
          prevIndex: input.index,
          pubkey: input.pubKey,
          amount: Int64(input.amount));

      // Add component and fee to list
      components.add((comp, input.amount - fee));
    }

    // Generate components for outputs
    for (Output output in outputs) {
      // Calculate fee
      List<int> script = output.addr.toScript();

      // Calculate fee
      int fee = Utilities.componentFee(output.sizeOfOutput(), feerate);

      // Create output component
      Component comp = Component();
      comp.output =
          OutputComponent(scriptpubkey: script, amount: Int64(output.value));

      // Add component and fee to list
      components.add((comp, -output.value - fee));
    }

    // Generate components for blanks
    for (int i = 0; i < numBlanks; i++) {
      Component comp = Component();
      comp.blank = BlankComponent();
      components.add((comp, 0));
    }

    // Initialize result list
    List<ComponentResult> resultList = [];

    // Generate components
    components.asMap().forEach((cnum, componentRecord) {
      // Generate salt
      Uint8List salt = Utilities.tokenBytes(32);
      componentRecord.$1.saltCommitment = Utilities.sha256(salt);
      Uint8List compser = componentRecord.$1.writeToBuffer();

      // Generate keypair
      (Uint8List, Uint8List) keyPair = Utilities.genKeypair();
      Uint8List privateKey = keyPair.$1;
      Uint8List pubKey = keyPair.$2;

      // Generate amount commitment
      Commitment commitmentInstance =
          setup.commit(BigInt.from(componentRecord.$2));
      Uint8List amountCommitment = commitmentInstance.pointPUncompressed;

      // Convert BigInt nonce to Uint8List
      Uint8List pedersenNonce = Uint8List.fromList(
          [int.parse(commitmentInstance.nonce.toRadixString(16), radix: 16)]);

      // Generating initial commitment
      InitialCommitment commitment = InitialCommitment(
          saltedComponentHash:
              Utilities.sha256(Uint8List.fromList([...compser, ...salt])),
          amountCommitment: amountCommitment,
          communicationKey: pubKey);

      // Write commitment to buffer
      Uint8List commitser = commitment.writeToBuffer();

      // Generating proof
      Proof proof =
          Proof(componentIdx: cnum, salt: salt, pedersenNonce: pedersenNonce);

      // Adding result to list
      resultList
          .add(ComponentResult(commitser, cnum, compser, proof, privateKey));
    });

    return resultList;
  }

  /// Receives a message from the server with the modern API (vs `recv()`).
  ///
  /// Receives an expected message from the server based on the given list of message names
  /// [expectedMsgNames]. Optionally, a [timeout] can be provided.
  ///
  /// TODO rename and return a GeneratedMessage or superclass that can include a FusionBegin
  ///
  /// Parameters:
  /// - [expectedMsgNames]: The list of expected message names.
  /// - [timeout] (optional): The timeout to use for the receive.
  ///
  /// Returns:
  ///   A future that completes with the received `GeneratedMessage`.
  ///
  /// Throws:
  /// - FusionError: if the connection is not initialized or a server error occurs.
  Future<GeneratedMessage> recv2(List<String> expectedMsgNames,
      {Duration? timeout}) async {
    // Check if connection has been initialized
    if (connection == null) {
      throw FusionError('Connection not initialized');
    }

    // Check if _socketWrapper has been initialized
    if (_socketWrapper == null) {
      throw FusionError('Socket wrapper not initialized');
    }
    // This throw could be removed if it's an issue

    // Receive the message from the server.
    (GeneratedMessage, String) result = await recvPb2(
        _socketWrapper!, connection!, ServerMessage, expectedMsgNames,
        timeout: timeout);

    // Extract the message and message type.
    GeneratedMessage submsg = result.$1;
    String mtype = result.$2;

    // Check if the message type is an error.
    if (mtype == 'error') {
      throw FusionError('server error: ${result.$1.toString()}');
    }

    // Return the message.
    return submsg;
  }

  /// Receives a message from the server.
  ///
  /// [DEPRECATED]
  ///
  /// TODO rename or remove.
  ///
  /// Returns:
  ///   A future that completes with the received `GeneratedMessage`.
  ///
  /// Throws:
  /// - FusionError: if the connection is not initialized or a server error occurs.
  Future<GeneratedMessage> recv(List<String> expectedMsgNames,
      {Duration? timeout}) async {
    // DEPRECATED
    // TODO remove usages of this function.
    if (connection == null) {
      throw FusionError('Connection not initialized');
    }

    // Get the message from the server.
    (GeneratedMessage, String) result = await recvPb(
        connection!, ServerMessage, expectedMsgNames,
        timeout: timeout);

    // Extract the message and message type.
    GeneratedMessage submsg = result.$1;
    String mtype = result.$2;

    // Check if the message type is an error.
    if (mtype == 'error') {
      throw FusionError('server error: ${submsg.toString()}');
    }

    // Return the message.
    return submsg;
  }

  /// Sends a message to the server with the deprecated API.
  ///
  /// [DEPRECATED]
  ///
  /// TODO rename or remove
  ///
  /// Takes a `GeneratedMessage` object [submsg] and sends it to the server. Optionally,
  /// a [timeout] can be specified.
  Future<void> send(GeneratedMessage submsg, {Duration? timeout}) async {
    // Check if connection has been initialized.
    if (connection == null) {
      throw FusionError('Connection not initialized');
    }
    // Previously this code just printed an error; if it's an issue, comment out the throw.

    // Send the message to the server.
    return await sendPb(connection!, ClientMessage, submsg, timeout: timeout);
  }

  /// Sends a message to the server with the modern API (vs. `send()`).
  ///
  /// Sends a `GeneratedMessage` object [submsg] to the server using the provided
  /// [socketwrapper]. Optionally, a [timeout] can be specified.
  ///
  /// TODO rename
  ///
  /// Parameters:
  /// - [socketwrapper]: The SocketWrapper object to use for communication.
  /// - [submsg]: The GeneratedMessage to send.
  /// - [timeout] (optional): The timeout to use for the send.
  ///
  /// Returns:
  ///   A future that completes when the message has been sent.
  ///
  /// Throws:
  /// - FusionError: if the connection is not initialized.
  Future<void> send2(GeneratedMessage submsg, {Duration? timeout}) async {
    // Check if _socketWrapper has been initialized
    if (_socketWrapper == null) {
      throw FusionError('Socket wrapper not initialized');
    }

    // Check if connection has been initialized
    if (connection == null) {
      throw FusionError('Connection not initialized');
    }

    // Send the message to the server.
    return await sendPb2(_socketWrapper!, connection!, ClientMessage, submsg,
        timeout: timeout);
  }

  /// Initializes communication by sending a greeting message to the server.
  ///
  /// Initiates the handshake by sending a `ClientHello` message to the server
  /// using the given [socketwrapper] for communication.
  ///
  /// Returns:
  ///   A `Future<void>` that completes once the handshake is successful.
  ///
  /// Throws:
  ///   FusionError if there are problems with the server's configuration or if
  ///   an unexpected message type is received.
  Future<void> greet() async {
    // Create the ClientHello message with version and genesis hash.
    ClientHello clientHello = ClientHello(
        version: Uint8List.fromList(utf8.encode(Protocol.VERSION)),
        genesisHash: Utilities.getCurrentGenesisHash());

    // Wrap the ClientHello in a ClientMessage.
    ClientMessage clientMessage = ClientMessage()..clienthello = clientHello;

    /*
    Connection greet_connection_1 = Connection.withoutSocket();
    // Let's move this up a level to the fusion_run and pass it in...
    SocketWrapper socketwrapper = SocketWrapper(server_host, server_port);
    await socketwrapper.connect();
    */

    // Send the message to the server.
    // TODO should this be unawaited?
    await send2(clientMessage);

    // Wait for a ServerHello message in reply.
    GeneratedMessage replyMsg = await recv2(['serverhello']);

    // Process the ServerHello message.
    if (replyMsg is ServerMessage) {
      ServerHello reply = replyMsg.serverhello;

      // Extract and set various server parameters.
      numComponents = reply.numComponents;
      componentFeeRate = reply.componentFeerate.toDouble();
      minExcessFee = reply.minExcessFee.toDouble();
      maxExcessFee = reply.maxExcessFee.toDouble();
      availableTiers = reply.tiers.map((tier) => tier.toInt()).toList();

      // Enforce some sensible limits, in case server is crazy
      if (componentFeeRate > Protocol.MAX_COMPONENT_FEERATE) {
        throw FusionError('excessive component feerate from server');
      }
      if (minExcessFee > 400) {
        // note this threshold should be far below MAX_EXCESS_FEE
        throw FusionError('excessive min excess fee from server');
      }
      if (minExcessFee > maxExcessFee) {
        throw FusionError('bad config on server: fees');
      }
      if (numComponents < Protocol.MIN_TX_COMPONENTS * 1.5) {
        throw FusionError('bad config on server: num_components');
      }
    } else {
      throw Exception(
          'Received unexpected message type: ${replyMsg.runtimeType}');
    }

    return;
  }

  /// Selects coins for fusion.
  ///
  /// Takes a set of `Input` objects [_coins] and returns a Record containing
  /// a list of eligible inputs, a list of ineligible inputs, the sum of the
  /// values of the eligible buckets, a boolean flag indicating if there are
  /// unconfirmed coins, and a boolean flag indicating if there are coinbase
  /// coins.
  ///
  /// TODO utilize a response class.
  ///
  /// Parameters:
  /// - [_coins]: The set of coins from which to select.
  ///
  /// Returns:
  ///   A `Future<(
  ///   List<(String, List<Input>)>, // Eligible
  ///   List<(String, List<Input>)>, // Ineligible
  ///   int, // sumValue
  ///   bool, // hasUnconfirmed
  ///   bool // hasCoinbase
  ///   )>` that completes with a Record containing the eligible inputs, ineligible inputs,
  ///   sum of the values of the eligible buckets, a boolean flag indicating if there are
  ///   unconfirmed coins, and a boolean flag indicating if there are coinbase coins.
  Future<
      (
        List<(String, List<Input>)>, // Eligible
        List<(String, List<Input>)>, // Ineligible
        int, // sumValue
        bool, // hasUnconfirmed
        bool // hasCoinbase
      )> selectCoins(Set<Input> _coins) async {
    Set<(String, List<Input>)> eligible = {}; // List of eligible inputs.
    Set<(String, List<Input>)> ineligible = {}; // List of ineligible inputs.
    bool hasUnconfirmed = false; // Are there unconfirmed coins?
    bool hasCoinbase = false; // Are there coinbase coins?
    int sumValue = 0; // Sum of the values of the eligible `Input`s.
    int mincbheight = localHeight + COINBASE_MATURITY;

    // Loop through the addresses in the wallet.
    for (Address address in await _getAddresses()) {
      // Get the coins for the address.
      List<Input> acoins = await _getInputsByAddress(address.addr);

      // Check if the address has any coins.
      if (acoins.isEmpty) continue;

      // Bool flag to indicate if the address is good (eligible).
      bool good = true;

      // TODO check if address is frozen
      /*
      if (wallet.frozenAddresses.contains(address)) {
        good = false;
      }
      */

      // Loop through the coins and check for eligibility.
      for (var i = 0; i < acoins.length; i++) {
        // Get the coin.
        var c = acoins[i];

        // Add the amount to the sum.
        sumValue += c.amount;

        // TODO check for tokens, maturity, etc.
        // TODO DO NOT TEST THIS WITH A WALLET WITH TOKENS OR YOU MAY LOSE THEM !!!
        /*
        good = good &&
            (i < 3 &&
                c['token_data'] == null &&
                c['slp_token'] == null &&
                !c['is_frozen_coin'] &&
                (!c['coinbase'] || c['height'] <= mincbheight)); // where `int mincbheight = localHeight + COINBASE_MATURITY;`

        if (c['height'] <= 0) {
          good = false;
          hasUnconfirmed = true;
        }

        hasCoinbase = hasCoinbase || c['coinbase'];
        */
      }
      if (good) {
        // Add the address and coins to the eligible list.
        eligible.add((address.addr, acoins));
      } else {
        // Add the address and coins to the ineligible list.
        ineligible.add((address.addr, acoins));
      }
    }

    // Return the Record.
    return (
      eligible.toList(),
      ineligible.toList(),
      sumValue,
      hasUnconfirmed,
      hasCoinbase
    );
  }

  /// Selects random coins for fusion.
  ///
  /// Takes a double [fraction] and a list of eligible buckets [eligible] and returns a list of
  /// random coins.
  ///
  /// Parameters:
  /// - [fraction]: The fraction of eligible `Input`s to select.
  /// - [eligible]: The list of eligible `Input`s.
  ///
  /// Returns:
  ///   A `Future<Set<Input>>` that completes with a list of random coins.
  Future<Set<Input>> selectRandomCoins(
      double fraction, List<(String, List<Input>)> eligible) async {
    // Shuffle the eligible buckets.
    var addrCoins = List<(String, List<Input>)>.from(eligible);
    addrCoins.shuffle();

    // Initialize the result set.
    Set<String> resultTxids = {};

    // Initialize the result list.
    Set<Input> result = {};

    // Counts the number of coins in the result so far.
    int numCoins = 0;

    // Counts the number of attempts to select coins.
    int maxAttempts = 100;

    // Counts the number of attempts to select coins.
    int numAttempts = 0;

    // Selection loop.
    //
    // This was added because the original code was failing to select a bucket
    // with coins when the number of coins was low.  This loop will try to select
    // a bucket with coins if the number of coins is low and we've tried to select
    // coins randomly over 100 (maxAttempts) times.
    while (true) {
      // Loop through each coin and check it.
      for (var record in addrCoins) {
        // Get the address and coins.
        var addr = record.$1;
        var acoins = record.$2;

        // Check if we have enough coins.
        if (numCoins >= DEFAULT_MAX_COINS) {
          // We have enough coins, so break.
          break;
        } else if (numCoins + acoins.length > DEFAULT_MAX_COINS) {
          // We have too many coins, so truncate the coins.
          continue;
        }

        // Check if we should skip this bucket.
        if (Random().nextDouble() > fraction) {
          continue;
        }

        // Semi-linkage check
        //
        // We consider all txids involving the address, historical and current.

        // Get the transactions for the address.
        Set<Transaction> ctxs = await _getTransactionsByAddress(addr);

        // Extract the txids from the transactions.
        Set<String> ctxids = ctxs.map((tx) {
          return tx.txid();
        }).toSet();

        // Check if there are any collisions.
        var collisions = ctxids.intersection(resultTxids);

        // Check if we should skip this bucket.
        //
        // Note each collision gives a separate chance of discarding this bucket.
        if (Random().nextDouble() >
            pow(KEEP_LINKED_PROBABILITY, collisions.length)) {
          continue;
        }

        // Add the coins and txids to the result.
        numCoins += acoins.length;
        result.addAll(acoins);
        resultTxids.addAll(ctxids);
      }

      // Check if we have enough coins.
      //
      // If we don't and if we've tried to select coins randomly over 100 times,
      // then we'll try the first bucket which has coins.
      if (result.isEmpty && numAttempts > maxAttempts) {
        try {
          // Try to find a bucket with coins.
          var res = addrCoins.firstWhere((record) => record.$2.isNotEmpty).$2;
          result = res.toSet();
        } catch (e) {
          // Handle exception where all eligible buckets were cleared
          throw FusionError('No coins available');
        }
      } else if (result.isNotEmpty) {
        // We have enough coins, so break the selection loop.
        break;
      }

      numAttempts++;
    }

    // Return the result.
    return result;
  }

  /// Gets the fraction parameter used to help select coins.
  ///
  /// Takes an integer [sumValue] and returns a double representing the fraction
  /// of coins to select.
  ///
  /// TODO implement custom modes.
  ///
  /// Parameters:
  /// - [sumValue]: The sum of the values of the eligible buckets.
  ///
  /// Returns:
  ///  A double representing the fraction of coins to select.
  double getFraction(int sumValue) {
    String mode = 'normal'; // TODO get from wallet configuration
    // 'normal', 'consolidate', 'fan-out', etc.
    double fraction = 0.1;

    // TODO implement custom modes.
    /*
    if (mode == 'custom') {
      String selectType = walletConf.selector[0];
      double selectAmount = walletConf.selector[1];

      if (selectType == 'size' && sumValue.toInt() != 0) {
        fraction = COIN_FRACTION_FUDGE_FACTOR * selectAmount / sumValue;
      } else if (selectType == 'count' && selectAmount.toInt() != 0) {
        fraction = COIN_FRACTION_FUDGE_FACTOR / selectAmount;
      } else if (selectType == 'fraction') {
        fraction = selectAmount;
      }
      // Note: fraction at this point could be <0 or >1 but doesn't matter.
    } else */
    if (mode == 'consolidate') {
      fraction = 1.0;
    } else if (mode == 'normal') {
      fraction = 0.5;
    } else if (mode == 'fan-out') {
      fraction = 0.1;
    }

    return fraction;
  }

  /// Allocates outputs for transaction components.
  ///
  /// Uses server parameters and local constraints to determine the number and
  /// sizes of the outputs in a transaction through a [_socketWrapper].
  ///
  /// Returns:
  ///   A `Future<void>` that completes once the outputs are successfully allocated.
  ///
  /// Throws:
  /// - FusionError: if any constraints or limits are violated.
  Future<void> allocateOutputs() async {
    print("DBUG allocateoutputs 746");
    print("CHECK socketwrapper 746");

    // Check if the connection is initialized.  _socketWrapper will need to be initialized.
    if (_socketWrapper == null) {
      throw FusionError('Connection not initialized');
    }

    // Initial sanity checks.
    _socketWrapper!.status();
    assert(['setup', 'connecting'].contains(status.$1));

    // Get the coins.
    (
      List<(String, List<Input>)>, // Eligible
      List<(String, List<Input>)>, // Ineligible
      int, // sumValue
      bool, // hasUnconfirmed
      bool // hasCoinbase _selections = await selectCoins(_inputs);
    ) _selections = await selectCoins(coins);

    // Initialize the eligible set.
    Set<Input> eligible = {};

    // Loop through each key-value pair in the Map to extract Inputs and put them in the Set
    for ((String, List<Input>) inputList in _selections.$1) {
      for (Input input in inputList.$2) {
        if (!eligible.contains(input)) {
          // Shouldn't this be accomplished by the Set?
          eligible.add(input);
        }
      }
    }

    // Select random coins from the eligible set.
    Set<Input> inputs =
        await selectRandomCoins(getFraction(_selections.$3), _selections.$1);
    /*await selectRandomCoins(
            numComponents / eligible.length, _selections.$1);*/
    int numInputs = inputs.length; // Number of inputs selected.

    // Calculate limits on the number of components and outputs.
    int maxComponents = min(numComponents, Protocol.MAX_COMPONENTS);
    int maxOutputs = maxComponents - numInputs;

    // More sanity checks.
    if (maxOutputs < 1) {
      throw FusionError('Too many inputs ($numInputs >= $maxComponents)');
    }
    assert(maxOutputs >= 1);

    // Calculate the number of distinct inputs.
    int numDistinct = inputs.map((e) => e.value).toSet().length;
    int minOutputs = max(Protocol.MIN_TX_COMPONENTS - numDistinct, 1);
    if (maxOutputs < minOutputs) {
      throw FusionError(
          'Too few distinct inputs selected ($numDistinct); cannot satisfy output count constraint (>= $minOutputs, <= $maxOutputs)');
    }

    // Calculate the available amount for outputs.
    int sumInputsValue = inputs.map((e) => e.value).reduce((a, b) => a + b);
    int inputFees = inputs
        .map((e) =>
            Utilities.componentFee(e.sizeOfInput(), componentFeeRate.toInt()))
        .reduce((a, b) => a + b);
    int availForOutputs = sumInputsValue - inputFees - minExcessFee.toInt();

    // Calculate fees per output.
    int feePerOutput = Utilities.componentFee(34, componentFeeRate.toInt());
    int offsetPerOutput = Protocol.MIN_OUTPUT + feePerOutput;

    // Check if the selected inputs have sufficient value.
    if (availForOutputs < offsetPerOutput) {
      throw FusionError('Selected inputs had too little value');
    }

    // Initialize random seed for generating outputs.
    Random rng = Random();
    List<int> seed = List<int>.generate(32, (_) => rng.nextInt(256));

    // Allocate the outputs based on available tiers.
    //
    // The allocated outputs and excess fees are stored in instance variables.
    print("DBUG allocateoutputs 785");
    tierOutputs = {};
    Map<int, int> excessFees = <int, int>{};

    // Loop through each available tier to determine the optimal fee and outputs.
    for (int scale in availableTiers) {
      // Calculate the maximum fuzz fee for this tier, which is the scale divided by 1,000,000.
      int fuzzFeeMax = scale ~/ 1000000;

      // Reduce the maximum allowable fuzz fee considering the minimum and maximum
      // excess fees and the maximum limit defined in the Protocol.
      int fuzzFeeMaxReduced = min(
          fuzzFeeMax,
          min(Protocol.MAX_EXCESS_FEE - minExcessFee.toInt(),
              maxExcessFee.toInt()));

      // Ensure that the reduced maximum fuzz fee is non-negative.
      assert(fuzzFeeMaxReduced >= 0);

      // Randomly pick a fuzz fee in the range `[0, fuzzFeeMaxReduced]`.
      int fuzzFee = rng.nextInt(fuzzFeeMaxReduced + 1);

      // Reduce the available amount for outputs by the selected fuzz fee.
      int reducedAvailForOutputs = availForOutputs - fuzzFee;

      // If the reduced available amount for outputs is less than the offset per
      // output, skip to the next iteration.
      if (reducedAvailForOutputs < offsetPerOutput) {
        continue;
      }

      // Generate a list of random outputs for this tier.
      List<int>? outputs = randomOutputsForTier(
          rng, reducedAvailForOutputs, scale, offsetPerOutput, maxOutputs);
      if (outputs != null) {
        print(outputs);
      }

      // Check if the list of outputs is null or has fewer items than the minimum
      // required number of outputs.
      if (outputs == null || outputs.length < minOutputs) {
        continue;
      }

      // Adjust each output value by subtracting the fee per output.
      outputs = outputs.map((o) => o - feePerOutput).toList();

      // Ensure the total number of components (inputs + outputs) does not exceed
      // the maximum limit defined in the Protocol.
      assert(inputs.length + (outputs.length) <= Protocol.MAX_COMPONENTS);

      // Store the calculated excess fee for this tier.
      excessFees[scale] = sumInputsValue - inputFees - reducedAvailForOutputs;

      // Store the list of output values for this tier.
      tierOutputs[scale] = outputs;
    }

    print('Possible tiers: $tierOutputs');

    // Save some parameters for safety checks.
    safetySumIn = sumInputsValue;
    safetyExcessFees = excessFees;
    return;
  } // End of `allocateOutputs()`.

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
    // This used to be `dynamic`, but then recv and recv2 were changed to return
    // a GeneratedMessage.
    GeneratedMessage msg;

    // Initialize a map to store the outputs for each tier.
    Map<int, List<int>> tierOutputs = this.tierOutputs;

    // Sort the tiers in ascending order.
    List<int> tiersSorted = tierOutputs.keys.toList()..sort();

    // Check if tierOutputs is empty and throw an error if so.
    if (tierOutputs.isEmpty) {
      throw FusionError(
          'No outputs available at any tier (selected inputs were too small / too large).');
    }

    print('registering for tiers: $tiersSorted');

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
    await send2(clientMessage);

    // TODO type the status variable.
    (String, String) status = ('waiting', 'Registered for tiers');

    // TODO make Entry class or otherwise type this section.
    Map<dynamic, String> tiersStrings = {
      for (var entry in tierOutputs.entries)
        entry.key:
            (entry.key * 1e-8).toStringAsFixed(8).replaceAll(RegExp(r'0+$'), '')
    };

    // Main loop to receive updates from the server.
    while (true) {
      print("RECEIVE LOOP 870............DEBUG");
      // TODO type msg.  GeneratedMessage doesn't have a 'fusionbegin' getter which is used below.
      msg = await recv2(['tierstatusupdate', 'fusionbegin'],
          timeout: Duration(seconds: 10));

      /*if (msg == null) continue;*/

      // Check for a FusionBegin message.
      // TODO: Properly type the fieldInfoFusionBegin variable
      FieldInfo<dynamic>? fieldInfoFusionBegin =
          msg.info_.byName["fusionbegin"];
      if (fieldInfoFusionBegin == null) {
        throw FusionError('Expected field not found in message: fusionbegin');
      }

      // Validate that the received message is indeed a FusionBegin message.
      bool messageIsFusionBegin = msg.hasField(fieldInfoFusionBegin.tagNumber);
      if (messageIsFusionBegin) {
        print("DEBUG 867 Fusion Begin message...");
        break;
      } /* else {
        throw FusionError('Expected a FusionBegin message');
      }
      */

      // Prechecks before processing the received message.
      checkStop(running: false);
      checkCoins();

      // Initialize a variable to store field information for "tierstatusupdate" in the message.
      FieldInfo<dynamic>? fieldInfo = msg.info_.byName["tierstatusupdate"];
      // Check if the field exists in the message, if not, throw an error.
      if (fieldInfo == null) {
        throw FusionError(
            'Expected field not found in message: tierstatusupdate');
      }

      // Determine if the message contains a "TierStatusUpdate"
      bool messageIsTierStatusUpdate = msg.hasField(fieldInfo.tagNumber);
      print("DEBUG 889 getting tier update.");

      // If the message doesn't contain a "TierStatusUpdate", throw an error.
      if (!messageIsTierStatusUpdate) {
        throw FusionError('Expected a TierStatusUpdate message');
      }

      // Initialize a map to store the statuses from the TierStatusUpdate message.
      late Map<Int64, TierStatusUpdate_TierStatus> statuses;
      // Populate the statuses map if "TierStatusUpdate" exists in the message.
      if (messageIsTierStatusUpdate) {
        /*TierStatusUpdate tierStatusUpdate = msg.tierstatusupdate;*/
        TierStatusUpdate tierStatusUpdate =
            msg.getField(fieldInfo.tagNumber) as TierStatusUpdate;
        statuses = tierStatusUpdate.statuses;
      }

      // print("DEBUG 8892 statuses: $statuses.");
      // print("DEBUG 8893 statuses: ${statuses!.entries}.");

      // Initialize variables to store the maximum fraction and tier numbers.
      double maxfraction = 0.0;
      List<int> maxtiers = <int>[];
      int? besttime;
      int? besttimetier;

      // Loop through each entry in statuses to find the maximum fraction and best time.
      for (var entry in statuses.entries) {
        // TODO make Entry class or otherwise type this section

        // Calculate the fraction of players to minimum players.
        double frac = ((entry.value.players.toInt())) /
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
        if (stopwatch.elapsedMilliseconds > inactiveTimeLimit) {
          throw FusionError('stopping due to inactivity');
        }
        // TODO handle else case
      }
      // TODO handle else case

      // Final status assignment based on calculated variables
      if (besttime != null) {
        (String, String) status =
            ('waiting', 'Starting in ${besttime}s. $tiersString');
      } else if (maxfraction >= 1) {
        (String, String) status = ('waiting', 'Starting soon. $tiersString');
      } else if (displayBest.isNotEmpty || displayMid.isNotEmpty) {
        (String, String) status =
            ('waiting', '${(maxfraction * 100).round()}% full. $tiersString');
      } else {
        (String, String) status = ('waiting', tiersString);
      }
    } // End of while loop.  Loop exits with a break if a FusionBegin message is received.

    // Check if the field 'fusionbegin' exists in the message.
    FieldInfo<dynamic>? fieldInfoFusionBegin = msg.info_.byName["fusionbegin"];
    if (fieldInfoFusionBegin == null) {
      throw FusionError('Expected field not found in message: fusionbegin');
    }

    // Determine if the message contains a FusionBegin message.
    bool messageIsFusionBegin = msg.hasField(fieldInfoFusionBegin.tagNumber);

    // Check if the received message is a FusionBegin message.
    if (!messageIsFusionBegin) {
      throw FusionError('Expected a FusionBegin message');
    }

    // Record the time when the fusion process began
    tFusionBegin = DateTime.now();

    // Check if the received message is a ServerMessage.
    if (msg is! ServerMessage) {
      throw FusionError('Expected a ServerMessage');
    }

    // Retrieve the FusionBegin message from the ServerMessage.
    FusionBegin fusionBeginMsg = msg.fusionbegin;

    // Calculate how many seconds have passed since the stopwatch was started
    int elapsedSeconds = stopwatch.elapsedMilliseconds ~/ 1000;

    // Calculate the time discrepancy between the server and the client
    double clockMismatch = fusionBeginMsg.serverTime.toInt() -
        DateTime.now().millisecondsSinceEpoch / 1000;

    // Check if the clock mismatch exceeds the maximum allowed discrepancy
    if (clockMismatch.abs().toDouble() > Protocol.MAX_CLOCK_DISCREPANCY) {
      throw FusionError(
          "Clock mismatch too large: ${(clockMismatch.toDouble()).toStringAsFixed(3)}.");
    }

    // Retrieve the tier in which the fusion process will occur
    tier = fusionBeginMsg.tier.toInt();

    // Populate covertDomainB with the received covert domain information
    covertDomainB = Uint8List.fromList(fusionBeginMsg.covertDomain);

    // Retrieve additional information such as port, SSL status, and server time for the fusion process
    covertPort = fusionBeginMsg.covertPort;
    covertSSL = fusionBeginMsg.covertSsl;
    beginTime = fusionBeginMsg.serverTime.toDouble();

    // Calculate the initial hash value for the fusion process
    lastHash = Utilities.calcInitialHash(
        tier, covertDomainB, covertPort, covertSSL, beginTime);

    // Retrieve the output amounts for the given tier and prepare the output addresses
    List<int>? outAmounts = tierOutputs[tier];
    List<Address> outAddrs =
        await _getUnusedReservedChangeAddresses(outAmounts?.length ?? 0);

    // Populate reservedAddresses and outputs with the prepared amounts and addresses
    reservedAddresses = outAddrs;
    outputs = Utilities.zip(outAmounts ?? [], outAddrs)
        .map((pair) => Output(value: pair[0] as int, addr: pair[1] as Address))
        .toList();

    // Retrieve the safety excess fee for the given tier
    safetyExcessFee = safetyExcessFees[tier] ?? 0;

    print(
        "starting fusion rounds at tier $tier: ${coins.length} inputs and ${outputs.length} outputs");
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
    print("DEBUG START COVERT!");

    // Initialize status record/tuple
    (String, String) status = ('running', 'Setting up Tor connections');

    // Get the Tor host and port from the wallet configuration.
    ({InternetAddress host, int port}) proxyInfo =
        await _getSocksProxyAddress();

    // Set the Tor host and port.
    torHost = proxyInfo.host.address; // TODO make sure this is correct.
    torPort = proxyInfo.port;

    // Decode the covert domain and validate it.
    String covertDomain;
    try {
      covertDomain = utf8.decode(covertDomainB);
    } catch (e) {
      throw FusionError('badly encoded covert domain');
    }

    // Create a new CovertSubmitter instance.
    CovertSubmitter covert = CovertSubmitter(
        covertDomain,
        covertPort,
        covertSSL,
        torHost,
        torPort,
        numComponents,
        Protocol.COVERT_SUBMIT_WINDOW,
        Protocol.COVERT_SUBMIT_TIMEOUT);
    try {
      // Schedule Tor connections for the CovertSubmitter.
      covert.scheduleConnections(tFusionBegin,
          Duration(seconds: Protocol.COVERT_CONNECT_WINDOW.toInt()),
          numSpares: Protocol.COVERT_CONNECT_SPARES.toInt(),
          connectTimeout: Protocol.COVERT_CONNECT_TIMEOUT.toInt());

      /*
      print("DEBUG return early from covert");
      // Return the CovertSubmitter instance early.
      // TODO finish method.
      return covert;
      */

      // Loop a bit before we're expecting startRound, watching for status updates.
      final tend = tFusionBegin.add(Duration(
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
        (String, String) status = (
          'running',
          'Setting up Tor connections ($numConnected+$numSpareConnected out of $numComponents)'
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
    print("START OF RUN ROUND");

    // Initial round status and timeout calculation
    (String, String) status =
        ('running', 'Starting round ${roundCount.toString()}');
    int timeoutInSeconds =
        (2 * Protocol.WARMUP_SLOP + Protocol.STANDARD_TIMEOUT).toInt();

    // Await the start of round message from the server
    GeneratedMessage msg = await recv2(['startround'],
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

    // Validate the server's time against our local time
    final clockMismatch = roundTime -
        Int64((DateTime.now().millisecondsSinceEpoch / 1000).round());

    if (clockMismatch.abs() > Int64(Protocol.MAX_CLOCK_DISCREPANCY.toInt())) {
      throw FusionError(
          "Clock mismatch too large: ${clockMismatch.toInt().toStringAsPrecision(3)}.");
    }

    // Check that the warmup time was as expected
    final lag = covertT0 -
        (tFusionBegin.millisecondsSinceEpoch / 1000) -
        Protocol.WARMUP_TIME;
    if (lag.abs() > Protocol.WARMUP_SLOP) {
      throw FusionError(
          "Warmup period too different from expectation (|${lag.toStringAsFixed(3)}s| > ${Protocol.WARMUP_SLOP.toStringAsFixed(3)}s).");
    }
    tFusionBegin = DateTime.now();

    print("round starting at ${DateTime.now().millisecondsSinceEpoch / 1000}");

    // Calculate fees and sums for inputs and outputs
    final inputFees = coins
        .map((e) =>
            Utilities.componentFee(e.sizeOfInput(), componentFeeRate.toInt()))
        .reduce((a, b) => a + b);
    final outputFees =
        outputs.length * Utilities.componentFee(34, componentFeeRate.toInt());
    final sumIn = coins.map((e) => e.amount).reduce((a, b) => a + b);
    final sumOut = outputs.map((e) => e.value).reduce((a, b) => a + b);

    // Calculate total and excess fee and perform safety checks
    final totalFee = sumIn - sumOut;
    final excessFee = totalFee - inputFees - outputFees;
    final safeties = [
      sumIn == safetySumIn,
      excessFee == safetyExcessFee,
      excessFee <= Protocol.MAX_EXCESS_FEE,
      totalFee <= Protocol.MAX_FEE,
    ];

    // Abort the round if the safety checks fail
    if (!safeties.every((element) => element)) {
      throw Exception(
          "(BUG!) Funds re-check failed -- aborting for safety. ${safeties.toString()}");
    }

    // Extract round public key and blind nonce points from the server message
    final roundPubKey = startRoundMsg.roundPubkey;
    final blindNoncePoints = startRoundMsg.blindNoncePoints;
    if (blindNoncePoints.length != numComponents) {
      throw FusionError('blind nonce miscount');
    }

    // Generate components and related data
    int numBlanks = numComponents - coins.length - outputs.length;
    final List<ComponentResult> genComponentsResults =
        genComponents(numBlanks, coins, outputs, componentFeeRate.toInt());

    // Initialize lists to store various parts of the component data
    final List<Uint8List> myCommitments = [];
    final List<int> myComponentSlots = [];
    final List<Uint8List> myComponents = [];
    final List<Proof> myProofs = [];
    final List<Uint8List> privKeys = [];
    // TODO type
    final List<dynamic> pedersenAmount = [];
    final List<dynamic> pedersenNonce = [];

    // Populate the lists with data from the generated components
    for (ComponentResult genComponentResult in genComponentsResults) {
      myCommitments.add(genComponentResult.commitment);
      myComponentSlots.add(genComponentResult.counter);
      myComponents.add(genComponentResult.component);
      myProofs.add(genComponentResult.proof);
      privKeys.add(genComponentResult.privateKey);
      pedersenAmount.add(genComponentResult.pedersenAmount);
      pedersenNonce.add(genComponentResult.pedersenNonce);
    }
    // Sanity checks on the generated components
    assert(excessFee ==
        pedersenAmount.reduce(
            (a, b) => a + b)); // sanity check that we didn't mess up the above
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
    print("RETURNING EARLY FROM run round .....");
    return true;
    */

    // Perform pre-submission checks and prepare a random number for later use
    final randomNumber = Utilities.getRandomBytes(32);
    covert.checkOk();
    checkStop();
    checkCoins();

    // Check if _socketWrapper has been initialized.
    if (_socketWrapper == null) {
      throw FusionError('Connection not initialized');
    }

    // Send initial commitments, fees, and other data to the server
    await send2(PlayerCommit(
      initialCommitments: myCommitments,
      excessFee: Int64(excessFee),
      pedersenTotalNonce: pedersenNonce.cast<int>(),
      randomNumberCommitment: crypto.sha256.convert(randomNumber).bytes,
      blindSigRequests: blindSigRequests.map((r) => r.request).toList(),
    ));

    // Await blind signature responses from the server
    msg = await recv2(['blindsigresponses'],
        timeout: Duration(seconds: Protocol.T_START_COMPS.toInt()));

    // Validate type and length of the received message and perform a sanity-check on it
    if (msg is BlindSigResponses) {
      BlindSigResponses typedMsg = msg;
      assert(typedMsg.scalars.length == blindSigRequests.length);
    } else {
      // Handle the case where msg is not of type BlindSigResponses
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
          // Handle the case where msg is not of type BlindSigResponses
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
    print("starting covert component submission");
    status = ('running', 'covert submission: components');

    // If we fail after this point, we want to stop connections gradually and
    // randomly. We don't want to stop them all at once, since if we had already
    // provided our input components then it would be a leak to have them all drop at once.
    covert.setStopTime((covertT0 + Protocol.T_START_CLOSE).toInt());

    // Schedule covert submissions.
    List<CovertComponent?> messages = List.filled(myComponents.length, null);

    for (int i = 0; i < myComponents.length; i++) {
      messages[myComponentSlots[i]] = CovertComponent(
          roundPubkey: roundPubKey,
          signature: blindSigs[i] as List<int>?,
          component: myComponents[i]);
    }
    if (messages.any((element) => element == null)) {
      throw FusionError('Messages list includes null values.');
    }

    final targetDateTime = DateTime.fromMillisecondsSinceEpoch(
        ((covertT0 + Protocol.T_START_COMPS) * 1000).toInt());
    covert.scheduleSubmissions(targetDateTime, messages);

    // While submitting, we download the (large) full commitment list.
    msg = await recv2(['allcommitments'],
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
      myCommitmentIndexes =
          myCommitments.map((c) => allCommitmentsBytes.indexOf(c)).toList();
    } on Exception {
      throw FusionError('One or more of my commitments missing.');
    }

    remainingTime = Protocol.T_START_SIGS - covertClock();
    if (remainingTime < 0) {
      throw FusionError('took too long to download commitments list');
    }

    // Once all components are received, the server shares them with us:
    msg = await recv2(['sharecovertcomponents'],
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
      myComponentIndexes = myComponents
          .map((c) => allComponents
              .indexWhere((element) => ListEquality<int>().equals(element, c)))
          .toList();
      if (myComponentIndexes.contains(-1)) {
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
    List<int> sessionHash = Utilities.calcRoundHash(lastHash, roundPubKey,
        roundTime.toInt(), allCommitmentsBytes, allComponents);

    // Validate session hash to prevent mismatch error
    if (!ListEquality()
        .equals(shareCovertComponentsMsg.sessionHash, sessionHash)) {
      throw FusionError('Session hash mismatch (bug!)');
    }

    // Handle covert signature submission.
    if (!shareCovertComponentsMsg.skipSignatures) {
      print("starting covert signature submission");
      status = ('running', 'covert submission: signatures');

      // Check for duplicate server components.
      if (allComponents.toSet().length != allComponents.length) {
        throw FusionError('Server component list includes duplicates.');
      }

      // Build transaction from components and session hash.
      (Transaction, List<int>) txData =
          Transaction.txFromComponents(allComponents, sessionHash);
      Transaction tx = txData!.$1;
      List<int> inputIndices = txData!.$2;

      // Initialize list to store covert transaction signature messages
      List<CovertTransactionSignature?> covertTransactionSignatureMessages =
          List<CovertTransactionSignature?>.filled(myComponents.length, null);

      // Combine transaction input indices and their corresponding inputs
      List<(int, Input)> myCombined = List<(int, Input)>.generate(
        inputIndices.length,
        (index) => (inputIndices[index], tx.Inputs[index]),
      );

      // Sign the covert transaction.
      for (int i = 0; i < myCombined.length; i++) {
        int cIdx = myCombined[i].$1;
        Input inp = myCombined[i].$2;

        // Skip if not my input.
        int myCompIdx = myComponentIndexes.indexOf(cIdx);
        if (myCompIdx == -1) continue; // not my input

        // Extract public and private keys.
        String pubKey = inp.getPubKey(0); // cast/convert to PublicKey?
        String sec = inp.getPrivKey(0); // cast/convert to SecretKey?

        // Calculate sighash for signing.
        List<int> preimageBytes = tx.serializePreimage(i, 0x41, useCache: true);
        crypto.Digest sighash =
            crypto.sha256.convert(crypto.sha256.convert(preimageBytes).bytes);

        // Generate signature (dummy placeholder)
        // TODO implement
        // var sig = schnorr.sign(sec, sighash);
        List<int> sig = <int>[0, 1, 2, 3, 4]; // dummy placeholder

        // Store the covert transaction signature
        covertTransactionSignatureMessages[myComponentSlots[myCompIdx]] =
            CovertTransactionSignature(txsignature: sig, whichInput: i);
      }

      // Schedule covert submissions
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
      msg = await recv2(['fusionresult'], timeout: timeout);

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

        // Finalize transaction details and update wallet label
        assert(tx.isComplete());
        String txHex = tx.serialize();

        txId = tx.txid();
        String sumInStr = Utilities.formatSatoshis(sumIn, numZeros: 8);
        String feeStr = totalFee.toString();
        String feeLoc = 'fee';

        String label =
            "CashFusion ${coins.length}⇢${outputs.length}, $sumInStr BCH (−$feeStr sats $feeLoc)";

        Utilities.updateWalletLabel(txId, label);
      } else {
        // If not successful, identify bad components.
        badComponents = msg.badComponents.toSet();
        if (badComponents.intersection(myComponentIndexes.toSet()).isNotEmpty) {
          print(
              "bad components: ${badComponents.toList()} mine: ${myComponentIndexes.toList()}");
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
    status = ('running', 'round failed - sending proofs');
    print("sending proofs");

    // Create a list of commitment indexes, but leaving out mine.
    List<int> othersCommitmentIdxes = [];
    for (int i = 0; i < allCommitments.length; i++) {
      if (!myCommitmentIndexes.contains(i)) {
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

    // Parameters for elliptic curve cryptography.
    ECDomainParameters params = ECDomainParameters('secp256k1');

    // Loop through all the destination commitments to generate encrypted proofs.
    for (int i = 0; i < dstCommits.length; i++) {
      InitialCommitment msg = dstCommits[i];
      Proof proof = myProofs[i];
      proof.componentIdx = myComponentIndexes[i];

      // Decode the communication key from its byte form.
      ECPoint? communicationKeyPointMaybe =
          params.curve.decodePoint(Uint8List.fromList(msg.communicationKey));

      // Error handling in case the decoding fails.
      if (communicationKeyPointMaybe == null) {
        continue;
      }
      ECPoint communicationKeyPoint = communicationKeyPointMaybe;

      try {
        // Encrypt the proof using the communication key.
        Uint8List encryptedData = await encrypt(
            proof.writeToBuffer(), communicationKeyPoint,
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
    await send2(MyProofsList(
        encryptedProofs: encodedEncproofs, randomNumber: randomNumber));

    // Update the status to indicate that the program is in the process of checking proofs.
    status = ('running', 'round failed - checking proofs');

    // Receive the list of proofs from the other parties
    print("receiving proofs");
    msg = await recv2(['theirproofslist'],
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
      } on RangeError catch (e) {
        // If the indices are invalid, throw an error.
        throw FusionError("Server relayed bad proof indices");
      }

      List<int> sKey;
      Uint8List proofBlob;

      try {
        // Decrypt the received proof using the private key.
        BigInt eccPrivateKey =
            Utilities.parseBigIntFromBytes(Uint8List.fromList(privKey));
        ECPrivateKey privateKey = ECPrivateKey(eccPrivateKey, params);

        // Decrypt the proof, storing the decrypted data and the symmetric key used.
        (Uint8List, Uint8List) result =
            await decrypt(Uint8List.fromList(rp.encryptedProof), privateKey);
        proofBlob = result.$1; // First item is the decrypted data.
        sKey = result.$2; // Second item is the symmetric key.
      } on Exception catch (e) {
        // If decryption fails, add the proof to the blame list.
        print("found an undecryptable proof");
        blames.add(Blames_BlameProof(
            whichProof: i, privkey: privKey, blameReason: 'undecryptable'));
        continue;
      }

      // Parsing the received commitment.
      InitialCommitment commitment = InitialCommitment();
      try {
        commitment.mergeFromBuffer(
            commitmentBlob as List<int>); // Method to parse protobuf data.
      } on FormatException catch (e) {
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
        List<int> badComponentsList = badComponents.toList();
        // Convert componentFeeRate to int if it's double.
        int componentFeerateInt = componentFeeRate
            .round(); // or use .toInt() if you want to truncate instead of rounding.

        InputComponent? inpComp = validateProofInternal(proofBlob, commitment,
            allComponentsUint8, badComponentsList, componentFeerateInt);
      } on Exception catch (e) {
        // If the proof is invalid, add it to the blame list.
        print("found an erroneous proof: ${e.toString()}");
        Blames_BlameProof blameProof = Blames_BlameProof();
        blameProof.whichProof = i;
        blameProof.sessionKey = sKey;
        blameProof.blameReason = e.toString();
        blames.add(blameProof);
        continue;
      }

      // If inpComp is not null, this means the proof was valid.
      // TODO inpComp can't be null, so this logic will never run!  Make sure to change to a valid check!
      // TODO null safety feedback messages for inpComp
      if (inpComp != null) {
        countInputs++;
        try {
          // Perform additional validation by checking against the blockchain
          Utilities.checkInputElectrumX(inpComp);
        } on Exception catch (e) {
          // If the input component doesn't match the blockchain, add the proof to the blame list.
          print(
              "found a bad input [${rp.srcCommitmentIdx}]: $e (${inpComp.prevTxid.reversed.toList().toHex()}:${inpComp.prevIndex})");

          Blames_BlameProof blameProof = Blames_BlameProof();
          blameProof.whichProof = i;
          blameProof.sessionKey = sKey;
          blameProof.blameReason =
              'input does not match blockchain: ' + e.toString();
          blameProof.needLookupBlockchain = true;
          blames.add(blameProof);
        } catch (e) {
          // If we can't check against the blockchain for some reason, log a message.
          print(
              "verified an input internally, but was unable to check it against blockchain: ${e}");
        }
      }
    }
    print("checked ${msg.proofs.length} proofs, $countInputs of them inputs");

    // Send the blame list to the server
    // TODO should this be unawaited?
    await send2(Blames(blames: blames));
    print("sending blames");

    // Update the status to indicate that the program is waiting for the round to restart.
    status = ('running', 'awaiting restart');

    // Await the final 'restartround' message. It might take some time
    // to arrive since other players might be slow, and then the server
    // itself needs to check blockchain.
    await recv2(['restartround'],
        timeout: Duration(
            seconds: 2 *
                (Protocol.STANDARD_TIMEOUT.round() +
                    Protocol.BLAME_VERIFY_TIME.round())));

    // Return true to indicate successful execution of this part.
    return true;
  } // /run_round()
}

/// Custom exception class for Fusion related errors.
///
/// Example usage:
/// dart /// throw FusionError('Your specific error message'); /// class FusionError implements Exception {
class FusionError implements Exception {
  /// The error message describing the issue.
  final String message;

  /// Constructs a new FusionError with the provided message.
  FusionError(this.message);

  /// Custom string representation of the FusionError, useful for debugging.
  @override
  String toString() => "FusionError: $message";
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:fixnum/fixnum.dart';
import 'package:fusiondart/src/comms.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/covert.dart';
import 'package:fusiondart/src/encrypt.dart';
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/models/address.dart';
import 'package:fusiondart/src/pedersen.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:fusiondart/src/socketwrapper.dart';
import 'package:fusiondart/src/util.dart';
import 'package:fusiondart/src/validation.dart';
import 'package:pointycastle/export.dart';
import 'package:protobuf/protobuf.dart';

class FusionError implements Exception {
  final String message;

  FusionError(this.message);

  @override
  String toString() => "FusionError: $message";
}

class ComponentResult {
  final Uint8List commitment;
  final int counter;
  final Uint8List component;
  final Proof proof;
  final Uint8List privateKey;
  // TODO type
  final dynamic pedersenAmount;
  final dynamic pedersenNonce;

  ComponentResult(this.commitment, this.counter, this.component, this.proof,
      this.privateKey,
      {this.pedersenAmount, this.pedersenNonce});
}

class Transaction {
  List<Input> Inputs = [];
  List<Output> Outputs = [];

  Transaction();

  // TODO type
  static Tuple txFromComponents(
      List<dynamic> allComponents, List<dynamic> sessionHash) {
    Transaction tx = Transaction(); // Initialize a new Transaction
    // TODO This should be based on wallet layer... implement the logic of constructing the transaction from components
    // For now, it just initializes Inputs and Outputs as empty lists
    tx.Inputs = [];
    tx.Outputs = [];

    // For now, just returning an empty list for inputIndices
    List<int> inputIndices = [];

    return Tuple(tx, inputIndices);
  }

  List<int> serializePreimage(int index, int hashType, {bool useCache = true}) {
    // Add implementation here
    // For now, returning an empty byte array
    return [];
  }

  String serialize() {
    // To implement...
    return "";
  }

  bool isComplete() {
    // implement based on wallet.
    return true;
  }

  String txid() {
    // To implement...
    return "";
  }
}

class Input {
  List<int> prevTxid;
  int prevIndex;
  List<int> pubKey;
  int amount;
  List<String> signatures = [];

  Input(
      {required this.prevTxid,
      required this.prevIndex,
      required this.pubKey,
      required this.amount});

  int sizeOfInput() {
    assert(1 < pubKey.length &&
        pubKey.length < 76); // need to assume regular push opcode
    return 108 + pubKey.length;
  }

  int get value {
    return amount;
  }

  String getPubKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return "";
  }

  String getPrivKey(int pubkeyIndex) {
    // TO BE IMPLEMENTED...
    return "";
  }

  static Input fromInputComponent(InputComponent inputComponent) {
    return Input(
      prevTxid: inputComponent.prevTxid, // Make sure the types are matching
      prevIndex: inputComponent.prevIndex.toInt(),
      pubKey: inputComponent.pubkey,
      amount: inputComponent.amount.toInt(),
    );
  }

  static Input fromStackUTXOData(
    ({String txid, int vout, int value}) utxoInfo,
  ) {
    return Input(
      prevTxid: utf8.encode(utxoInfo.txid), // Convert txid to a List<int>
      prevIndex: utxoInfo.vout,
      pubKey: utf8.encode('0000'), // Placeholder
      amount: utxoInfo.value,
    );
  }

  void sign(String privateKey, Transaction tx) {
    String message = tx.txid();

    // generate 32 random bytes
    Uint8List aux = Uint8List(32);
    Random random = Random.secure();
    for (int i = 0; i < 32; i++) {
      aux[i] = random.nextInt(256);
    }

    String signature = bip340.sign(privateKey, message, hex.encode(aux));

    signatures.add(signature);
  }

  bool verify(String publicKey, Transaction tx) {
    String message = tx.txid();

    for (String signature in signatures) {
      if (!bip340.verify(publicKey, message, signature)) {
        return false;
      }
    }

    // only return true if no signatures failed
    return true;
  }
}

class Output {
  int value;
  Address addr;

  int amount = 0;

  Output({required this.value, required this.addr});

  int sizeOfOutput() {
    List<int> scriptpubkey = addr
        .toScript(); // assuming addr.toScript() returns List<int> that represents the scriptpubkey
    assert(scriptpubkey.length < 253);
    return 9 + scriptpubkey.length;
  }

  static Output fromOutputComponent(OutputComponent outputComponent) {
    Address address = Address.fromScriptPubKey(outputComponent.scriptpubkey);
    return Output(
      value: outputComponent.amount.toInt(),
      addr: address,
    );
  }
}

class BlindSignatureRequest {
  final BigInt order; // ECDSA curve order
  final BigInt fieldsize; // ECDSA curve field size
  late final Uint8List pubkey;
  late final Uint8List R;
  late final Uint8List messageHash;
  late BigInt a;
  late BigInt b;
  late BigInt c;
  late BigInt e;
  late BigInt enew;
  late Uint8List Rxnew;
  late Uint8List pubkeyCompressed;

  BlindSignatureRequest(this.pubkey, this.R, this.messageHash)
      : order = ECCurve_secp256r1().n,
        fieldsize = BigInt.from(ECCurve_secp256r1().curve.fieldSize) {
    if (pubkey.length != 33 || R.length != 33 || messageHash.length != 32) {
      throw ArgumentError('Invalid argument lengths.');
    }

    a = _randomBigInt(order);
    b = _randomBigInt(order);

    _calcInitial();

    // calculate e and enew
    final digest =
        crypto.sha256.convert(Rxnew + pubkeyCompressed + messageHash);
    final eHash = BigInt.parse(digest.toString(), radix: 16);
    e = (c * eHash + b) % order;
    enew = eHash % order;
  }

  BigInt _randomBigInt(BigInt maxValue) {
    // final int maxInt =
    //     9223372036854775807; // maximum int value in Dart (2^63 - 1)
    //
    // if (maxValue > BigInt.from(maxInt)) {
    //   throw ArgumentError('maxValue is too large to fit in an int.');
    //   // TODO implement support for larger BigInt values
    // }

    final random = Random.secure();
    return BigInt.from(
        random.nextInt(maxValue.toInt())); // assuming maxValue < maxInt
  }

  void _calcInitial() {
    ECPoint? Rpoint = Util.ser_to_point(R, params);
    ECPoint? pubpoint = Util.ser_to_point(pubkey, params);

    pubkeyCompressed = Util.point_to_ser(pubpoint, true);

    ECPoint? intermediateR = Rpoint + (params.G * a);
    if (intermediateR == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation Rpoint + (params.G * a).');
    }

    ECPoint? Rnew = intermediateR + (pubpoint * b);
    if (Rnew == null) {
      throw ArgumentError(
          'Failed to perform elliptic curve operation intermediateR + (pubpoint * b).');
    }

    Rxnew = bigIntToBytes(Rnew.x!.toBigInteger()!); // TODO check for null
    BigInt? y = Rnew.y?.toBigInteger();

    if (y == null) {
      throw ArgumentError('Y-coordinate of the new R point is null.');
    }

    c = BigInt.from(jacobi(y, fieldsize));
  }

  // TODO use something built in rather than implementing here
  int jacobi(BigInt a, BigInt n) {
    assert(n > BigInt.zero && n.isOdd);

    BigInt t = BigInt.one;
    while (a != BigInt.zero) {
      while (a.isEven) {
        a = a >> 1;
        BigInt r = n % BigInt.from(8);
        if (r == BigInt.from(3) || r == BigInt.from(5)) {
          t = -t;
        }
      }

      BigInt temp = a;
      a = n;
      n = temp;

      if (a % BigInt.from(4) == BigInt.from(3) &&
          n % BigInt.from(4) == BigInt.from(3)) {
        t = -t;
      }
      a = a % n;
    }

    if (n == BigInt.one) {
      return t.toInt();
    } else {
      return 0;
    }
  }

  Uint8List bigIntToBytes(BigInt number) {
    return Uint8List.fromList(number.toRadixString(16).codeUnits);
  }

  BigInt bytesToBigInt(Uint8List bytes) {
    return BigInt.parse(
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);
  }

  Uint8List get request {
    return bigIntToBytes(e);
  }

  Uint8List finalize(Uint8List sBytes, {bool check = true}) {
    if (sBytes.length != 32) {
      throw ArgumentError('Invalid length for sBytes');
    }

    BigInt s = bytesToBigInt(sBytes);
    BigInt snew = (c * (s + a)) % order;

    List<int> sig = Rxnew + bigIntToBytes(snew);

    ECPoint? pubPoint = Util.ser_to_point(pubkey, params);

    if (check && !Util.schnorrVerify(pubPoint, sig, messageHash)) {
      throw Exception('Blind signature verification failed.');
    }

    return Uint8List.fromList(sig.toList());
  }
}

// Class to handle fusion
class Fusion {
  late final Future<Address> Function() _createNewReservedChangeAddress;
  late final Future<List<Address>> Function(int numberOfAddresses)
      _getUnusedReservedChangeAddresses;

  Fusion(
      {required Future<Address> Function() createNewReservedChangeAddress,
      required Future<List<Address>> Function(int numberOfAddresses)
          getUnusedReservedChangeAddresses});

  void initFusion({
    required Future<Address> Function() createNewReservedChangeAddress,
    required Future<List<Address>> Function(int numberOfAddresses)
        getUnusedReservedChangeAddresses,
  }) {
    _createNewReservedChangeAddress = createNewReservedChangeAddress;
    _getUnusedReservedChangeAddresses = getUnusedReservedChangeAddresses;
  }

  List<Input> coins =
      []; //"coins" and "inputs" are often synonymous in the original python code.
  List<Output> outputs = [];
  List<Address> changeAddresses = [];
  bool server_connected_and_greeted = false;
  bool stopping = false;
  bool stopping_if_not_running = false;
  String stopReason = "";
  String tor_host = "";
  bool server_ssl = false;
  String server_host = "cashfusion.stackwallet.com";
  int server_port = 8787;

  //String server_host = "fusion.servo.cash";
  //int server_port = 8789;

  int tor_port = 0;
  int roundcount = 0;
  String txid = "";

  Tuple<String, String> status = Tuple("", "");
  Connection? connection;

  int numComponents = 0;
  double componentFeeRate = 0;
  double minExcessFee = 0;
  double maxExcessFee = 0;
  List<int> availableTiers = [];

  int maxOutputs = 0;
  int safety_sum_in = 0;
  Map<int, int> safety_exess_fees = {};
  Map<int, List<int>> tierOutputs =
      {}; // not sure if this should be using outputs class.

  int inactiveTimeLimit = 600000; // this is in ms... equates to 10 minutes.
  int tier = 0;
  int covertPort = 0;
  bool covertSSL = false;
  double beginTime = 0.0; //  represent time in seconds.
  List<int> lastHash = <int>[];
  List<Address> reservedAddresses = <Address>[];
  int safetyExcessFee = 0;
  DateTime t_fusionBegin = DateTime.now();
  Uint8List covertDomainB = Uint8List(0);

  List<int>? txInputIndices;
  Transaction tx = Transaction();
  List<int> myComponentIndexes = [];
  List<int> myCommitmentIndexes = [];
  Set<int> badComponents = {};

  /*
  Fusion() {
    //initializeConnection(host, port)
  }

  Future<void> initializeConnection(String host, int port) async {
    Socket socket = await Socket.connect(host, port);
    connection = Connection()..socket = socket;
  }
  */

  Future<void> add_coins_from_wallet(
    List<({String txid, int vout, int value})> utxoList,
  ) async {
    // Convert each UTXO info to an Input and add to 'coins'
    for (final utxoInfo in utxoList) {
      coins.add(Input.fromStackUTXOData(utxoInfo));
    }
  }

  Future<void> addChangeAddress(Address address) async {
    // add address to addresses[]
    changeAddresses.add(address);
  }

  Future<void> fusion_run() async {
    print("DEBUG FUSION 223...fusion run....");
    try {
      try {
        // Check compatibility  - This was done in python version to see if fast libsec installed.
        // For now , in dart, just pass this test.
        ;
      } on Exception catch (e) {
        // handle exception, rethrow as a custom FusionError
        throw FusionError("Incompatible: $e");
      }

      // Check if can connect to Tor proxy, if not, raise FusionError. Empty String treated as no host.
      if (tor_host.isNotEmpty &&
          tor_port != 0 &&
          !await isTorPort(tor_host, tor_port)) {
        throw FusionError("Can't connect to Tor proxy at $tor_host:$tor_port");
      }

      try {
        // Check stop condition
        check_stop(running: false);
      } catch (e) {
        print(e);
      }

      try {
        // Check coins
        check_coins();
      } catch (e) {
        print(e);
      }

      // Connect to server
      status = Tuple("connecting", "");
      try {
        connection = await openConnection(server_host, server_port,
            connTimeout: 5.0, defaultTimeout: 5.0, ssl: server_ssl);
      } catch (e) {
        print("Connect failed: $e");
        String sslstr = server_ssl ? ' SSL ' : '';
        throw FusionError(
            'Could not connect to $sslstr$server_host:$server_port');
      }

      // Once connection is successful, wrap operations inside this block
      // Within this block, version checks, downloads server params, handles coins and runs rounds
      try {
        SocketWrapper socketwrapper = SocketWrapper(server_host, server_port);
        await socketwrapper.connect();

        // Version check and download server params.
        await greet(socketwrapper);

        socketwrapper.status();
        server_connected_and_greeted = true;
        notify_server_status(true);

        // In principle we can hook a pause in here -- user can insert coins after seeing server params.

        try {
          if (coins.isEmpty) {
            throw FusionError('Started with no coins');
            return;
          }
        } catch (e) {
          print(e);
          return;
        }

        await allocateOutputs(socketwrapper);
        // In principle we can hook a pause in here -- user can tweak tier_outputs, perhaps cancelling some unwanted tiers.

        // Register for tiers, wait for a pool.
        await registerAndWait(socketwrapper);

        // launch the covert submitter
        CovertSubmitter covert = await startCovert();
        try {
          // Pool started. Keep running rounds until fail or complete.
          while (true) {
            roundcount += 1;
            if (await runRound(covert)) {
              break;
            }
          }
        } finally {
          covert.stop();
        }
      } finally {
        (await connection)?.close();
      }

      print("RETURNING early in fusion_run....");
      return;

      for (int i = 0; i < 60; i++) {
        if (stopping) {
          break; // not an error
        }

        if (Util.walletHasTransaction(txid)) {
          break;
        }

        await Future.delayed(Duration(seconds: 1));
      }

      // Set status to 'complete' with 'time_wait'
      status = Tuple('complete', 'txid: $txid');

      // Wait for transaction to show up in wallets
      // Set status to 'complete' with txid
    } on FusionError catch (err) {
      print('Failed: ${err}');
      status.item1 = "failed";
      status.item2 = err.toString(); // setting the error message
    } catch (exc) {
      print('Exception: ${exc}');
      status.item1 = "failed";
      status.item2 =
          "Exception: ${exc.toString()}"; // setting the exception message
    } finally {
      clear_coins();
      if (status.item1 != 'complete') {
        for (Output output in outputs) {
          // TODO implement
          // Util.unreserve_change_address(output.addr);
        }
        if (!server_connected_and_greeted) {
          notify_server_status(false, tup: status);
        }
      }
    }
  } // end fusion_run function.

  void notify_server_status(bool b, {Tuple? tup}) {
    // Function implementation goes here
  }

  void stop([String reason = 'stopped', bool notIfRunning = false]) {
    if (stopping) {
      return;
    }
    if (notIfRunning) {
      if (stopping_if_not_running) {
        return;
      }
      stopReason = reason;
      stopping_if_not_running = true;
    } else {
      stopReason = reason;
      stopping = true;
    }
    // note the reason is only overwritten if we were not already stopping this way.
  }

  void check_stop({bool running = true}) {
    // Gets called occasionally from fusion thread to allow a stop point.
    if (stopping || (!running && stopping_if_not_running)) {
      throw FusionError(stopReason ?? 'Unknown stop reason');
    }
  }

  void check_coins() {
    // Implement by calling wallet layer to check the coins are ok.
    return;
  }

  void clear_coins() {
    coins = [];
  }

  void addCoins(List<Input> newCoins) {
    coins.addAll(newCoins);
  }

  void notify_coins_UI() {
    return;
  }

  static bool walletCanFuse() {
    return true;

    // Implement logic here to return false if the wallet can't fuse.  (If its read only or non P2PKH)
  }

  static double nextDoubleNonZero(Random rng) {
    double value = 0.0;
    while (value == 0.0) {
      value = rng.nextDouble();
    }
    return value;
  }

  static List<int>? randomOutputsForTier(
      Random rng, int inputAmount, int scale, int offset, int maxCount) {
    if (inputAmount < offset) {
      return [];
    }
    double lambd = 1.0 / scale;
    int remaining = inputAmount;
    List<double> values = []; // list of fractional random values without offset
    bool didBreak =
        false; // Add this flag to detect when a break is encountered

    for (int i = 0; i < maxCount + 1; i++) {
      double val = -lambd * log(nextDoubleNonZero(rng));
      remaining -= (val.ceil() + offset);
      if (remaining < 0) {
        didBreak = true; // If you break, set this flag to true
        break;
      }
      values.add(val);
    }

    if (!didBreak && values.length > maxCount) {
      values = values.sublist(0, maxCount);
    }

    if (values.isEmpty) {
      // Our first try put us over the limit, so we have nothing to work with.
      // (most likely, scale was too large)
      return [];
    }

    int desiredRandomSum = inputAmount - values.length * offset;
    assert(desiredRandomSum >= 0, 'desiredRandomSum is less than 0');

    /*Now we need to rescale and round the values so they fill up the desired.
  input amount exactly. We perform rounding in cumulative space so that the
  sum is exact, and the rounding is distributed fairly.
   */

    // Dart equivalent of itertools.accumulate
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

  static List<ComponentResult> genComponents(
      int numBlanks, List<Input> inputs, List<Output> outputs, int feerate) {
    assert(numBlanks >= 0);

    List<Tuple<Component, int>> components = [];

    // Set up Pedersen setup instance
    Uint8List HBytes = Uint8List.fromList(
        [0x02] + 'CashFusion gives us fungibility.'.codeUnits);
    ECDomainParameters params = ECDomainParameters('secp256k1');
    ECPoint? HMaybe = params.curve.decodePoint(HBytes);
    if (HMaybe == null) {
      throw Exception('Failed to decode point');
    }
    ECPoint H = HMaybe;
    PedersenSetup setup = PedersenSetup(H);

    for (Input input in inputs) {
      int fee = Util.componentFee(input.sizeOfInput(), feerate);

      Component comp = Component();
      comp.input = InputComponent(
          prevTxid: Uint8List.fromList(input.prevTxid.reversed.toList()),
          prevIndex: input.prevIndex,
          pubkey: input.pubKey,
          amount: Int64(input.amount));
      components.add(Tuple<Component, int>(comp, input.amount - fee));
    }

    for (Output output in outputs) {
      List<int> script = output.addr.toScript();
      int fee = Util.componentFee(output.sizeOfOutput(), feerate);

      Component comp = Component();
      comp.output =
          OutputComponent(scriptpubkey: script, amount: Int64(output.value));
      components.add(Tuple<Component, int>(comp, -output.value - fee));
    }

    for (int i = 0; i < numBlanks; i++) {
      Component comp = Component();
      comp.blank = BlankComponent();
      components.add(Tuple<Component, int>(comp, 0));
    }

    List<ComponentResult> resultList = [];

    components.asMap().forEach((cnum, Tuple<Component, int> componentTuple) {
      Uint8List salt = Util.tokenBytes(32);
      componentTuple.item1.saltCommitment = Util.sha256(salt);
      Uint8List compser = componentTuple.item1.writeToBuffer();

      Tuple<Uint8List, Uint8List> keyPair = Util.genKeypair();
      Uint8List privateKey = keyPair.item1;
      Uint8List pubKey = keyPair.item2;

      Commitment commitmentInstance =
          setup.commit(BigInt.from(componentTuple.item2));
      Uint8List amountCommitment = commitmentInstance.PUncompressed;

// Convert BigInt nonce to Uint8List
      Uint8List pedersenNonce = Uint8List.fromList(
          [int.parse(commitmentInstance.nonce.toRadixString(16), radix: 16)]);

// Generating initial commitment
      InitialCommitment commitment = InitialCommitment(
          saltedComponentHash:
              Util.sha256(Uint8List.fromList([...compser, ...salt])),
          amountCommitment: amountCommitment,
          communicationKey: pubKey);

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

  Future<GeneratedMessage> recv2(
      SocketWrapper socketwrapper, List<String> expectedMsgNames,
      {Duration? timeout}) async {
    if (connection == null) {
      throw FusionError('Connection not initialized');
    }

    Tuple<GeneratedMessage, String> result = await recvPb2(
        socketwrapper, connection!, ServerMessage, expectedMsgNames,
        timeout: timeout);

    GeneratedMessage submsg = result.item1;
    String mtype = result.item2;

    if (mtype == 'error') {
      throw FusionError('server error: ${submsg.toString()}');
    }

    return submsg;
  }

  Future<GeneratedMessage> recv(List<String> expectedMsgNames,
      {Duration? timeout}) async {
    // DEPRECATED
    if (connection == null) {
      throw FusionError('Connection not initialized');
    }

    Tuple<GeneratedMessage, String> result = await recvPb(
        connection!, ServerMessage, expectedMsgNames,
        timeout: timeout);

    GeneratedMessage submsg = result.item1;
    String mtype = result.item2;

    if (mtype == 'error') {
      throw FusionError('server error: ${submsg.toString()}');
    }

    return submsg;
  }

  Future<void> send(GeneratedMessage submsg, {Duration? timeout}) async {
    // DEPRECATED
    if (connection != null) {
      await sendPb(connection!, ClientMessage, submsg, timeout: timeout);
    } else {
      print('Connection is null');
    }
  }

  Future<void> send2(SocketWrapper socketwrapper, GeneratedMessage submsg,
      {Duration? timeout}) async {
    if (connection != null) {
      await sendPb2(socketwrapper, connection!, ClientMessage, submsg,
          timeout: timeout);
    } else {
      print('Connection is null');
    }
  }

  Future<void> greet(SocketWrapper socketwrapper) async {
    ClientHello clientHello = ClientHello(
        version: Uint8List.fromList(utf8.encode(Protocol.VERSION)),
        genesisHash: Util.get_current_genesis_hash());

    ClientMessage clientMessage = ClientMessage()..clienthello = clientHello;

    //deprecated
    //Connection greet_connection_1 = Connection.withoutSocket();
    /*
    lets move this up a level to the fusion_run and pass it in....
    SocketWrapper socketwrapper = SocketWrapper(server_host, server_port);
    await socketwrapper.connect();
    */
    // TODO should this be unawaited?
    await send2(socketwrapper, clientMessage);

    GeneratedMessage replyMsg = await recv2(socketwrapper, ['serverhello']);
    if (replyMsg is ServerMessage) {
      ServerHello reply = replyMsg.serverhello;

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
  }

  Future<void> allocateOutputs(socketwrapper) async {
    print("DBUG allocateoutputs 746");

    print("CHECK socketwrapper 746");
    socketwrapper.status();
    assert(['setup', 'connecting'].contains(status.item1));

    List<Input> inputs = coins;
    int numInputs = inputs.length;

    int maxComponents = min(numComponents, Protocol.MAX_COMPONENTS);
    int maxOutputs = maxComponents - numInputs;
    if (maxOutputs < 1) {
      throw FusionError('Too many inputs ($numInputs >= $maxComponents)');
    }

    if (maxOutputs != null) {
      assert(maxOutputs >= 1);
      maxOutputs = min(maxOutputs, maxOutputs);
    }

    int numDistinct = inputs.map((e) => e.value).toSet().length;
    int minOutputs = max(Protocol.MIN_TX_COMPONENTS - numDistinct, 1);
    if (maxOutputs < minOutputs) {
      throw FusionError(
          'Too few distinct inputs selected ($numDistinct); cannot satisfy output count constraint (>= $minOutputs, <= $maxOutputs)');
    }

    int sumInputsValue = inputs.map((e) => e.value).reduce((a, b) => a + b);
    int inputFees = inputs
        .map(
            (e) => Util.componentFee(e.sizeOfInput(), componentFeeRate.toInt()))
        .reduce((a, b) => a + b);
    int availForOutputs = sumInputsValue - inputFees - minExcessFee.toInt();

    int feePerOutput = Util.componentFee(34, componentFeeRate.toInt());

    int offsetPerOutput = Protocol.MIN_OUTPUT + feePerOutput;

    if (availForOutputs < offsetPerOutput) {
      throw FusionError('Selected inputs had too little value');
    }

    Random rng = Random();
    List<int> seed = List<int>.generate(32, (_) => rng.nextInt(256));

    print("DBUG allocateoutputs 785");
    tierOutputs = {};
    Map<int, int> excessFees = <int, int>{};
    for (int scale in availableTiers) {
      int fuzzFeeMax = scale ~/ 1000000;
      int fuzzFeeMaxReduced = min(
          fuzzFeeMax,
          min(Protocol.MAX_EXCESS_FEE - minExcessFee.toInt(),
              maxExcessFee.toInt()));

      assert(fuzzFeeMaxReduced >= 0);
      int fuzzFee = rng.nextInt(fuzzFeeMaxReduced + 1);

      int reducedAvailForOutputs = availForOutputs - fuzzFee;
      if (reducedAvailForOutputs < offsetPerOutput) {
        continue;
      }

      List<int>? outputs = randomOutputsForTier(
          rng, reducedAvailForOutputs, scale, offsetPerOutput, maxOutputs);
      if (outputs != null) {
        print(outputs);
      }
      if (outputs == null || outputs.length < minOutputs) {
        continue;
      }
      outputs = outputs.map((o) => o - feePerOutput).toList();

      assert(inputs.length + (outputs?.length ?? 0) <= Protocol.MAX_COMPONENTS);

      excessFees[scale] = sumInputsValue - inputFees - reducedAvailForOutputs;
      tierOutputs[scale] = outputs!;
    }

    print('Possible tiers: $tierOutputs');

    safety_sum_in = sumInputsValue;
    safety_exess_fees = excessFees;
    return;
  }

  Future<void> registerAndWait(SocketWrapper socketwrapper) async {
    Stopwatch stopwatch = Stopwatch()..start();
    // TODO type
    // msg can be different classes depending on which protobuf msg is sent.
    dynamic? msg;

    Map<int, List<int>> tierOutputs = this.tierOutputs;
    List<int> tiersSorted = tierOutputs.keys.toList()..sort();

    if (tierOutputs.isEmpty) {
      throw FusionError(
          'No outputs available at any tier (selected inputs were too small / too large).');
    }

    print('registering for tiers: $tiersSorted');

    int self_fuse = 1; // Temporary value for now
    List<int> cashfusionTag = [1]; // temp value for now

    check_stop(running: false);
    check_coins();

    List<JoinPools_PoolTag> tags = [
      JoinPools_PoolTag(id: cashfusionTag, limit: self_fuse)
    ];

// Create JoinPools message
    JoinPools joinPools =
        JoinPools(tiers: tiersSorted.map((i) => Int64(i)).toList(), tags: tags);

// Wrap it in a ClientMessage
    ClientMessage clientMessage = ClientMessage()..joinpools = joinPools;

    await send2(socketwrapper, clientMessage);

    status = Tuple<String, String>('waiting', 'Registered for tiers');

    Map<dynamic, String> tiersStrings = {
      // TODO make Entry class or otherwise type this section
      for (var entry in tierOutputs.entries)
        entry.key:
            (entry.key * 1e-8).toStringAsFixed(8).replaceAll(RegExp(r'0+$'), '')
    };

    while (true) {
      print("RECEIVE LOOP 870............DEBUG");
      GeneratedMessage msg = await recv2(
          socketwrapper, ['tierstatusupdate', 'fusionbegin'],
          timeout: Duration(seconds: 10));

      // TODO type
      FieldInfo<dynamic>? fieldInfoFusionBegin =
          msg.info_.byName["fusionbegin"];
      if (fieldInfoFusionBegin != null &&
          msg.hasField(fieldInfoFusionBegin.tagNumber)) {
        print("DEBUG 867 Fusion Begin message...");
        break;
      }

      check_stop(running: false);
      check_coins();

      // Define the bool variable

      FieldInfo<dynamic>? fieldInfo = msg.info_.byName["tierstatusupdate"];
      if (fieldInfo == null) {
        throw FusionError(
            'Expected field not found in message: tierstatusupdate');
      }

      bool messageIsTierStatusUpdate = msg.hasField(fieldInfo.tagNumber);
      print("DEBUG 889 getting tier update.");

      if (!messageIsTierStatusUpdate) {
        throw FusionError('Expected a TierStatusUpdate message');
      }

      late Map<Int64, TierStatusUpdate_TierStatus> statuses;
      if (messageIsTierStatusUpdate) {
        //TierStatusUpdate tierStatusUpdate = msg.tierstatusupdate;
        TierStatusUpdate tierStatusUpdate =
            msg.getField(fieldInfo.tagNumber) as TierStatusUpdate;
        statuses = tierStatusUpdate.statuses;
      }

      double maxfraction = 0.0;
      List<int> maxtiers = <int>[];
      int? besttime;
      int? besttimetier;
      if (statuses!.entries is Iterable) {
        for (var entry in statuses.entries) {
          // TODO make Entry class or otherwise type this section
          double frac = ((entry.value.players.toInt())) /
              ((entry.value.minPlayers.toInt()));
          if (frac >= maxfraction) {
            if (frac > maxfraction) {
              maxfraction = frac;
              maxtiers.clear();
            }
            maxtiers.add(entry.key.toInt());
          }

          FieldInfo<dynamic>? fieldInfoTimeRemaining =
              entry.value.info_.byName["timeRemaining"];
          // if (fieldInfoTimeRemaining == null) {
          //   throw FusionError(
          //       'Expected field not found in message: timeRemaining');
          // }

          if (fieldInfoTimeRemaining != null) {
            if (entry.value.hasField(fieldInfoTimeRemaining!.tagNumber)) {
              int tr = entry.value.timeRemaining.toInt();
              if (besttime == null || tr < besttime) {
                besttime = tr;
                besttimetier = entry.key.toInt();
              }
            }
          } else {
            // TODO throw warning or error?
          }
        }
      }

      List<String> displayBest = <String>[];
      List<String> displayMid = <String>[];
      List<String> displayQueued = <String>[];

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

      List<String> parts = <String>[];
      if (displayBest.isNotEmpty || displayMid.isNotEmpty) {
        parts.add("Tiers: ${displayBest.join(', ')} ${displayMid.join(', ')}");
      }
      if (displayQueued.isNotEmpty) {
        parts.add("Queued: ${displayQueued.join(', ')}");
      }
      String tiersString = parts.join(' ');

      if (besttime == null && inactiveTimeLimit != null) {
        if (stopwatch.elapsedMilliseconds > inactiveTimeLimit) {
          throw FusionError('stopping due to inactivity');
        } else {
          // debug
        }
      } else {
        // debug
      }

      if (besttime != null) {
        status = Tuple<String, String>(
            'waiting', 'Starting in ${besttime}s. $tiersString');
      } else if (maxfraction >= 1) {
        status =
            Tuple<String, String>('waiting', 'Starting soon. $tiersString');
      } else if (displayBest.isNotEmpty || displayMid.isNotEmpty) {
        status = Tuple<String, String>(
            'waiting', '${(maxfraction * 100).round()}% full. $tiersString');
      } else {
        status = Tuple<String, String>('waiting', tiersString);
      }
    }

    // TODO type fieldInfoFusionBegin
    dynamic fieldInfoFusionBegin = msg.info_.byName["fusionbegin"];
    if (fieldInfoFusionBegin == null) {
      throw FusionError('Expected field not found in message: fusionbegin');
    }

    bool messageIsFusionBegin =
        msg.hasField(fieldInfoFusionBegin.tagNumber) as bool;
    if (!messageIsFusionBegin) {
      throw FusionError('Expected a FusionBegin message');
    }

    t_fusionBegin = DateTime.now();

    FusionBegin fusionBeginMsg = msg.fusionbegin
        as FusionBegin; // TODO handle better than with just a cast

    int elapsedSeconds = stopwatch.elapsedMilliseconds ~/ 1000;
    double clockMismatch = fusionBeginMsg.serverTime.toInt() -
        DateTime.now().millisecondsSinceEpoch / 1000;

    if (clockMismatch.abs().toDouble() > Protocol.MAX_CLOCK_DISCREPANCY) {
      throw FusionError(
          "Clock mismatch too large: ${(clockMismatch.toDouble()).toStringAsFixed(3)}.");
    }

    tier = fusionBeginMsg.tier.toInt();
    if (msg is FusionBegin) {
      covertDomainB = Uint8List.fromList(msg.covertDomain);
    }

    covertPort = fusionBeginMsg.covertPort;
    covertSSL = fusionBeginMsg.covertSsl;
    beginTime = fusionBeginMsg.serverTime.toDouble();

    lastHash = Util.calcInitialHash(
        tier, covertDomainB, covertPort, covertSSL, beginTime);

    List<int>? outAmounts = tierOutputs[tier];
    List<Address> outAddrs =
        await _getUnusedReservedChangeAddresses(outAmounts?.length ?? 0);

    reservedAddresses = outAddrs;
    outputs = Util.zip(outAmounts ?? [], outAddrs)
        .map((pair) => Output(
            value: pair[0] as int, addr: Address.fromString(pair[1] as String)))
        .toList();

    safetyExcessFee = safety_exess_fees[tier] ?? 0;

    print(
        "starting fusion rounds at tier $tier: ${coins.length} inputs and ${outputs.length} outputs");
  }

  Future<CovertSubmitter> startCovert() async {
    print("DEBUG START COVERT!");
    status = Tuple('running', 'Setting up Tor connections');

    String covertDomain;
    try {
      covertDomain = utf8.decode(covertDomainB);
    } catch (e) {
      throw FusionError('badly encoded covert domain');
    }
    CovertSubmitter covert = CovertSubmitter(
        covertDomain,
        covertPort,
        covertSSL,
        tor_host,
        tor_port,
        numComponents,
        Protocol.COVERT_SUBMIT_WINDOW,
        Protocol.COVERT_SUBMIT_TIMEOUT);
    try {
      covert.scheduleConnections(t_fusionBegin,
          Duration(seconds: Protocol.COVERT_CONNECT_WINDOW.toInt()),
          numSpares: Protocol.COVERT_CONNECT_SPARES.toInt(),
          connectTimeout: Protocol.COVERT_CONNECT_TIMEOUT.toInt());

      print("DEBUG return early from covert");
      return covert;

      // loop until a just a bit before we're expecting startRound, watching for status updates
      final tend = t_fusionBegin.add(Duration(
          seconds: (Protocol.WARMUP_TIME - Protocol.WARMUP_SLOP - 1).round()));

      while (DateTime.now().millisecondsSinceEpoch / 1000 <
          tend.millisecondsSinceEpoch / 1000) {
        int numConnected =
            covert.slots.where((s) => s.covConn?.connection != null).length;

        int numSpareConnected =
            covert.spareConnections.where((c) => c.connection != null).length;

        status = Tuple('running',
            'Setting up Tor connections ($numConnected+$numSpareConnected out of $numComponents)');

        await Future.delayed(Duration(seconds: 1));

        covert.checkOk();
        check_stop();
        check_coins();
      }
    } catch (e) {
      covert.stop();
      rethrow;
    }

    return covert;
  }

  Future<bool> runRound(CovertSubmitter covert) async {
    print("START OF RUN ROUND");
    status = Tuple('running', 'Starting round ${roundcount.toString()}');
    int timeoutInSeconds =
        (2 * Protocol.WARMUP_SLOP + Protocol.STANDARD_TIMEOUT).toInt();
    GeneratedMessage msg = await recv(['startround'],
        timeout: Duration(seconds: timeoutInSeconds));

    // Record the time we got this message; it forms the basis time for all covert activities.
    final covertT0 = DateTime.now().millisecondsSinceEpoch / 1000;
    double covertClock() =>
        (DateTime.now().millisecondsSinceEpoch / 1000) - covertT0;

    final roundTime = (msg as StartRound).serverTime;

    // Check the server's declared unix time, which will be committed.
    final clockMismatch =
        msg.serverTime - DateTime.now().millisecondsSinceEpoch / 1000;
    if (clockMismatch.abs() > Protocol.MAX_CLOCK_DISCREPANCY) {
      throw FusionError(
          "Clock mismatch too large: ${clockMismatch.toInt().toStringAsPrecision(3)}.");
    }

    if (t_fusionBegin != null) {
      // On the first startround message, check that the warmup time was within acceptable bounds.
      final lag = covertT0 -
          (t_fusionBegin.millisecondsSinceEpoch / 1000) -
          Protocol.WARMUP_TIME;
      if (lag.abs() > Protocol.WARMUP_SLOP) {
        throw FusionError(
            "Warmup period too different from expectation (|${lag.toStringAsFixed(3)}s| > ${Protocol.WARMUP_SLOP.toStringAsFixed(3)}s).");
      }
      t_fusionBegin = DateTime.now();
    }

    print("round starting at ${DateTime.now().millisecondsSinceEpoch / 1000}");

    final inputFees = coins
        .map(
            (e) => Util.componentFee(e.sizeOfInput(), componentFeeRate.toInt()))
        .reduce((a, b) => a + b);
    final outputFees =
        outputs.length * Util.componentFee(34, componentFeeRate.toInt());

    final sumIn = coins.map((e) => e.amount).reduce((a, b) => a + b);
    final sumOut = outputs.map((e) => e.value).reduce((a, b) => a + b);

    final totalFee = sumIn - sumOut;
    final excessFee = totalFee - inputFees - outputFees;
    final safeties = [
      sumIn == safety_sum_in,
      excessFee == safetyExcessFee,
      excessFee <= Protocol.MAX_EXCESS_FEE,
      totalFee <= Protocol.MAX_FEE,
    ];

    if (!safeties.every((element) => element)) {
      throw Exception(
          "(BUG!) Funds re-check failed -- aborting for safety. ${safeties.toString()}");
    }

    final roundPubKey = (msg as StartRound).roundPubkey;

    final blindNoncePoints = (msg as StartRound).blindNoncePoints;
    if (blindNoncePoints.length != numComponents) {
      throw FusionError('blind nonce miscount');
    }

    final numBlanks = numComponents - coins.length - outputs.length;
    final List<ComponentResult> genComponentsResults =
        genComponents(numBlanks, coins, outputs, componentFeeRate.toInt());

    final List<Uint8List> myCommitments = [];
    final List<int> myComponentSlots = [];
    final List<Uint8List> myComponents = [];
    final List<Proof> myProofs = [];
    final List<Uint8List> privKeys = [];
    // TODO type
    final List<dynamic> pedersenAmount = [];
    final List<dynamic> pedersenNonce = [];

    for (ComponentResult genComponentResult in genComponentsResults) {
      myCommitments.add(genComponentResult.commitment);
      myComponentSlots.add(genComponentResult.counter);
      myComponents.add(genComponentResult.component);
      myProofs.add(genComponentResult.proof);
      privKeys.add(genComponentResult.privateKey);
      pedersenAmount.add(genComponentResult.pedersenAmount);
      pedersenNonce.add(genComponentResult.pedersenNonce);
    }
    assert(excessFee ==
        pedersenAmount.reduce(
            (a, b) => a + b)); // sanity check that we didn't mess up the above
    assert(myComponents.toSet().length == myComponents.length); // no duplicates

    // Need to implement this!  schnorr is from EC schnorr.py
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

    // print("RETURNING EARLY FROM run round .....");
    // return true;
    final randomNumber = Util.getRandomBytes(32);
    covert.checkOk();
    check_stop();
    check_coins();

    await send(PlayerCommit(
      initialCommitments: myCommitments,
      excessFee: Int64(excessFee),
      pedersenTotalNonce: pedersenNonce.cast<int>(),
      randomNumberCommitment: crypto.sha256.convert(randomNumber).bytes,
      blindSigRequests: blindSigRequests.map((r) => r.request).toList(),
    ));

    msg = await recv(['blindsigresponses'],
        timeout: Duration(seconds: Protocol.T_START_COMPS.toInt()));

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
    await Future.delayed(Duration(seconds: remainingTime.floor()));

// Our final check to leave the fusion pool, before we start telling our
// components. This is much more annoying since it will cause the round
// to fail, but since we would end up killing the round anyway then it's
// best for our privacy if we just leave now.
// (This also is our first call to check_connected.)
    covert.checkConnected();
    check_coins();

// Start covert component submissions
    print("starting covert component submission");
    status = Tuple('running', 'covert submission: components');

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
    msg = await recv(['allcommitments'],
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
    msg = await recv(['sharecovertcomponents'],
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
              .indexWhere((element) => ListEquality().equals(element, c)))
          .toList();
      if (myComponentIndexes.contains(-1)) {
        throw FusionError('One or more of my components missing.');
      }
    } on StateError {
      throw FusionError('One or more of my components missing.');
    }

    // Need to implement: check the components list and see if there are enough inputs/outputs
    // for there to be significant privacy.

    List<List<int>> allCommitmentsBytes = allCommitments
        .map((commitment) => commitment.writeToBuffer().toList())
        .toList();
    List<int> sessionHash = Util.calcRoundHash(lastHash, roundPubKey,
        roundTime.toInt(), allCommitmentsBytes, allComponents);

    if (shareCovertComponentsMsg.sessionHash != null &&
        !ListEquality()
            .equals(shareCovertComponentsMsg.sessionHash, sessionHash)) {
      throw FusionError('Session hash mismatch (bug!)');
    }

    if (!shareCovertComponentsMsg.skipSignatures) {
      print("starting covert signature submission");
      status = Tuple('running', 'covert submission: signatures');

      if (allComponents.toSet().length != allComponents.length) {
        throw FusionError('Server component list includes duplicates.');
      }

      Tuple txInputIndices =
          Transaction.txFromComponents(allComponents, sessionHash);

      Tuple txData = Transaction.txFromComponents(allComponents, sessionHash);
      tx = txData!.item1 as Transaction;
      List<int> inputIndices = txData!.item2 as List<int>;

      List<CovertTransactionSignature?> covertTransactionSignatureMessages =
          List<CovertTransactionSignature?>.filled(myComponents.length, null);

      List<Tuple<int, Input>> my_combined = List<Tuple<int, Input>>.generate(
        inputIndices.length,
        (index) => Tuple(inputIndices[index], tx.Inputs[index]),
      );

      for (int i = 0; i < my_combined.length; i++) {
        int cIdx = my_combined[i].item1;
        Input inp = my_combined[i].item2;

        int myCompIdx = myComponentIndexes.indexOf(cIdx);
        if (myCompIdx == -1) continue; // not my input

        String pubKey = inp.getPubKey(0); // cast/convert to PublicKey?
        String sec = inp.getPrivKey(0); // cast/convert to SecretKey?

        List<int> preimageBytes = tx.serializePreimage(i, 0x41, useCache: true);
        crypto.Digest sighash =
            crypto.sha256.convert(crypto.sha256.convert(preimageBytes).bytes);

        //var sig = schnorr.sign(sec, sighash); // Needs implementation
        List<int> sig = <int>[0, 1, 2, 3, 4]; // dummy placeholder

        covertTransactionSignatureMessages[myComponentSlots[myCompIdx]] =
            CovertTransactionSignature(txsignature: sig, whichInput: i);
      }

      DateTime covertT0DateTime = DateTime.fromMillisecondsSinceEpoch(
          covertT0.toInt() * 1000); // covertT0 is in seconds
      covert.scheduleSubmissions(
          covertT0DateTime
              .add(Duration(milliseconds: Protocol.T_START_SIGS.toInt())),
          covertTransactionSignatureMessages);

      // wait for result
      int timeoutMillis = (Protocol.T_EXPECTING_CONCLUSION -
              Protocol.TS_EXPECTING_COVERT_COMPONENTS)
          .toInt();
      Duration timeout = Duration(milliseconds: timeoutMillis);
      msg = await recv(['fusionresult'], timeout: timeout);

      // Critical check on server's response timing.
      if (covertClock() > Protocol.T_EXPECTING_CONCLUSION) {
        throw FusionError('Fusion result message arrived too slowly.');
      }

      covert.checkDone();
      FusionResult fusionResultMsg = msg as FusionResult;
      if (fusionResultMsg.ok) {
        List<List<int>> allSigs = msg.txsignatures;

        // assemble the transaction.
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
          inp.signatures = [sig + '41'];
        }

        assert(tx.isComplete());
        String txHex = tx.serialize();

        txid = tx.txid();
        String sumInStr = Util.formatSatoshis(sumIn, numZeros: 8);
        String feeStr = totalFee.toString();
        String feeLoc = 'fee';

        String label =
            "CashFusion ${coins.length}⇢${outputs.length}, ${sumInStr} BCH (−${feeStr} sats ${feeLoc})";

        Util.updateWalletLabel(txid, label);
      } else {
        badComponents = msg.badComponents.toSet();
        if (badComponents.intersection(myComponentIndexes.toSet()).isNotEmpty) {
          print(
              "bad components: ${badComponents.toList()} mine: ${myComponentIndexes.toList()}");
          throw FusionError("server thinks one of my components is bad!");
        }
      }
    } else {
      // skip_signatures True
      Set<int> badComponents = Set<int>();
    }

// ### Blame phase ###

    covert.setStopTime((covertT0 + Protocol.T_START_CLOSE_BLAME).floor());

    print("sending proofs");
    status = Tuple('running', 'round failed - sending proofs');

// create a list of commitment indexes, but leaving out mine.
    List<int> othersCommitmentIdxes = [];
    for (int i = 0; i < allCommitments.length; i++) {
      if (!myCommitmentIndexes.contains(i)) {
        othersCommitmentIdxes.add(i);
      }
    }
    int N = othersCommitmentIdxes.length;
    assert(N == allCommitments.length - myCommitments.length);
    if (N == 0) {
      throw FusionError(
          "Fusion failed with only me as player -- I can only blame myself.");
    }

// where should I send my proofs?
    List<InitialCommitment> dstCommits = [];
    for (int i = 0; i < myCommitments.length; i++) {
      dstCommits.add(allCommitments[
          othersCommitmentIdxes[Util.randPosition(randomNumber, N, i)]]);
    }

// generate the encrypted proofs
    List<String> encproofs = List<String>.filled(myCommitments.length, '');

    ECDomainParameters params = ECDomainParameters('secp256k1');
    for (int i = 0; i < dstCommits.length; i++) {
      InitialCommitment msg = dstCommits[i];
      Proof proof = myProofs[i];
      proof.componentIdx = myComponentIndexes[i];

      ECPoint? communicationKeyPointMaybe =
          params.curve.decodePoint(Uint8List.fromList(msg.communicationKey));
      if (communicationKeyPointMaybe == null) {
        // handle the error case here, e.g., throw an exception or skip this iteration.
        continue;
      }
      ECPoint communicationKeyPoint = communicationKeyPointMaybe;

      try {
        Uint8List encryptedData = await encrypt(
            proof.writeToBuffer(), communicationKeyPoint,
            padToLength: 80);
        encproofs[i] = String.fromCharCodes(encryptedData);
      } catch (EncryptionFailed) {
        // The communication key was bad (probably invalid x coordinate).
        // We will just send a blank. They can't even blame us since there is no private key! :)
        continue;
      }
    }

    List<Uint8List> encodedEncproofs =
        encproofs.map((e) => Uint8List.fromList(e.codeUnits)).toList();
    this.send(MyProofsList(
        encryptedProofs: encodedEncproofs, randomNumber: randomNumber));

    status = Tuple('running', 'round failed - checking proofs');

    print("receiving proofs");
    msg = await recv(['theirproofslist'],
        timeout: Duration(seconds: (2 * Protocol.STANDARD_TIMEOUT).round()));

    List<Blames_BlameProof> blames = [];

    int countInputs = 0;

    TheirProofsList proofsList = msg as TheirProofsList;

    List<int>? privKey;
    InitialCommitment commitmentBlob;
    for (var i = 0; i < proofsList.proofs.length; i++) {
      TheirProofsList_RelayedProof rp = msg.proofs[i];
      try {
        privKey = privKeys[rp.dstKeyIdx];
        commitmentBlob = allCommitments[rp.srcCommitmentIdx];
      } on RangeError catch (e) {
        throw FusionError("Server relayed bad proof indices");
      }

      List<int> sKey;
      Uint8List proofBlob;

      try {
        BigInt eccPrivateKey =
            parseBigIntFromBytes(Uint8List.fromList(privKey));
        ECPrivateKey privateKey = ECPrivateKey(eccPrivateKey, params);

        Tuple<Uint8List, Uint8List> result =
            await decrypt(Uint8List.fromList(rp.encryptedProof), privateKey);
        proofBlob = result.item1; // First item is the decrypted data
        sKey = result.item2; // Second item is the symmetric key
      } on Exception catch (e) {
        print("found an undecryptable proof");
        blames.add(Blames_BlameProof(
            whichProof: i,
            privkey: privKey as List<int>?,
            blameReason: 'undecryptable'));
        continue;
      }

      InitialCommitment commitment = InitialCommitment();
      try {
        commitment.mergeFromBuffer(
            commitmentBlob as List<int>); // Method to parse protobuf data
      } on FormatException catch (e) {
        throw FusionError("Server relayed bad commitment");
      }

      InputComponent? inpComp;

      try {
        // Convert allComponents to List<Uint8List>
        List<Uint8List> allComponentsUint8 = allComponents
            .map((component) => Uint8List.fromList(component))
            .toList();
        // Convert badComponents to List<int>
        List<int> badComponentsList = badComponents.toList();
        // Convert componentFeeRate to int if it's double
        int componentFeerateInt = componentFeeRate
            .round(); // or use .toInt() if you want to truncate instead of rounding

        InputComponent? inpComp = validateProofInternal(proofBlob, commitment,
            allComponentsUint8, badComponentsList, componentFeerateInt);
      } on Exception catch (e) {
        print("found an erroneous proof: ${e.toString()}");
        Blames_BlameProof blameProof = Blames_BlameProof();
        blameProof.whichProof = i;
        blameProof.sessionKey = sKey;
        blameProof.blameReason = e.toString();
        blames.add(blameProof);
        continue;
      }

      if (inpComp != null) {
        countInputs++;
        try {
          Util.checkInputElectrumX(inpComp);
        } on Exception catch (e) {
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
          print(
              "verified an input internally, but was unable to check it against blockchain: ${e}");
        }
      }
    }
    print("checked ${msg.proofs.length} proofs, $countInputs of them inputs");

    print("sending blames");
    send(Blames(blames: blames));

    status = Tuple('running', 'awaiting restart');

// Await the final 'restartround' message. It might take some time
// to arrive since other players might be slow, and then the server
// itself needs to check blockchain.
    await recv(['restartround'],
        timeout: Duration(
            seconds: 2 *
                (Protocol.STANDARD_TIMEOUT.round() +
                    Protocol.BLAME_VERIFY_TIME.round())));
    return true;
  } // end of run_round() function.
}

BigInt parseBigIntFromBytes(Uint8List bytes) {
  return BigInt.parse(
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
    radix: 16,
  );
}

extension HexEncoding on List<int> {
  String toHex() {
    return map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
//  END OF CLASS

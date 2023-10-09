import 'dart:math';
import 'dart:typed_data';

import 'package:bitbox/bitbox.dart' as bitbox;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:fixnum/fixnum.dart';
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/extensions/on_big_int.dart';
import 'package:fusiondart/src/models/protobuf.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/protocol.dart';

abstract final class OutputHandling {
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
  static Future<
      (
        List<(String, List<bitbox.Input>)>, // Eligible.
        List<(String, List<bitbox.Input>)>, // Ineligible.
        BigInt, // sumValue.
        bool, // hasUnconfirmed.
        bool // hasCoinbase.
      )> selectCoins(
    List<bitbox.Input> _coins, {
    required int currentChainHeight,
    required Future<List<Address>> Function() getAddresses,
    required Future<List<bitbox.Input>> Function(String address)
        getInputsByAddress,
    required Future<List<Map<String, dynamic>>> Function(String address)
        getTransactionsByAddress,
  }) async {
    List<(String, List<bitbox.Input>)> eligible =
        []; // List of eligible inputs.
    List<(String, List<bitbox.Input>)> ineligible =
        []; // List of ineligible inputs.
    bool hasUnconfirmed = false; // Are there unconfirmed coins?
    bool hasCoinbase = false; // Are there coinbase coins?
    BigInt sumValue =
        BigInt.zero; // Sum of the values of the eligible `Input`s.
    int mincbheight = currentChainHeight + Fusion.COINBASE_MATURITY;

    // Loop through the addresses in the wallet.
    for (Address address in await getAddresses()) {
      // Get the coins for the address.
      List<bitbox.Input> acoins = await getInputsByAddress(address.address);

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
        sumValue += BigInt.from(c.value ?? 0); // TODO verify 0 works as default

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
        eligible.add((address.address, acoins));
      } else {
        // Add the address and coins to the ineligible list.
        ineligible.add((address.address, acoins));
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
  ///   A `Future<List<Input>>` that completes with a list of random coins.
  static Future<List<bitbox.Input>> selectRandomCoins(
    double fraction,
    List<(String, List<bitbox.Input>)> eligible,
    Future<List<Map<String, dynamic>>> Function(String address)
        getTransactionsByAddress,
  ) async {
    // Shuffle the eligible buckets.
    var addrCoins = List<(String, List<bitbox.Input>)>.from(eligible);
    addrCoins.shuffle();

    // Initialize the result set.
    Set<String> resultTxids = {};

    // Initialize the result list.
    List<bitbox.Input> result = [];

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
        if (numCoins >= Fusion.DEFAULT_MAX_COINS) {
          // We have enough coins, so break.
          break;
        } else if (numCoins + acoins.length > Fusion.DEFAULT_MAX_COINS) {
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
        List<Map<String, dynamic>> ctxs = await getTransactionsByAddress(addr);

        // Extract the txids from the transactions.
        Set<String> ctxids = ctxs.map((tx) => tx["txid"] as String).toSet();

        // Check if there are any collisions.
        var collisions = ctxids.intersection(resultTxids);

        // Check if we should skip this bucket.
        //
        // Note each collision gives a separate chance of discarding this bucket.
        if (Random().nextDouble() >
            pow(Fusion.KEEP_LINKED_PROBABILITY, collisions.length)) {
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
          result = res.toList();
        } catch (e) {
          // Handle exception where all eligible buckets were cleared.
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
  static Future<
      ({
        List<bitbox.Input> inputs,
        Map<int, List<int>> tierOutputs,
        int safetySumIn,
        Map<int, int> safetyExcessFees,
      })> allocateOutputs({
    required Connection connection,
    required FusionStatus status,
    required List<bitbox.Input> coins,
    required int currentChainHeight,
    required ({
      int numComponents,
      int componentFeeRate,
      int minExcessFee,
      int maxExcessFee,
      List<int> availableTiers,
    }) serverParams,
    required Future<List<Address>> Function() getAddresses,
    required Future<List<bitbox.Input>> Function(String address)
        getInputsByAddress,
    required Future<List<Map<String, dynamic>>> Function(String address)
        getTransactionsByAddress,
  }) async {
    Utilities.debugPrint("DBUG allocateoutputs 746");
    Utilities.debugPrint("CHECK socketwrapper 746");

    if (!(status == FusionStatus.connecting || status == FusionStatus.setup)) {
      throw Exception(
          "allocateOutputs called with unexpected FusionStatus: $status");
    }

    // Get the coins.
    (
      List<(String, List<bitbox.Input>)>, // Eligible.
      List<(String, List<bitbox.Input>)>, // Ineligible.
      BigInt, // sumValue.
      bool, // hasUnconfirmed.
      bool // hasCoinbase _selections = await selectCoins(_inputs);
    ) _selections = await selectCoins(
      coins,
      currentChainHeight: currentChainHeight,
      getAddresses: getAddresses,
      getInputsByAddress: getInputsByAddress,
      getTransactionsByAddress: getTransactionsByAddress,
    );

    // Initialize the eligible set.
    List<bitbox.Input> eligible = [];

    // Loop through each key-value pair in the Map to extract Inputs and put them in the Set.
    for ((String, List<bitbox.Input>) inputList in _selections.$1) {
      for (bitbox.Input input in inputList.$2) {
        if (!eligible.contains(input)) {
          // Shouldn't this be accomplished by the Set?
          eligible.add(input);
        }
      }
    }

    // Select random coins from the eligible set.
    final inputs = await selectRandomCoins(
      _getFraction(_selections.$3),
      _selections.$1,
      getTransactionsByAddress,
    );
    /*await selectRandomCoins(
            numComponents / eligible.length, _selections.$1);*/
    int numInputs = inputs.length; // Number of inputs selected.

    // Calculate limits on the number of components and outputs.
    int maxComponents =
        min(serverParams.numComponents, Protocol.MAX_COMPONENTS);
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
    BigInt sumInputsValue = BigInt.from(inputs
            .map((input) => input.value)
            .reduce((a, b) => (a ?? 0) + (b ?? 0)) ??
        0);
    // TODO verify 0s as defaults work above.
    int inputFees = inputs.fold(
        0,
        (sum, input) =>
            sum +
            Utilities.componentFee(
                input.sizeOfInput(), serverParams.componentFeeRate));
    // TODO implement sizeOfInput(), probably in Utilities.
    /*
    // Equivalent to the fold above.
    int inputFees = 0;
    for (Input input in inputs) {
      inputFees +=
      Utilities.componentFee(input.sizeOfInput(), componentFeeRate.toInt());
    }
     */
    BigInt availForOutputs = sumInputsValue -
        BigInt.from(inputFees) -
        BigInt.from(serverParams.minExcessFee);

    // Calculate fees per output.
    int feePerOutput = Utilities.componentFee(
      34,
      serverParams.componentFeeRate,
    );
    final offsetPerOutput = BigInt.from(Protocol.MIN_OUTPUT + feePerOutput);

    // Check if the selected inputs have sufficient value.
    if (availForOutputs < offsetPerOutput) {
      throw FusionError('Selected inputs had too little value');
    }

    // Allocate the outputs based on available tiers.
    //
    // The allocated outputs and excess fees are stored in instance variables.
    Utilities.debugPrint("DBUG allocateoutputs 785");
    final Map<int, List<int>> tierOutputs = {};
    final Map<int, int> excessFees = <int, int>{};

    // Loop through each available tier to determine the optimal fee and outputs.
    for (int scale in serverParams.availableTiers) {
      // Calculate the maximum fuzz fee for this tier, which is the scale divided by 1,000,000.
      int fuzzFeeMax = scale ~/ 1000000;

      // Reduce the maximum allowable fuzz fee considering the minimum and maximum
      // excess fees and the maximum limit defined in the Protocol.
      int fuzzFeeMaxReduced = min(
          fuzzFeeMax,
          min(Protocol.MAX_EXCESS_FEE - serverParams.minExcessFee,
              serverParams.maxExcessFee));

      // Ensure that the reduced maximum fuzz fee is non-negative.
      assert(fuzzFeeMaxReduced >= 0);

      // Randomly pick a fuzz fee in the range `[0, fuzzFeeMaxReduced]`.
      Random rng = Random();
      final fuzzFee = BigInt.from(rng.nextInt(fuzzFeeMaxReduced + 1));

      // Reduce the available amount for outputs by the selected fuzz fee.
      final reducedAvailForOutputs = availForOutputs - fuzzFee;

      // If the reduced available amount for outputs is less than the offset per
      // output, skip to the next iteration.
      if (reducedAvailForOutputs < offsetPerOutput) {
        continue;
      }

      // Generate a list of random outputs for this tier.
      List<int>? _outputs = randomOutputsForTier(
        rng,
        reducedAvailForOutputs.toInt(), // toInt()  ...WCGW
        scale,
        offsetPerOutput.toInt(), // toInt()  ...WCGW
        maxOutputs,
      );

      // Check if the list of outputs is null or has fewer items than the minimum
      // required number of outputs.
      if (_outputs == null || _outputs.length < minOutputs) {
        continue;
      }

      // Adjust each output value by subtracting the fee per output.
      _outputs = _outputs.map((o) => o - feePerOutput).toList();

      // Ensure the total number of components (inputs + outputs) does not exceed
      // the maximum limit defined in the Protocol.
      assert(inputs.length + (_outputs.length) <= Protocol.MAX_COMPONENTS);

      // Store the calculated excess fee for this tier.
      excessFees[scale] =
          (sumInputsValue - BigInt.from(inputFees) - reducedAvailForOutputs)
              .toInt();

      // Store the list of output values for this tier.
      tierOutputs[scale] = _outputs;
    }

    Utilities.debugPrint('Possible tiers: $tierOutputs');

    return (
      inputs: inputs,
      tierOutputs: tierOutputs,
      safetySumIn: sumInputsValue.toInt(), // toInt()  ...WCGW
      safetyExcessFees: excessFees,
    );
  } // End of `allocateOutputs()`.

  /// Generates the components required for a fusion transaction.
  ///
  /// Given the number of blank components [numBlanks], input components [inputs],
  /// output components [outputs], and fee rate [feerate], this method generates and
  /// returns a list of `ComponentResult` objects that include all necessary
  /// details for a fusion transaction.
  ///
  /// Returns:
  ///   A list of `ComponentResult` objects containing all the components needed for the transaction.
  static ({
    List<ComponentResult> results,
    BigInt sumAmounts,
    Uint8List pedersenTotalNonce,
  }) genComponents(
    coinlib.NetworkParams network,
    int numBlanks,
    List<bitbox.Input> inputs,
    List<Output> outputs,
    int feerate,
  ) {
    // Sanity check.
    if (numBlanks < 0) {
      throw Exception("genComponents called with numBlanks less than 0");
    }

    // Initialize list of components.
    List<({Component component, BigInt value})> components = [];

    // Generate components.
    for (bitbox.Input input in inputs) {
      // Calculate fee.
      int fee = Utilities.componentFee(input.sizeOfInput(), feerate);
      // TODO implement sizeOfInput().

      // Create input component.
      final comp = Component()
        ..input = InputComponent(
          prevTxid: Uint8List.fromList(
            input.prevTxid.reversed.toList(),
          ), // Why is this reversed?
          prevIndex: input.prevIndex,
          pubkey: input.pubKey,
          amount: Int64.parseHex((input.value).toHex),
        );

      // Add component and fee to list.
      components.add(
        (
          component: comp,
          value: BigInt.from(input.value ?? 0 - fee),
          // TODO verify 0 as default works above.
        ),
      );
    }

    // Generate components for outputs.
    for (Output output in outputs) {
      // Calculate fee.
      List<int> script = output.addr.toScript(network);

      // Calculate fee.
      int fee = Utilities.componentFee(output.sizeOfOutput(network), feerate);

      // Create output component.
      final comp = Component()
        ..output =
            OutputComponent(scriptpubkey: script, amount: Int64(output.value));

      // Add component and fee to list.
      components.add(
        (
          component: comp,
          value:
              (BigInt.from(-1) * BigInt.from(output.value)) - BigInt.from(fee),
        ),
      );
    }

    // Generate components for blanks.
    for (int i = 0; i < numBlanks; i++) {
      components.add(
        (
          component: Component()..blank = BlankComponent(),
          value: BigInt.zero,
        ),
      );
    }

    // Initialize result list.
    List<ComponentResult> resultList = [];
    BigInt sumAmounts = BigInt.zero;
    BigInt sumNonce = BigInt.zero;

    // Generate commitments.
    components.asMap().forEach((cnum, componentRecord) {
      // Generate salt.
      final salt = Utilities.tokenBytes(32);
      componentRecord.component.saltCommitment = Utilities.sha256(salt);
      final compser = componentRecord.component.writeToBuffer();

      final pedersenCommitment = Utilities.pedersenSetup.commit(
        componentRecord.value,
      );
      sumAmounts += componentRecord.value;
      sumNonce += pedersenCommitment.nonce;

      // Generate keypair.
      (Uint8List, Uint8List) keyPair = Utilities.genKeypair();
      final privateKey = keyPair.$1;
      final pubKey = keyPair.$2;

      // Generating initial commitment.
      final commitment = InitialCommitment(
        saltedComponentHash:
            Utilities.sha256(Uint8List.fromList(compser + salt)),
        amountCommitment: pedersenCommitment.pointPUncompressed,
        communicationKey: pubKey,
      );

      // Write commitment to buffer.
      final commitser = commitment.writeToBuffer();

      // Generate proof.
      Proof proof = Proof(
        componentIdx: cnum,
        salt: salt,
        pedersenNonce: pedersenCommitment.nonce.toBytes,
      );

      // Add result to list.
      resultList.add(
        ComponentResult(
          commitment: commitser,
          counter: cnum,
          component: compser,
          proof: proof,
          privateKey: privateKey,
        ),
      );
    });

    // Sort resultList by commitser.
    resultList.sort((ComponentResult a, ComponentResult b) =>
        compareUint8List(a.commitment, b.commitment));

    // Calculate pedersen commitment for the total nonce.
    sumNonce = sumNonce % Utilities.secp256k1Params.n;

    return (
      results: resultList,
      sumAmounts: sumAmounts,
      pedersenTotalNonce: sumNonce.toBytes,
    );
  }

  /// Compare two Uint8Lists for sorting purposes.
  static int compareUint8List(Uint8List a, Uint8List b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] < b[i]) return -1;
      if (a[i] > b[i]) return 1;
    }
    if (a.length < b.length) return -1;
    if (a.length > b.length) return 1;
    return 0;
  }

  /// Generates random outputs given specific parameters.
  ///
  /// Generates a list of random integer values for output tiers, adhering to the given parameters
  /// [rng], [inputAmount], [scale], [offset], and [maxCount].
  ///
  /// Returns:
  ///   A list of integer values representing the random outputs for the tier.
  static List<int>? randomOutputsForTier(
    Random rng,
    int inputAmount,
    int scale,
    int offset,
    int maxCount,
  ) {
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

    // Rescale the cumsum to the desired sum.
    double rescale = desiredRandomSum / cumsum[cumsum.length - 1];
    List<int> normedCumsum = cumsum.map((v) => (rescale * v).round()).toList();
    assert(normedCumsum[normedCumsum.length - 1] == desiredRandomSum,
        'Last element of normedCumsum is not equal to desiredRandomSum');
    List<int> differences = [];
    differences.add(normedCumsum[0]); // First element
    for (int i = 1; i < normedCumsum.length; i++) {
      differences.add(normedCumsum[i] - normedCumsum[i - 1]);
    }

    // Add offset to differences.
    List<int> result = differences.map((d) => offset + d).toList();

    // Sanity check.
    assert(result.reduce((a, b) => a + b) == inputAmount,
        'Sum of result is not equal to inputAmount');

    return result;
  }

  // ================== private ================================================
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
  static double _getFraction(BigInt sumValue) {
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
}

# FusionDart

A Dart package for interacting with CashFusion servers.

# WARNING

 - Do not test this with a wallet with tokens.

Do not import/inject CashToken, SLP, and other non-standard outputs into this package.  Fusiondart itself does not currently check for tokens and their use in CashFusion transactions will almost certainly lead to their loss.

## Features

 - [x] Testnet support
 - [x] Connect to CashFusion servers
 - [x] Send and receive CashFusion messages and status updates
 - [x] Register for CashFusion tiers
 - [x] Send and receive CashFusion transactions

## Getting started

### Building

FusionDart uses [coinlib](https://github.com/peercoin/coinlib) for cryptocurrency calculations, which [needs to be built](https://github.com/peercoin/coinlib/tree/master/coinlib#building-for-linux).  Build it according to their documentation ([macOS instructions here](https://github.com/peercoin/coinlib/tree/master/coinlib#building-for-macos)).

### Toolchain

`pubspec.lock` is resolved with Flutter 3.44.8 (Dart 3.12.2), the version Stack Wallet uses.  The bitbox dependency pulls in the Flutter SDK, which pins some transitive packages such as `meta` and `vector_math`, so other Flutter versions rewrite the lockfile.

`dart test -x slow` skips the slow tests.

The checked-in protocol bindings support protobuf runtime versions 4.1
through 6.x. See the regeneration instructions below before updating them.

## Usage

See [cypherstack/stack_wallet/lib/services/mixins/fusion_wallet_interface.dart](https://github.com/cypherstack/stack_wallet/blob/fusion/lib/services/mixins/fusion_wallet_interface.dart) for a working example.  It follows this basic pattern:

```dart
import 'package:fusiondart/fusiondart.dart';

// Use server host and port which ultimately come from text fields.
fusion.FusionParams serverParams = fusion.FusionParams(
   serverHost: "fusion.servo.cash",
   serverPort: 8789,
   serverSsl: true,
   genesisHashHex: "000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943",
   mode: fusion.FusionMode.normal, // normal, fanout, or consolidate.
   torForOver: false,
   enableDebugPrint: true, // Set to false for release.
);

// Instantiate a Fusion object with custom parameters.
_mainFusionObject = fusion.Fusion(serverParams);

// Pass wallet functions to the Fusion object.
await _mainFusionObject!.initFusion(
   getTransactionsByAddress: _getTransactionsByAddress,
   getUnusedReservedChangeAddresses: _getUnusedReservedChangeAddresses,
   getSocksProxyAddress: _getSocksProxyAddress,
   getChainHeight: _getChainHeight,
   updateStatusCallback: _updateStatus,
   checkUtxoExists: _checkUtxoExists,
   getTransactionJson: _getTransactionJson,
   getPrivateKeyForPubKey: _getPrivateKeyForPubKey,
   broadcastTransaction: _broadcastTransaction,
   unReserveAddresses: _unReserveAddresses,
);


// Fuse UTXOs.
await _mainFusionObject!.fuse(
   inputsFromWallet: coinList,
   network: fusion.Utilities.testNet,
);
```

You will need to define the injected methods `_getTransactionsByAddress`, `_getUnusedReservedChangeAddresses`, etc.

## Contributing

See https://github.com/cypherstack/fusiondart/issues for a list of issues to which you may contribute.  Please PR against the `staging` branch.

## Building Dart Files from fusion.proto

This section describes how to generate Dart files based on the `fusion.proto` file.

### Prerequisites

- Install `protoc` 3.21.12.
- Install the protobuf 4-era Dart generator used by the checked-in bindings:

    ```bash
    dart pub global activate protoc_plugin 22.1.0
    ```

### Steps

1. From any directory, run:

    ```bash
    ./lib/src/protobuf/build-proto-fusion.sh
    ```

The checked-in bindings use `protoc` 3.21.12 and `protoc_plugin` 22.1.0. Their
`fusion.proto` SHA-256 is
`22b8a137176c28ecd12bb6fde8c44662b555a470e79a5203105e363abf9307da`.
The script regenerates the files in place and runs
`tool/patch_generated_proto.dart`. The postprocessor preserves the generated
public `createRepeated()` methods while replacing the `PbList()` constructor
removed in protobuf 6 with an implementation supported by protobuf 4 through
6. It is safe to run the postprocessor more than once.

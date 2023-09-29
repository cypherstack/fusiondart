# FusionDart

A Dart package for interacting with CashFusion servers.

# WARNING

 - Do not test this with a wallet with significant funds.
 - Do not test this with a wallet with tokens.

These actions may result in loss of funds, tokens, or both.  Outputs are not currently checked for tokens and their use in CashFusion transactions will almost certainly lead to their loss.

## Features

 - [x] Connect to a CashFusion server
 - [x] Create CashFusion sessions
 - [x] Join CashFusion sessions
 - [x] Send and receive CashFusion messages
 - [ ] Send and receive CashFusion transactions
 - [ ] Send and receive CashFusion status updates
 - [ ] Send and receive CashFusion errors
 - [ ] Send and receive CashFusion session stats
 - [ ] Send and receive CashFusion session stats updates
 - [ ] Send and receive CashFusion session stats errors
 - [ ] Send and receive CashFusion session stats updates errors

## Getting started

### Building

FusionDart uses [coinlib](https://github.com/peercoin/coinlib) for cryptocurrency calculations, which [needs to be built](https://github.com/peercoin/coinlib/tree/master/coinlib#building-for-linux).  Build it according to their documentation ([macOS instructions here](https://github.com/peercoin/coinlib/tree/master/coinlib#building-for-macos)).

### Example

Check `/example` folder for a sample app.

## Usage

```dart
import 'package:fusiondart/fusiondart.dart';

// TODO
```

## Building Dart Files from fusion.proto

This section describes how to generate Dart files based on the `fusion.proto` file.

### Prerequisites

- Ensure that you have the `protoc` command-line tool installed.
- Navigate to the directory containing your `fusion.proto` file.

### Steps

1. Open your terminal and navigate to the directory where your `fusion.proto` file is located.
2. Run the following script ([fusiondart/lib/src/protobuf/build-proto-fusion.sh](https://github.com/cypherstack/fusiondart/blob/staging/lib/src/protobuf/build-proto-fusion.sh)) to generate the Dart files:

    ```bash
    #!/bin/bash

    # This script will build the dart files based on fusion.proto.

    # The path to your .proto file. Adjust this if necessary.
    PROTO_FILE="fusion.proto"

    # Run the protoc command.
    protoc --dart_out=grpc:. $PROTO_FILE
    ```

3. After running the script, Dart files will be generated in the same directory as your `.proto` file.
4. Manually copy any generated Dart files that you need to your `lib` folder.

<!-- 
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/guides/libraries/writing-package-pages). 

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-library-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/developing-packages). 
-->

# fusiondart

A Dart package for interacting with CashFusion servers.

## Features

 - [ ] Connect to CashFusion servers
 - [ ] Create CashFusion sessions
 - [ ] Join CashFusion sessions
 - [ ] Send and receive CashFusion messages
 - [ ] Send and receive CashFusion transactions
 - [ ] Send and receive CashFusion status updates
 - [ ] Send and receive CashFusion errors
 - [ ] Send and receive CashFusion session stats
 - [ ] Send and receive CashFusion session stats updates
 - [ ] Send and receive CashFusion session stats errors
 - [ ] Send and receive CashFusion session stats updates errors

## Getting started

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

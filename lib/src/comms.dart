import 'dart:async';
import 'dart:io';

import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/fusion.dart';
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/socketwrapper.dart';
import 'package:fusiondart/src/util.dart';
import 'package:protobuf/protobuf.dart';

typedef PbCreateFunc = GeneratedMessage Function();

Map<Type, PbCreateFunc> pbClassCreators = {
  CovertResponse: () => CovertResponse(),
  ClientMessage: () => ClientMessage(),
  InputComponent: () => InputComponent(),
  OutputComponent: () => OutputComponent(),
  BlankComponent: () => BlankComponent(),
  Component: () => Component(),
  InitialCommitment: () => InitialCommitment(),
  Proof: () => Proof(),
  ClientHello: () => ClientHello(),
  ServerHello: () => ServerHello(),
  JoinPools: () => JoinPools(),
  TierStatusUpdate: () => TierStatusUpdate(),
  FusionBegin: () => FusionBegin(),
  StartRound: () => StartRound(),
  PlayerCommit: () => PlayerCommit(),
  BlindSigResponses: () => BlindSigResponses(),
  AllCommitments: () => AllCommitments(),
  CovertComponent: () => CovertComponent(),
  ShareCovertComponents: () => ShareCovertComponents(),
  CovertTransactionSignature: () => CovertTransactionSignature(),
  FusionResult: () => FusionResult(),
  MyProofsList: () => MyProofsList(),
  TheirProofsList: () => TheirProofsList(),
  Blames: () => Blames(),
  RestartRound: () => RestartRound(),
  Error: () => Error(),
  Ping: () => Ping(),
  OK: () => OK(),
  ServerMessage: () => ServerMessage(),
  CovertMessage: () => CovertMessage(),
};

Future<void> sendPb(
    Connection connection, Type pbClass, GeneratedMessage subMsg,
    {Duration? timeout}) async {
  // Construct the outer message with the submessage.

  if (pbClassCreators[pbClass] == null) {
    print('pbClassCreators[pbClass] is null');
    return;
  }

  GeneratedMessage pbMessage = pbClassCreators[pbClass]!()
    ..mergeFromMessage(subMsg);
  final msgBytes = pbMessage.writeToBuffer();
  try {
    await connection.sendMessage(msgBytes, timeout: timeout);
  } on SocketException {
    throw FusionError('Connection closed by remote');
  } on TimeoutException {
    throw FusionError('Timed out during send');
  } catch (e) {
    throw FusionError('Communications error: ${e.runtimeType}: $e');
  }
}

Future<void> sendPb2(SocketWrapper socketwrapper, Connection connection,
    Type pbClass, GeneratedMessage subMsg,
    {Duration? timeout}) async {
  // Construct the outer message with the submessage.

  if (pbClassCreators[pbClass] == null) {
    print('pbClassCreators[pbClass] is null');
    return;
  }

  GeneratedMessage pbMessage = pbClassCreators[pbClass]!()
    ..mergeFromMessage(subMsg);
  final msgBytes = pbMessage.writeToBuffer();
  try {
    await connection.sendMessageWithSocketWrapper(socketwrapper, msgBytes,
        timeout: timeout);
  } on SocketException {
    throw FusionError('Connection closed by remote');
  } on TimeoutException {
    throw FusionError('Timed out during send');
  } catch (e) {
    throw FusionError('Communications error: ${e.runtimeType}: $e');
  }
}

Future<Tuple<GeneratedMessage, String>> recvPb2(SocketWrapper socketwrapper,
    Connection connection, Type pbClass, List<String> expectedFieldNames,
    {Duration? timeout}) async {
  try {
    List<int> blob =
        await connection.recv_message2(socketwrapper, timeout: timeout);

    GeneratedMessage pbMessage = pbClassCreators[pbClass]!()
      ..mergeFromBuffer(blob);

    if (!pbMessage.isInitialized()) {
      throw FusionError('Incomplete message received');
    }

    for (String name in expectedFieldNames) {
      // TODO type
      FieldInfo<dynamic>? fieldInfo = pbMessage.info_.byName[name];

      if (fieldInfo == null) {
        throw FusionError('Expected field not found in message: $name');
      }

      if (pbMessage.hasField(fieldInfo.tagNumber)) {
        return Tuple(pbMessage, name);
      }
    }

    throw FusionError(
        'None of the expected fields found in the received message');
  } catch (e) {
    // Handle different exceptions here
    if (e is SocketException) {
      throw FusionError('Connection closed by remote');
    } else if (e is InvalidProtocolBufferException) {
      throw FusionError('Message decoding error: ' + e.toString());
    } else if (e is TimeoutException) {
      throw FusionError('Timed out during receive');
    } else if (e is OSError && e.errorCode == 9) {
      throw FusionError('Connection closed by local');
    } else {
      throw FusionError(
          'Communications error: ${e.runtimeType}: ${e.toString()}');
    }
  }
}

Future<Tuple<GeneratedMessage, String>> recvPb(
    Connection connection, Type pbClass, List<String> expectedFieldNames,
    {Duration? timeout}) async {
  try {
    List<int> blob = await connection.recv_message(timeout: timeout);

    GeneratedMessage pbMessage = pbClassCreators[pbClass]!()
      ..mergeFromBuffer(blob);

    if (!pbMessage.isInitialized()) {
      throw FusionError('Incomplete message received');
    }

    for (String name in expectedFieldNames) {
      // TODO type
      FieldInfo<dynamic>? fieldInfo = pbMessage.info_.byName[name];

      if (fieldInfo == null) {
        throw FusionError('Expected field not found in message: $name');
      }

      if (pbMessage.hasField(fieldInfo.tagNumber)) {
        return Tuple(pbMessage, name);
      }
    }

    throw FusionError(
        'None of the expected fields found in the received message');
  } catch (e) {
    // Handle different exceptions here
    if (e is SocketException) {
      throw FusionError('Connection closed by remote');
    } else if (e is InvalidProtocolBufferException) {
      throw FusionError('Message decoding error: ' + e.toString());
    } else if (e is TimeoutException) {
      throw FusionError('Timed out during receive');
    } else if (e is OSError && e.errorCode == 9) {
      throw FusionError('Connection closed by local');
    } else {
      throw FusionError(
          'Communications error: ${e.runtimeType}: ${e.toString()}');
    }
  }
}

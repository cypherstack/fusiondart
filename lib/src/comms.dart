import 'dart:async';
import 'dart:io';

import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/exceptions.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:protobuf/protobuf.dart';

/// Type definition for a function that creates a new instance of a Protobuf GeneratedMessage.
typedef PbCreateFunc = GeneratedMessage Function();

/// A mapping of Protobuf message types to their respective factory functions.
///
/// This map allows us to instantiate a new Protobuf message object given its type.
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

/// Sends a Protobuf message [subMsg] of type [pbClass] over a [connection].
///
/// [DEPRECATED], use sendPb2 instead.  TODO remove this function.
///
/// Parameters:
/// - [connection]: The connection object through which the message will be sent.
/// - [pbClass]: The Protobuf class type to send.
/// - [subMsg]: The specific Protobuf message to send.
/// - [timeout]: (Optional) The time duration to wait before timing out.
///
/// Returns:
///   A Future<void> object.
///
/// Throws:
///   FusionError: If any step in the sending process fails.
Future<void> sendPb(
  Connection connection,
  GeneratedMessage pbMessage, {
  Duration? timeout,
}) async {
  // Convert the Protobuf message to bytes.
  final msgBytes = pbMessage.writeToBuffer();

  try {
    // Send the message through the connection.
    await connection.sendMessage(msgBytes, timeout: timeout);
  } on SocketException {
    throw FusionError('Connection closed by remote');
  } on TimeoutException {
    throw FusionError('Timed out during send');
  } catch (e) {
    throw FusionError('Communications error: ${e.runtimeType}: $e');
  }
}

/// Receives a protocol buffer message from the server.
///
/// This function is used to receive a protocol buffer message from the server.
/// It is similar to recvPb2, but it does not take a SocketWrapper object.
///
/// Parameters:
/// - [connection] Connection instance to the server.
/// - [pbClass] The protocol buffer message type to be received.
/// - [expectedFieldNames] List of field names that are expected to be in the received message.
/// - [timeout] Optional parameter for timeout duration.
///
/// Returns:
///   A Record containing the received GeneratedMessage and the name of the field that was received.
///
/// Throws:
///   FusionError: If there's an error in the communication process or if the received message lacks expected fields.
Future<(GeneratedMessage, String)> recvPb(
    Connection connection, Type pbClass, List<String> expectedFieldNames,
    {Duration? timeout}) async {
  try {
    // Receive the message blob from the server.
    List<int> blob = await connection.recvMessage(timeout: timeout);

    // Deserialize the blob into a protocol buffer message.
    GeneratedMessage pbMessage = pbClassCreators[pbClass]!()
      ..mergeFromBuffer(blob);

    // Check if the message is complete.
    if (!pbMessage.isInitialized()) {
      throw FusionError('Incomplete message received');
    }

    // Check for the presence of expected fields.
    for (String name in expectedFieldNames) {
      // TODO define type for fieldInfo
      FieldInfo<dynamic>? fieldInfo = pbMessage.info_.byName[name];

      if (fieldInfo == null) {
        throw FusionError('Expected field not found in message: $name');
      }

      // Check if the field is present in the message.
      if (pbMessage.hasField(fieldInfo.tagNumber)) {
        return (pbMessage, name);
      }
    }

    throw FusionError(
        'None of the expected fields found in the received message');
  } catch (e) {
    if (e is SocketException) {
      throw FusionError('Connection closed by remote');
    } else if (e is InvalidProtocolBufferException) {
      throw FusionError('Message decoding error: $e');
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

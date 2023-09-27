import 'dart:convert';
import 'dart:typed_data';

import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/comms.dart';
import 'package:fusiondart/src/connection.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:fusiondart/src/protocol.dart';
import 'package:fusiondart/src/socketwrapper.dart';
import 'package:fusiondart/src/util.dart';
import 'package:protobuf/protobuf.dart';

abstract final class IO {
  static Future<GeneratedMessage> recv(
    List<String> expectedMsgNames, {
    Duration? timeout,
    required Connection connection,
    required SocketWrapper socketWrapper,
  }) async {
    // Receive the message from the server.
    final (GeneratedMessage, String) result = await recvPb2(
      socketWrapper,
      connection,
      ServerMessage,
      expectedMsgNames,
      timeout: timeout,
    );

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

  static Future<void> send(
    GeneratedMessage submsg, {
    Duration? timeout,
    required Connection connection,
    required SocketWrapper socketWrapper,
  }) async {
    // Send the message to the server.
    return await sendPb2(socketWrapper, connection, ClientMessage, submsg,
        timeout: timeout);
  }

  static Future<
      ({
        int numComponents,
        int componentFeeRate,
        int minExcessFee,
        int maxExcessFee,
        List<int> availableTiers,
      })> greet({
    required Connection connection,
    required SocketWrapper socketWrapper,
  }) async {
    // Create the ClientHello message with version and genesis hash.
    final clientHello = ClientHello(
        version: Uint8List.fromList(utf8.encode(Protocol.VERSION)),
        genesisHash: Utilities.getCurrentGenesisHash());

    // Wrap the ClientHello in a ClientMessage.
    ClientMessage clientMessage = ClientMessage()..clienthello = clientHello;

    // Send the message to the server.
    await send(
      clientMessage,
      connection: connection,
      socketWrapper: socketWrapper,
    );

    // Wait for a ServerHello message in reply.
    GeneratedMessage replyMsg = await recv(
      ['serverhello'],
      connection: connection,
      socketWrapper: socketWrapper,
    );

    // Process the ServerHello message.
    if (replyMsg is ServerMessage) {
      ServerHello reply = replyMsg.serverhello;

      // Extract and set various server parameters.
      final numComponents = reply.numComponents;
      final componentFeeRate = reply.componentFeerate.toInt();
      final minExcessFee = reply.minExcessFee.toInt();
      final maxExcessFee = reply.maxExcessFee.toInt();
      final availableTiers = reply.tiers.map((tier) => tier.toInt()).toList();

      // Enforce some sensible limits, in case server is crazy
      if (componentFeeRate > Protocol.MAX_COMPONENT_FEERATE) {
        throw FusionError('excessive component feerate from server');
      }
      if (minExcessFee > 400) {
        // note this threshold should be far below MAX_EXCESS_FEE.
        throw FusionError('excessive min excess fee from server');
      }
      if (minExcessFee > maxExcessFee) {
        throw FusionError('bad config on server: fees');
      }
      if (numComponents < Protocol.MIN_TX_COMPONENTS * 1.5) {
        throw FusionError('bad config on server: num_components');
      }

      return (
        numComponents: numComponents,
        componentFeeRate: componentFeeRate,
        minExcessFee: minExcessFee,
        maxExcessFee: maxExcessFee,
        availableTiers: availableTiers,
      );
    } else {
      throw Exception(
          'Received unexpected message type: ${replyMsg.runtimeType}');
    }
  }
}

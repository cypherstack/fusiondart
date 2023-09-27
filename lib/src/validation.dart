import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:collection/collection.dart';
import 'package:fusiondart/src/encrypt.dart' as encrypt;
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:fusiondart/src/models/input.dart';
import 'package:fusiondart/src/models/output.dart';
import 'package:fusiondart/src/pedersen.dart';
import 'package:fusiondart/src/protobuf/fusion.pb.dart' as pb;
import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/export.dart';
import 'package:protobuf/protobuf.dart';

class ValidationError implements Exception {
  final String message;
  ValidationError(this.message);
  @override
  String toString() => 'Validation error: $message';
}

int componentContrib(pb.Component component, int feerate) {
  if (component.hasInput()) {
    Input inp = Input.fromInputComponent(component.input);
    return inp.amount.toInt() -
        Utilities.componentFee(inp.sizeOfInput(), feerate);
  } else if (component.hasOutput()) {
    Output out = Output.fromOutputComponent(component.output);
    return -out.amount.toInt() -
        Utilities.componentFee(out.sizeOfOutput(), feerate);
  } else if (component.hasBlank()) {
    return 0;
  } else {
    throw ValidationError('Invalid component type');
  }
}

void check(bool condition, String failMessage) {
  if (!condition) {
    throw ValidationError(failMessage);
  }
}

T protoStrictParse<T extends GeneratedMessage>(T msg, List<int> blob) {
  try {
    msg.mergeFromBuffer(blob);
  } catch (e) {
    throw ArgumentError('ValidationError: decode error');
  }

  if (!(msg.isInitialized())) {
    throw ArgumentError('missing fields');
  }

  if (msg.unknownFields.isNotEmpty) {
    throw ArgumentError('has extra fields');
  }

  if (msg.writeToBuffer().length != blob.length) {
    throw ArgumentError('encoding too long');
  }

  return msg;
}

List<pb.InitialCommitment> checkPlayerCommit(pb.PlayerCommit msg,
    int minExcessFee, int maxExcessFee, int numComponents) {
  check(msg.initialCommitments.length == numComponents,
      "wrong number of component commitments");
  check(msg.blindSigRequests.length == numComponents,
      "wrong number of blind sig requests");

  check(
      minExcessFee <= msg.excessFee.toInt() &&
          msg.excessFee.toInt() <= maxExcessFee,
      "bad excess fee");

  check(msg.randomNumberCommitment.length == 32, "bad random commit");
  check(msg.pedersenTotalNonce.length == 32, "bad nonce");
  check(msg.blindSigRequests.every((r) => r.length == 32),
      "bad blind sig request");

  final List<pb.InitialCommitment> commitMessages = [];
  for (List<int> cblob in msg.initialCommitments) {
    final cmsg = protoStrictParse(pb.InitialCommitment(), cblob);
    check(cmsg.saltedComponentHash.length == 32, "bad salted hash");
    List<int> P = cmsg.amountCommitment;
    check(P.length == 65 && P[0] == 4, "bad commitment point");
    check(
        cmsg.communicationKey.length == 33 &&
            (cmsg.communicationKey[0] == 2 || cmsg.communicationKey[0] == 3),
        "bad communication key");
    commitMessages.add(cmsg);
  }

  final Uint8List hBytes =
      Uint8List.fromList([0x02] + 'CashFusion gives us fungibility.'.codeUnits);
  // final ECPoint? hMaybe = params.curve.decodePoint(hBytes);
  // if (hMaybe == null) {
  //   throw Exception('Failed to decode point');
  // }
  // final ECPoint H = hMaybe;
  final PedersenSetup setup = PedersenSetup(hBytes);

  final Commitment claimedCommit;
  final Uint8List pointsum;
  // Verify pedersen commitment
  try {
    pointsum = Utilities.addPoints(
      commitMessages
          .map((m) => Uint8List.fromList(m.amountCommitment))
          .toList(),
      Utilities.secp256k1Params,
    );
    claimedCommit = setup.commit(
      BigInt.from(msg.excessFee.toInt()),
      nonce: (Uint8List.fromList(msg.pedersenTotalNonce)).toBigInt,
    );

    check(pointsum == claimedCommit.pointPUncompressed,
        "pedersen commitment mismatch");
  } catch (e) {
    throw ValidationError("pedersen commitment verification error");
  }
  check(pointsum == claimedCommit.pointPUncompressed,
      "pedersen commitment mismatch");
  return commitMessages;
}

(String, int) checkCovertComponent(
    pb.CovertComponent msg, ECPoint roundPubkey, int componentFeerate) {
  Uint8List messageHash = Utilities.sha256(Uint8List.fromList(msg.component));

  check(msg.signature.length == 64, "bad message signature");
  check(Utilities.schnorrVerify(roundPubkey, msg.signature, messageHash),
      "bad message signature");

  final cmsg = protoStrictParse(pb.Component(), msg.component);
  check(cmsg.saltCommitment.length == 32, "bad salt commitment");

  final String sortKey;

  if (cmsg.hasInput()) {
    final inp = cmsg.input;
    check(inp.prevTxid.length == 32, "bad txid");
    check(
        (inp.pubkey.length == 33 &&
                (inp.pubkey[0] == 2 || inp.pubkey[0] == 3)) ||
            (inp.pubkey.length == 65 && inp.pubkey[0] == 4),
        "bad pubkey");

    sortKey = 'i${String.fromCharCodes(inp.prevTxid.reversed)}'
        '${inp.prevIndex.toString()}'
        '${String.fromCharCodes(cmsg.saltCommitment)}';
  } else if (cmsg.hasOutput()) {
    final out = cmsg.output;
    // Basically just checks if its ok address. should throw error if not.
    try {
      Utilities.getAddressFromOutputScript(out.scriptpubkey as Uint8List);
    } catch (_) {
      rethrow;
    }

    check(out.amount >= Utilities.dustLimit(out.scriptpubkey.length),
        "dust output");
    sortKey =
        'o${out.amount.toString()}${String.fromCharCodes(out.scriptpubkey)}${String.fromCharCodes(cmsg.saltCommitment)}';
  } else if (cmsg.hasBlank()) {
    sortKey = 'b${String.fromCharCodes(cmsg.saltCommitment)}';
  } else {
    throw ValidationError('missing component details');
  }

  return (sortKey, componentContrib(cmsg, componentFeerate));
}

pb.InputComponent? validateProofInternal(
  Uint8List proofBlob,
  pb.InitialCommitment commitment,
  List<Uint8List> allComponents,
  List<int> badComponents,
  int componentFeerate,
) {
  final Uint8List hBytes =
      Uint8List.fromList([0x02] + 'CashFusion gives us fungibility.'.codeUnits);
  // final ECPoint? hMaybe = params.curve.decodePoint(hBytes);
  // if (hMaybe == null) {
  //   throw Exception('Failed to decode point');
  // }
  // final ECPoint h = hMaybe;
  PedersenSetup setup = PedersenSetup(hBytes);

  final msg = protoStrictParse(pb.Proof(), proofBlob);

  Uint8List componentBlob;
  try {
    componentBlob = allComponents[msg.componentIdx];
  } catch (e) {
    throw ValidationError("component index out of range");
  }

  check(!badComponents.contains(msg.componentIdx), "component in bad list");

  final comp = pb.Component();
  comp.mergeFromBuffer(componentBlob);
  assert(comp.isInitialized());

  check(msg.salt.length == 32, "salt wrong length");
  check(
    Utilities.sha256(msg.salt as Uint8List) == comp.saltCommitment,
    "salt commitment mismatch",
  );

  // TODO validate
  Iterable<int> iterableSalt = msg.salt;
  check(
    Utilities.sha256(Uint8List.fromList([...iterableSalt, ...componentBlob])) ==
        commitment.saltedComponentHash,
    "salted component hash mismatch",
  );

  int contrib = componentContrib(comp, componentFeerate);

  final List<int> pCommitted = commitment.amountCommitment;

  final Commitment claimedCommit = setup.commit(
    BigInt.from(contrib),
    nonce: Uint8List.fromList(msg.pedersenNonce).toBigInt,
  );

  check(
    Uint8List.fromList(pCommitted) == claimedCommit.pointPUncompressed,
    "pedersen commitment mismatch",
  );

  if (comp.hasInput()) {
    return comp.input;
  } else {
    return null;
  }
}

Future<pb.InputComponent> validateBlame(
  pb.Blames_BlameProof blame,
  Uint8List encProof,
  Uint8List srcCommitBlob,
  Uint8List destCommitBlob,
  List<Uint8List> allComponents,
  List<int> badComponents,
  int componentFeerate,
) async {
  final destCommit = pb.InitialCommitment();
  destCommit.mergeFromBuffer(destCommitBlob);

  // TODO: why is this unused???
  // Looks unused in the python code as well...
  List<int> destPubkey = destCommit.communicationKey;

  final srcCommit = pb.InitialCommitment();
  srcCommit.mergeFromBuffer(srcCommitBlob);

  final decrypter = blame.whichDecrypter();

  if (decrypter == pb.Blames_BlameProof_Decrypter.privkey) {
    check(blame.privkey.length == 32, 'bad blame privkey');

    final privateKey = coinlib.ECPrivateKey(Uint8List.fromList(blame.privkey));

    check(destCommit.communicationKey.equals(privateKey.pubkey.data),
        'bad blame privkey');

    try {
      await encrypt.decrypt(
        encProof,
        Uint8List.fromList(blame.privkey),
      );
    } catch (e) {
      throw Exception("validateBlame() undecryptable");
    }
    throw ValidationError('blame gave privkey but decryption worked');
  } else if (decrypter != pb.Blames_BlameProof_Decrypter.sessionKey) {
    throw ValidationError('unknown blame decrypter');
  }
  Uint8List key = Uint8List.fromList(blame.sessionKey);
  check(key.length == 32, 'bad blame session key');
  Uint8List proofBlob;
  try {
    proofBlob = await encrypt.decryptWithSymmkey(encProof, key);
  } catch (e) {
    throw ValidationError('bad blame session key');
  }
  pb.InputComponent? inpComp;
  try {
    inpComp = validateProofInternal(
      proofBlob,
      srcCommit,
      allComponents,
      badComponents,
      componentFeerate,
    );
  } catch (e) {
    rethrow;
  }

  if (!blame.needLookupBlockchain) {
    throw ValidationError(
        'blame indicated internal inconsistency, none found!');
  }

  if (inpComp == null) {
    throw ValidationError(
        'blame indicated blockchain error on a non-input component');
  }

  return inpComp;
}

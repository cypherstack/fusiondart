import 'dart:typed_data';

import 'package:fusiondart/src/encrypt.dart' as Encrypt;
import 'package:fusiondart/src/fusion.pb.dart' as pb;
import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/models/address.dart';
import 'package:fusiondart/src/models/input.dart';
import 'package:fusiondart/src/models/output.dart';
import 'package:fusiondart/src/pedersen.dart';
import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/export.dart';

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

// TODO type
dynamic protoStrictParse(dynamic msg, List<int> blob) {
  // TODO validate "is InitialCommitment"
  try {
    if (msg.mergeFromBuffer(blob) != blob.length) {
      throw ArgumentError('DecodeError');
    }
  } catch (e) {
    throw ArgumentError('ValidationError: decode error');
  }

  if (!(msg.isInitialized() as bool)) {
    throw ArgumentError('missing fields');
  }

  // Protobuf in dart does not support 'unknownFields' method
  // if (!msg.unknownFields.isEmpty) {
  //   throw ArgumentError('has extra fields');
  // }

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

  List<pb.InitialCommitment> commitMessages = [];
  for (List<int> cblob in msg.initialCommitments) {
    pb.InitialCommitment cmsg =
        protoStrictParse(pb.InitialCommitment(), cblob) as pb.InitialCommitment;
    check(cmsg.saltedComponentHash.length == 32, "bad salted hash");
    List<int> P = cmsg.amountCommitment;
    check(P.length == 65 && P[0] == 4, "bad commitment point");
    check(
        cmsg.communicationKey.length == 33 &&
            (cmsg.communicationKey[0] == 2 || cmsg.communicationKey[0] == 3),
        "bad communication key");
    commitMessages.add(cmsg);
  }

  Uint8List HBytes =
      Uint8List.fromList([0x02] + 'CashFusion gives us fungibility.'.codeUnits);
  ECDomainParameters params = ECDomainParameters('secp256k1');
  ECPoint? HMaybe = params.curve.decodePoint(HBytes);
  if (HMaybe == null) {
    throw Exception('Failed to decode point');
  }
  ECPoint H = HMaybe;
  PedersenSetup setup = PedersenSetup(H);

  Commitment claimedCommit;
  Uint8List pointsum;
  // Verify pedersen commitment
  try {
    pointsum = Commitment.addPoints(commitMessages
        .map((m) => Uint8List.fromList(m.amountCommitment))
        .toList());
    claimedCommit = setup.commit(BigInt.from(msg.excessFee.toInt()),
        nonce: Utilities.bytesToBigInt(
            Uint8List.fromList(msg.pedersenTotalNonce)));

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

  // TODO type
  dynamic cmsg = protoStrictParse(pb.Component(), msg.component);
  check(cmsg.saltCommitment.length == 32, "bad salt commitment");

  String sortKey;

  if (cmsg.hasInput() as bool) {
    // TODO type
    dynamic inp = cmsg.input;
    check(inp.txid.length == 32, "bad txid");
    check(
        (inp.pubkey.length == 33 &&
                (inp.pubkey[0] == 2 || inp.pubkey[0] == 3)) ||
            (inp.pubkey.length == 65 && inp.pubkey[0] == 4),
        "bad pubkey");
    if (cmsg.saltCommitment is! Iterable<int>) {
      throw Exception(
          'cmsg.saltCommitment is not Iterable<int> in checkCovertComponent');
    }
    sortKey =
        'i${String.fromCharCodes(inp.txid.reversed as Iterable<int>)}${inp.index.toString()}${String.fromCharCodes(cmsg.saltCommitment as Iterable<int>)}';
  } else if (cmsg.hasOutput() as bool) {
    // TODO type
    dynamic out = cmsg.output;
    Address addr;
    // Basically just checks if its ok address. should throw error if not.
    addr = Utilities.getAddressFromOutputScript(out.scriptpubkey as Uint8List);

    check(
        (out.amount >= Utilities.dustLimit(out.scriptpubkey.length as int)
            as bool),
        "dust output");
    sortKey =
        'o${out.amount.toString()}${String.fromCharCodes(out.scriptpubkey as Iterable<int>)}${String.fromCharCodes(cmsg.saltCommitment as Iterable<int>)}';
  } else if (cmsg.hasBlank() as bool) {
    sortKey = 'b${String.fromCharCodes(cmsg.saltCommitment as Iterable<int>)}';
  } else {
    throw ValidationError('missing component details');
  }

  return (sortKey, componentContrib(cmsg as pb.Component, componentFeerate));
}

pb.InputComponent? validateProofInternal(
  Uint8List proofBlob,
  pb.InitialCommitment commitment,
  List<Uint8List> allComponents,
  List<int> badComponents,
  int componentFeerate,
) {
  Uint8List HBytes =
      Uint8List.fromList([0x02] + 'CashFusion gives us fungibility.'.codeUnits);
  ECDomainParameters params = ECDomainParameters('secp256k1');
  ECPoint? HMaybe = params.curve.decodePoint(HBytes);
  if (HMaybe == null) {
    throw Exception('Failed to decode point');
  }
  ECPoint H = HMaybe;
  PedersenSetup setup = PedersenSetup(H);

  // TODO type
  dynamic msg = protoStrictParse(pb.Proof(), proofBlob);

  Uint8List componentBlob;
  try {
    componentBlob = allComponents[msg.componentIdx as int];
  } catch (e) {
    throw ValidationError("component index out of range");
  }

  check(!badComponents.contains(msg.componentIdx), "component in bad list");

  Component comp = pb.Component();
  comp.mergeFromBuffer(componentBlob);
  assert(comp.isInitialized());

  check(msg.salt.length == 32, "salt wrong length");
  check(
    Utilities.sha256(msg.salt as Uint8List) == comp.saltCommitment,
    "salt commitment mismatch",
  );

  // TODO validate
  Iterable<int> iterableSalt = msg.salt as Iterable<int>;
  check(
    Utilities.sha256(Uint8List.fromList([...iterableSalt, ...componentBlob])) ==
        commitment.saltedComponentHash,
    "salted component hash mismatch",
  );

  int contrib = componentContrib(comp, componentFeerate);

  List<int> PCommitted = commitment.amountCommitment;

  Commitment claimedCommit = setup.commit(
    BigInt.from(contrib),
    nonce: Utilities.bytesToBigInt(msg.pedersenNonce as Uint8List),
  );

  check(
    Uint8List.fromList(PCommitted) == claimedCommit.pointPUncompressed,
    "pedersen commitment mismatch",
  );

  if (comp.hasInput()) {
    return comp.input;
  } else {
    return null;
  }
}

// TODO type
Future<dynamic> validateBlame(
  pb.Blames_BlameProof blame,
  Uint8List encProof,
  Uint8List srcCommitBlob,
  Uint8List destCommitBlob,
  List<Uint8List> allComponents,
  List<int> badComponents,
  int componentFeerate,
) async {
  InitialCommitment destCommit = pb.InitialCommitment();
  destCommit.mergeFromBuffer(destCommitBlob);
  List<int> destPubkey = destCommit.communicationKey;

  InitialCommitment srcCommit = pb.InitialCommitment();
  srcCommit.mergeFromBuffer(srcCommitBlob);

  Blames_BlameProof_Decrypter decrypter = blame.whichDecrypter();
  ECDomainParameters params = ECDomainParameters('secp256k1');
  if (decrypter == pb.Blames_BlameProof_Decrypter.privkey) {
    Uint8List privkey = Uint8List.fromList(blame.privkey);
    check(privkey.length == 32, 'bad blame privkey');
    String privkeyHexStr =
        Utilities.bytesToHex(privkey); // Convert bytes to hex string.
    BigInt privkeyBigInt =
        BigInt.parse(privkeyHexStr, radix: 16); // Convert hex string to BigInt.
    ECPrivateKey privateKey =
        ECPrivateKey(privkeyBigInt, params); // Create ECPrivateKey
    List<String> pubkeys = Utilities.pubkeysFromPrivkey(privkeyHexStr);
    check(destCommit.communicationKey == pubkeys[1], 'bad blame privkey');
    try {
      Encrypt.decrypt(encProof, privateKey);
    } catch (e) {
      return 'undecryptable';
    }
    throw ValidationError('blame gave privkey but decryption worked');
  } else if (decrypter != pb.Blames_BlameProof_Decrypter.sessionKey) {
    throw ValidationError('unknown blame decrypter');
  }
  Uint8List key = Uint8List.fromList(blame.sessionKey);
  check(key.length == 32, 'bad blame session key');
  Uint8List proofBlob;
  try {
    proofBlob = await Encrypt.decryptWithSymmkey(encProof, key);
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
    return e.toString();
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

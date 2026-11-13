import 'package:fusiondart/src/protobuf/fusion.pb.dart';
import 'package:test/test.dart';

void main() {
  test('all generated createRepeated APIs remain usable', () {
    final factories = <dynamic Function()>[
      InputComponent.createRepeated,
      OutputComponent.createRepeated,
      BlankComponent.createRepeated,
      Component.createRepeated,
      InitialCommitment.createRepeated,
      Proof.createRepeated,
      ClientHello.createRepeated,
      ServerHello.createRepeated,
      JoinPools_PoolTag.createRepeated,
      JoinPools.createRepeated,
      TierStatusUpdate_TierStatus.createRepeated,
      TierStatusUpdate.createRepeated,
      FusionBegin.createRepeated,
      StartRound.createRepeated,
      PlayerCommit.createRepeated,
      BlindSigResponses.createRepeated,
      AllCommitments.createRepeated,
      CovertComponent.createRepeated,
      ShareCovertComponents.createRepeated,
      CovertTransactionSignature.createRepeated,
      FusionResult.createRepeated,
      MyProofsList.createRepeated,
      TheirProofsList_RelayedProof.createRepeated,
      TheirProofsList.createRepeated,
      Blames_BlameProof.createRepeated,
      Blames.createRepeated,
      RestartRound.createRepeated,
      Error.createRepeated,
      Ping.createRepeated,
      OK.createRepeated,
      ClientMessage.createRepeated,
      ServerMessage.createRepeated,
      CovertMessage.createRepeated,
      CovertResponse.createRepeated,
    ];

    for (final createRepeated in factories) {
      expect(createRepeated(), isEmpty);
    }

    final inputs = InputComponent.createRepeated()..add(InputComponent());
    expect(inputs, hasLength(1));
  });
}

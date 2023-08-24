import 'package:fusiondart/src/fusion.pb.dart';
import 'package:fusiondart/src/models/address.dart';

class Output {
  int value;
  Address addr;

  int amount = 0;

  Output({required this.value, required this.addr});

  int sizeOfOutput() {
    List<int> scriptpubkey = addr
        .toScript(); // assuming addr.toScript() returns List<int> that represents the scriptpubkey
    assert(scriptpubkey.length < 253);
    return 9 + scriptpubkey.length;
  }

  static Output fromOutputComponent(OutputComponent outputComponent) {
    Address address = Address.fromScriptPubKey(outputComponent.scriptpubkey);
    return Output(
      value: outputComponent.amount.toInt(),
      addr: address,
    );
  }
}

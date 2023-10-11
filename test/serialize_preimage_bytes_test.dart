import 'package:bitbox/bitbox.dart' as bitbox;
import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:fusiondart/fusiondart.dart';
import 'package:fusiondart/src/extensions/on_string.dart';
import 'package:fusiondart/src/extensions/on_uint8list.dart';
import 'package:test/test.dart';

void main() {
  test('Test Known Signature Bytes', () async {
    await coinlib.loadCoinlib();

    final input = bitbox.Input(
      hash: '4d9d20abe5faeccd4a027284333df4ccd35f86f2f07ed14b626a8bc8a505ed1a'
          .toUint8ListFromHex,
      index: 0,
      sequence: 0xffffffff,
      pubkeys: [
        '02c649d809b4186de74342504705e1936e24cf7605d06ab43bc9fd3638be720d3a'
            .toUint8ListFromHex
      ],
      value: 40000,
    );

    // final Output output = Output(
    //     value: 0, // ???
    //     address: '1A1C5oYHaxmS7i2HExd9mvwrRsntynGue9');
    // python uses: `[(TYPE_SCRIPT, ScriptOutput(bytes([OpCodes.OP_RETURN, *prefix, 32]) + session_hash), 0)]`
    // // final List<int> prefix = [4, 70, 85, 90, 0];
    // final output = bitbox.Output(
    //   script: Uint8List.fromList(
    //       [0x6a, 4, 70, 85, 90, 0, 32, ...List.generate(32, (index) => 0)]),
    //       // [0x6a, ...prefix, 32, ...List.generate(32, (index) => 0)]),
    //   value: 0,w
    // );
    final output = Output.fromScriptPubKey(
      scriptPubkey: [
        0x6a,
        4,
        70,
        85,
        90,
        0,
        32,
        ...List.generate(32, (index) => 0)
      ],
      // [0x6a, ...prefix, 32, ...List.generate(32, (index) => 0)]),
      value: 0,
    );

    final tx = Transaction([input], []); // TODO add output.

    // Calculate sigHash for signing.
    final preimageBytes = tx.serializePreimageBytes(
      0,
      network: Utilities.mainNet,
      nHashType: 0x41,
      useCache: true,
    );
    final sigHash = Utilities.doubleSha256(preimageBytes);

    expect(
      sigHash.toHex,
      'd67d0b43caeba9e1bdb8560fdaf50c024c6de67d36532275307536f0b324827a',
    );
  });
}

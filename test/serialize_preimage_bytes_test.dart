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
      hash: 'c0305ddaa027ebabf217df7adfd79c79a8920dad9b0fd534446f545594c40c37'
          .toUint8ListFromHex,
      index: 32,
      sequence: 0xffffffff,
      pubkeys: [
        '025ba567cfbe18be15445520696ba05320feb5607e00089e75511c323fa4e9dff6'
            .toUint8ListFromHex
      ],
      value: 1740046,
    );

    final Output output = Output(
        value: 0, // ???
        address:
            'qqpt9pqwvzqhlal4s2ere3n43k8ejedf65qrq4f4wr'); // or bitcoincash:qqpt9pqwvzqhlal4s2ere3n43k8ejedf65qrq4f4wr
    // python uses: `[(TYPE_SCRIPT, ScriptOutput(bytes([OpCodes.OP_RETURN, *prefix, 32]) + session_hash), 0)]`
    // // final List<int> prefix = [4, 70, 85, 90, 0];
    // final output = bitbox.Output(
    //   script: Uint8List.fromList(
    //       [0x6a, 4, 70, 85, 90, 0, 32, ...List.generate(32, (index) => 0)]),
    //       // [0x6a, ...prefix, 32, ...List.generate(32, (index) => 0)]),
    //   value: 0,
    // );

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
      'ba41eaaa11ab0f1d40ffeef4d3c35559a4e9aed53011a0a4e05700287857eb60',
    );
  });
}

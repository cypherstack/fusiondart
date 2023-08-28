import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:fusiondart/src/util.dart';
import 'package:pointycastle/pointycastle.dart' hide Mac;

// Global constants for elliptic curve parameters
final ECDomainParameters params = ECDomainParameters('secp256k1');
final BigInt order = params.n;

/// Custom exception class for encryption failures.
class EncryptionFailed implements Exception {}

/// Custom exception class for decryption failures.
class DecryptionFailed implements Exception {}

/// Encrypts a message using a provided EC public key.
///
/// Parameters:
/// - [message]: The message to encrypt as a Uint8List.
/// - [pubkey]: The EC public key to encrypt with.
/// - [padToLength] (optional): Optional padding for encrypted message.
///
/// Returns:
///   A Future that resolves to the encrypted message as a Uint8List.
///
/// Throws:
/// - EncryptionFailed: if the encryption fails for any reason.
Future<Uint8List> encrypt(Uint8List message, ECPoint pubKey,
    {int? padToLength}) async {
  // Initialize public point from the public key
  ECPoint pubPoint;
  try {
    pubPoint = Utilities.serToPoint(pubKey.getEncoded(true), params);
  } catch (_) {
    throw EncryptionFailed(); // If serialization to point fails, throw encryption failed exception.
  }

  // Generate secure random nonce.
  BigInt nonceSec = Utilities.secureRandomBigInt(params.n.bitLength);

  // Calculate G * nonceSec
  ECPoint? GTimesNonceSec = params.G * nonceSec;
  if (GTimesNonceSec == null) {
    throw Exception('Multiplication of G with nonceSec resulted in null');
  }

  // Serialize G_times_nonceSec to bytes
  Uint8List noncePub = Utilities.pointToSer(GTimesNonceSec, true);

  // Calculate public point * nonceSec
  ECPoint? pubPointTimesNonceSec = pubPoint * nonceSec;
  if (pubPointTimesNonceSec == null) {
    throw Exception(
        'Multiplication of pubPoint with nonceSec resulted in null');
  }

  // Create a SHA-256 hash as the symmetric key.
  List<int> key = crypto.sha256
      .convert(Utilities.pointToSer(pubPointTimesNonceSec, true))
      .bytes;

  // Prepare plaintext with message length prepended.
  Uint8List plaintext = Uint8List(4 + message.length)
    ..buffer.asByteData().setUint32(0, message.length, Endian.big)
    ..setRange(4, 4 + message.length, message);

  // Handle padding for AES encryption.
  if (padToLength == null) {
    padToLength = ((plaintext.length + 15) ~/ 16) *
        16; // Round up to nearest 16 bytes for AES block size.
  } else if (padToLength % 16 != 0) {
    throw ArgumentError('$padToLength not multiple of 16');
  }
  if (padToLength < plaintext.length) {
    throw ArgumentError('$padToLength < ${plaintext.length}');
  }

  // Actual padding.
  plaintext = Uint8List(padToLength)
    ..setRange(0, message.length + 4, plaintext);

  // Initialize secret key, MAC algorithm, and cipher.
  final secretKey = SecretKey(key);
  final macAlgorithm = Hmac(Sha256());
  final cipher = AesCbc.with128bits(macAlgorithm: macAlgorithm);

  // Generate a random nonce.
  final nonce = Uint8List(16);

  // Perform AES encryption.
  final secretBox =
      await cipher.encrypt(plaintext, secretKey: secretKey, nonce: nonce);

  // Prepare final ciphertext.
  final ciphertext = secretBox.cipherText;

  // Combine nonce, ciphertext, and MAC to create the final encrypted message.
  return Uint8List(
      noncePub.length + ciphertext.length + secretBox.mac.bytes.length)
    ..setRange(0, noncePub.length, noncePub)
    ..setRange(noncePub.length, noncePub.length + ciphertext.length, ciphertext)
    ..setRange(
        noncePub.length + ciphertext.length,
        noncePub.length + ciphertext.length + secretBox.mac.bytes.length,
        secretBox.mac.bytes);
}

/// Decrypts data using a symmetric key.
///
/// Parameters:
/// - [data]: The encrypted data as a Uint8List.
/// - [key]: The symmetric key as a Uint8List.
///
/// Returns:
///   A Future that resolves to the decrypted message as a Uint8List.
///
/// Throws:
/// - DecryptionFailed: if the decryption fails for any reason.
Future<Uint8List> decryptWithSymmkey(Uint8List data, Uint8List key) async {
  // Check if the incoming data has a minimum length to contain all the elements.
  if (data.length < 33 + 16 + 16) {
    throw DecryptionFailed();
  }

  // Extract the actual ciphertext from the data (skipping nonce and MAC).
  Uint8List ciphertext = data.sublist(33, data.length - 16);

  // Check if the ciphertext's length is a multiple of the AES block size.
  if (ciphertext.length % 16 != 0) {
    throw DecryptionFailed();
  }

  // Initialize the secret key and cipher.
  final secretKey = SecretKey(key);
  final cipher = AesCbc.with128bits(macAlgorithm: Hmac.sha256());

  // Create a random nonce.
  final nonce = Uint8List(16);

  // Initialize the SecretBox with the ciphertext, MAC and nonce.
  final secretBox = SecretBox(ciphertext,
      mac: Mac(data.sublist(data.length - 16)), nonce: nonce);

  // Perform the decryption.
  final plaintext = await cipher.decrypt(secretBox, secretKey: secretKey);

  // Check if the decrypted plaintext has at least 4 bytes (for the length field).
  if (plaintext.length < 4) {
    throw DecryptionFailed();
  }

  // Convert plaintext to ByteData to read the length field.
  Uint8List uint8list = Uint8List.fromList(plaintext);
  ByteData byteData = ByteData.sublistView(uint8list);
  int msgLength = byteData.getUint32(0, Endian.big);

  // Check if the length field in the decrypted message matches the actual message length.
  if (msgLength + 4 > plaintext.length) {
    throw DecryptionFailed();
  }

  // Extract and return the actual message from the decrypted plaintext.
  return Uint8List.fromList(plaintext.sublist(4, 4 + msgLength));
}

/// Decrypts an encrypted message using a provided EC private key.
///
/// Parameters:
/// - [data]: The encrypted data as a Uint8List.
/// - [privkey]: The EC private key to decrypt with.
///
/// Returns:
///   A Future that resolves to a tuple containing the decrypted message and the symmetric key used for decryption, both as Uint8Lists.
///
/// Throws:
/// - DecryptionFailed: if the decryption fails for any reason.
/// - Exception: if the private key or nonce point is null.
Future<(Uint8List, Uint8List)> decrypt(
    Uint8List data, ECPrivateKey privkey) async {
  // Ensure the encrypted data is of the minimum required length.
  if (data.length < 33 + 16 + 16) {
    throw DecryptionFailed();
  }
  // Extract the public part of the nonce from the incoming data.
  Uint8List noncePub = data.sublist(0, 33);
  ECPoint noncePoint;

  // Attempt to deserialize the nonce point.
  try {
    noncePoint = Utilities.serToPoint(noncePub, params);
  } catch (_) {
    throw DecryptionFailed();
  }

  // TODO double check if this is correct according to the Python in Electron-Cash

  // Initialize the EC parameters.
  ECPoint G = params.G;
  final List<int> key;

  // Ensure the private key exists and is valid.
  if (privkey.d != null) {
    // Compute the point that will be used for generating the symmetric key.
    // This is done by multiplying the base point G with the private key (d) and adding the noncePoint.
    ECPoint? point = (G * privkey.d)! + noncePoint;

    // Generate the symmetric key using the SHA-256 hash of the computed point.
    key = crypto.sha256.convert(Utilities.pointToSer(point!, true)).bytes;
    // Use the symmetric key to decrypt the data.
    Uint8List decryptedData =
        await decryptWithSymmkey(data, Uint8List.fromList(key));

    // Return the decrypted data and the symmetric key used for decryption.
    return (decryptedData, Uint8List.fromList(key));
  } else {
    // Handle the situation where privkey.d or noncePoint is null.
    throw Exception("FIXME"); // TODO
  }
}

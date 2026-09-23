import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'token_store.dart';

/// Local unlock over the encrypted database. Entirely a client concern — the
/// server never sees it, and a token is needed only to talk.
class PinGate {
  PinGate(this._tokens);

  final TokenStore _tokens;

  Future<bool> get isSet async => (await _tokens.pinHash()) != null;

  Future<void> set(String pin) async {
    final salt = _salt();
    await _tokens.savePinHash('$salt:${_hash(pin, salt)}');
  }

  Future<bool> verify(String pin) async {
    final stored = await _tokens.pinHash();
    if (stored == null) return true;
    final parts = stored.split(':');
    if (parts.length != 2) return false;
    return _hash(pin, parts.first) == parts.last;
  }

  Future<void> clear() => _tokens.clearPin();

  static String _salt() {
    final rng = Random.secure();
    return base64Url.encode(List<int>.generate(12, (_) => rng.nextInt(256)));
  }

  static String _hash(String pin, String salt) {
    // A four-digit PIN has no entropy worth defending with a slow KDF; the
    // real protection is the SQLCipher key in platform secure storage.
    return sha256.convert(utf8.encode('$salt|$pin')).toString();
  }
}

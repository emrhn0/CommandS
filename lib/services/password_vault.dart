import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:win32/win32.dart';

const _cryptProtectUiForbidden = 0x1;

/// Keeps the one key that remembered passwords are encrypted with, where only
/// this user of this machine can read it.
abstract class KeyStore {
  /// The key, or null when none has been made yet. Throws if the store cannot
  /// be read at all, which is not the same as being empty.
  Future<Uint8List?> read();
  Future<void> write(Uint8List key);
}

/// For tests, which must never touch the real key of whoever runs them.
class MemoryKeyStore implements KeyStore {
  Uint8List? key;

  @override
  Future<Uint8List?> read() async => key;

  @override
  Future<void> write(Uint8List value) async => key = value;
}

/// Windows: a file in the app's roaming folder, encrypted with DPAPI, so it
/// opens only for the same Windows account.
class DpapiKeyStore implements KeyStore {
  DpapiKeyStore({String? path}) : _path = path ?? '${Platform.environment['APPDATA']}\\CommandS\\password.key';
  final String _path;

  @override
  Future<Uint8List?> read() async {
    final file = File(_path);
    if (!await file.exists()) return null;
    return _transform(await file.readAsBytes(), protect: false);
  }

  @override
  Future<void> write(Uint8List key) async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_transform(key, protect: true), flush: true);
  }

  static Uint8List _transform(Uint8List input, {required bool protect}) {
    final inBuffer = calloc<Uint8>(input.length);
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    try {
      inBuffer.asTypedList(input.length).setAll(0, input);
      inBlob.ref
        ..cbData = input.length
        ..pbData = inBuffer;
      final ok = protect
          ? CryptProtectData(inBlob, nullptr, nullptr, nullptr, nullptr, _cryptProtectUiForbidden, outBlob)
          : CryptUnprotectData(inBlob, nullptr, nullptr, nullptr, nullptr, _cryptProtectUiForbidden, outBlob);
      if (ok == 0) throw StateError('DPAPI failed (${GetLastError()})');
      final out = Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      LocalFree(outBlob.ref.pbData);
      return out;
    } finally {
      calloc.free(inBuffer);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}

/// macOS: the login keychain, through `security`. The key goes in on stdin, as
/// a command line can be read by other processes.
class KeychainKeyStore implements KeyStore {
  static const _service = 'CommandS';
  static const _account = 'password-key';

  @override
  Future<Uint8List?> read() async {
    final r = await Process.run('/usr/bin/security', ['find-generic-password', '-s', _service, '-a', _account, '-w']);
    // 44: errSecItemNotFound, nothing saved yet. Anything else is a failure.
    if (r.exitCode == 44) return null;
    if (r.exitCode != 0) throw StateError('Keychain read failed (${r.exitCode})');
    return base64Decode((r.stdout as String).trim());
  }

  @override
  Future<void> write(Uint8List key) async {
    final p = await Process.start('/usr/bin/security', ['-i']);
    p.stdin.writeln('add-generic-password -U -s $_service -a $_account -w ${base64Encode(key)}');
    await p.stdin.close();
    final drain = Future.wait([p.stdout.drain<void>(), p.stderr.drain<void>()]);
    final code = await p.exitCode;
    await drain;
    if (code != 0) throw StateError('Keychain write failed ($code)');
  }
}

/// Encrypts remembered passwords with AES-256-GCM. Each is bound to its
/// connection's id, so a saved value cannot be moved onto another connection.
class PasswordVault {
  PasswordVault(this._store);

  /// Replaces the platform's store. Under `flutter test` the default is an
  /// in-memory one, so a test run can never reach the real key.
  @visibleForTesting
  static KeyStore? storeOverride;

  static KeyStore platformStore() {
    if (storeOverride != null) return storeOverride!;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return storeOverride = MemoryKeyStore();
    return Platform.isMacOS ? KeychainKeyStore() : DpapiKeyStore();
  }

  final KeyStore _store;
  Uint8List? _key;

  static const _prefix = 'v1:';
  static const _nonceLength = 12;
  static final _random = Random.secure();

  static Uint8List _randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  Future<Uint8List> _ensureKey({required bool create}) async {
    final known = _key ?? await _store.read();
    if (known != null) {
      if (known.length != 32) throw StateError('Stored key has the wrong length');
      return _key = known;
    }
    if (!create) throw StateError('No key to decrypt with');
    final fresh = _randomBytes(32);
    await _store.write(fresh);
    // Read it back: a key that was not really kept would lose every password.
    final back = await _store.read();
    if (back == null || !listEquals(back, fresh)) throw StateError('Key did not survive being stored');
    return _key = fresh;
  }

  static Uint8List _run(bool encrypt, Uint8List key, Uint8List nonce, String id, Uint8List input) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, Uint8List.fromList(utf8.encode(id))));
    return cipher.process(input);
  }

  Future<String> encrypt(String password, String id) async {
    final key = await _ensureKey(create: true);
    final nonce = _randomBytes(_nonceLength);
    final sealed = _run(true, key, nonce, id, Uint8List.fromList(utf8.encode(password)));
    return _prefix + base64Encode([...nonce, ...sealed]);
  }

  /// Throws if the key is gone or the value was changed.
  Future<String> decrypt(String stored, String id) async {
    if (!stored.startsWith(_prefix)) throw const FormatException('Unknown format');
    final key = await _ensureKey(create: false);
    final raw = base64Decode(stored.substring(_prefix.length));
    final nonce = Uint8List.sublistView(raw, 0, _nonceLength);
    final sealed = Uint8List.sublistView(raw, _nonceLength);
    return utf8.decode(_run(false, key, nonce, id, sealed));
  }
}

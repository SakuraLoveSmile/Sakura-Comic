import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:comic_app/src/auth_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.sakurasep.comic/auth_store');
  const store = KeystoreSecretStore();

  group('KeystoreSecretStore platform channel integration', () {
    test('save succeeds when channel returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'save') return true;
        return null;
      });

      await expectLater(store.save('ref-1', 'secret-1'), completes);
    });

    test('save throws KeystoreException when channel returns false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'save') return false;
        return null;
      });

      expect(
        () => store.save('ref-1', 'secret-1'),
        throwsA(isA<KeystoreException>().having(
          (e) => e.code,
          'code',
          'SAVE_FAILED',
        )),
      );
    });

    test('save maps PlatformException to KeystoreException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'KEYSTORE_UNAVAILABLE',
          message: 'Keystore master key is unavailable',
        );
      });

      expect(
        () => store.save('ref-1', 'secret-1'),
        throwsA(isA<KeystoreException>().having(
          (e) => e.code,
          'code',
          'KEYSTORE_UNAVAILABLE',
        )),
      );
    });

    test('read returns string on success', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') return 'decrypted-value';
        return null;
      });

      final result = await store.read('ref-1');
      expect(result, 'decrypted-value');
    });

    test('read returns null when absent', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') return null;
        return null;
      });

      final result = await store.read('ref-1');
      expect(result, isNull);
    });

    test('read maps PlatformException to KeystoreException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'DECRYPTION_FAILED',
          message: 'Failed to decrypt secret',
        );
      });

      expect(
        () => store.read('ref-1'),
        throwsA(isA<KeystoreException>().having(
          (e) => e.code,
          'code',
          'DECRYPTION_FAILED',
        )),
      );
    });

    test('delete succeeds when channel returns true', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'delete') return true;
        return null;
      });

      await expectLater(store.delete('ref-1'), completes);
    });

    test('delete throws KeystoreException when channel returns false',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'delete') return false;
        return null;
      });

      expect(
        () => store.delete('ref-1'),
        throwsA(isA<KeystoreException>().having(
          (e) => e.code,
          'code',
          'DELETE_FAILED',
        )),
      );
    });

    test('delete maps PlatformException to KeystoreException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'STORAGE_ERROR',
          message: 'Failed to delete ref',
        );
      });

      expect(
        () => store.delete('ref-1'),
        throwsA(isA<KeystoreException>().having(
          (e) => e.code,
          'code',
          'STORAGE_ERROR',
        )),
      );
    });
  });
}

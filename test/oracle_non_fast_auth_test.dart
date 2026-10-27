/// Wire-shape unit tests for the non-fast-auth (pre-23ai) handshake builders
/// added for Oracle 11g/12c/19c listeners that do not advertise FAST_AUTH.
/// These run without a database — they assert the standalone PROTOCOL /
/// DATA-TYPES / AUTH message layout and the token-field toggle.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_db_server/oracle_native_handshake.dart';
import 'package:test/test.dart';

void main() {
  group('non-fast-auth handshake builders', () {
    test('buildProtocolMessage is a standalone type-1 PROTOCOL message', () {
      final msg = buildProtocolMessage();
      expect(msg[0], ttcMsgTypeProtocol); // 1
      expect(msg[1], ttcProtocolVersion); // 6
      expect(msg[2], 0);
      // Driver name, null-terminated, follows.
      final driver = utf8.encode(clientDriverName);
      expect(
          msg.sublist(3, 3 + driver.length), orderedEquals(driver));
      expect(msg[3 + driver.length], 0);
      // No bundled DATA-TYPES / charset fields trail a standalone PROTOCOL.
      expect(msg.length, 3 + driver.length + 1);
    });

    test('buildDataTypesMessage is a standalone type-2 message with charset',
        () {
      final msg = buildDataTypesMessage();
      expect(msg[0], ttcMsgTypeDataTypes); // 2
      // Charset id 873 (AL32UTF8) written little-endian, twice.
      expect(msg[1] | (msg[2] << 8), ttcCharsetUtf8);
      expect(msg[3] | (msg[4] << 8), ttcCharsetUtf8);
    });

    test('buildAuthPhaseOneMessage is a type-3 function 0x76 message', () {
      final msg = buildAuthPhaseOneMessage(username: 'scott');
      expect(msg[0], ttcMsgTypeFunction); // 3
      expect(msg[1], ttcAuthPhaseOne); // 0x76
      expect(msg[2], 1); // sequence
    });

    test('includeToken toggles the 23ai fast-auth token field', () {
      const common = {
        'username': 'scott',
        'sessionKeyHex': '00',
        'authPasswordHex': '00',
        'alterSession': 'X\u0000',
      };
      final withToken = buildAuthPhaseTwoMessage(
        username: common['username']!,
        sessionKeyHex: common['sessionKeyHex']!,
        authPasswordHex: common['authPasswordHex']!,
        alterSession: common['alterSession']!,
        includeToken: true,
      );
      final withoutToken = buildAuthPhaseTwoMessage(
        username: common['username']!,
        sessionKeyHex: common['sessionKeyHex']!,
        authPasswordHex: common['authPasswordHex']!,
        alterSession: common['alterSession']!,
        includeToken: false,
      );
      // Both are type-3 / func 0x73.
      expect(withToken[0], ttcMsgTypeFunction);
      expect(withToken[1], ttcAuthPhaseTwo); // 0x73
      expect(withoutToken[1], ttcAuthPhaseTwo);
      // The token (UB8 0) adds exactly one byte right after the 3-byte header.
      expect(withToken.length, withoutToken.length + 1);
      expect(withToken[3], 0); // token byte
    });

    test('parseAuthChallenge returns null when no AUTH message is present', () {
      expect(parseAuthChallenge(Uint8List.fromList([1, 2, 3, 4])), isNull);
      // A lone type-8 byte without the required keys is not a challenge.
      expect(parseAuthChallenge(Uint8List.fromList([8, 0, 0])), isNull);
    });
  });
}

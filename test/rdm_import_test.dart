import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:commands/models/models.dart';
import 'package:commands/services/rdm_import.dart';

// IPs below are from the RFC 5737 documentation ranges (192.0.2.0/24,
// 198.51.100.0/24) -- guaranteed never to be a real routable address.
const _sample = '''
{
  "Connections": [
    {
      "ConnectionType": 77,
      "Group": "EXAMPLE CORP",
      "ID": "01025a27-169d-4951-bca9-d4951e36c458",
      "Name": "PA_450 - 192.0.2.10",
      "Terminal": {
        "Host": "192.0.2.10",
        "HostPort": 22,
        "SafePassword": "I+6DbSxneX2mV51Cjt/BZw==",
        "Username": "admin_example"
      }
    },
    {
      "ConnectionType": 1,
      "Group": "SAMPLE BRANCH",
      "ID": "0191969a-02dc-45b5-9dd8-3518e92c303e",
      "Name": "DC2 - 198.51.100.20",
      "Url": "198.51.100.20",
      "RDP": {
        "Domain": "samplebranch",
        "SafePassword": "Z1K2pI4f43SBT6ZuAgEsKA==",
        "UserName": "svc-example"
      }
    },
    {
      "ConnectionType": 77,
      "Group": "SAMPLE BRANCH\\\\SWITCH's",
      "ID": "01b5c1ef-3c2d-474b-96fc-f7a9a992b78f",
      "Name": "SW_2 - 198.51.100.30",
      "Terminal": {
        "Host": "198.51.100.30",
        "HostPort": 22,
        "SafePassword": "Xowi1y0Jd+aRHWneNvhEZw==",
        "Username": "netadmin"
      }
    },
    {
      "ConnectionType": 25,
      "Group": "SAMPLE BRANCH\\\\SWITCH's",
      "ID": "023ec2a4-2dd8-4936-8d96-0716b322900b",
      "Name": "SWITCH's"
    },
    {
      "ConnectionType": 75,
      "ID": "3c12ba58-f194-4a27-adc6-840ca36abb48",
      "Name": "SERIAL CONNECTION",
      "Terminal": {
        "SerialLine": "/dev/tty.usbserial-120",
        "SerialSpeed": 15200
      }
    },
    {
      "AppVersion": "2026.2",
      "ConnectionType": 77,
      "Group": "OTHER SITE",
      "ID": "07925058-9326-4653-87d4-1c41ad046169",
      "Name": "PANORAMA - 192.0.2.50",
      "Terminal": {
        "Host": "192.0.2.50",
        "HostPort": 22,
        "Username": "admin_example"
      }
    }
  ],
  "DatabaseID": "00000000-0000-0000-0000-000000000000",
  "Version": 2
}
''';

void main() {
  test('looksLikeRdmExport detects the RDM schema', () {
    final doc = jsonDecode(_sample) as Map<String, dynamic>;
    expect(looksLikeRdmExport(doc), isTrue);
    expect(looksLikeRdmExport({'connections': []}), isFalse);
  });

  test('parseRdmExport imports SSH + RDP, skips folder markers and serial', () {
    final doc = jsonDecode(_sample) as Map<String, dynamic>;
    final result = parseRdmExport(doc);

    // 4 real connections (2 SSH incl. one nested-group, 1 RDP), skip the
    // type-25 folder marker and the type-75 serial connection.
    expect(result.connections.length, 4);
    expect(result.skippedUnsupported, 2);

    final ssh = result.connections.where((c) => c.protocol == ConnectionProtocol.ssh).toList();
    final rdp = result.connections.where((c) => c.protocol == ConnectionProtocol.rdp).toList();
    expect(ssh.length, 3);
    expect(rdp.length, 1);

    final dc2 = rdp.single;
    expect(dc2.host, '198.51.100.20');
    expect(dc2.port, 3389);
    expect(dc2.username, 'svc-example');
    expect(dc2.domain, 'samplebranch');

    // EXAMPLE CORP, SAMPLE BRANCH, SAMPLE BRANCH\SWITCH's, OTHER SITE.
    expect(result.folders.length, 4);
  });

  test('nested "Group" paths become chained parent/child folders', () {
    final doc = jsonDecode(_sample) as Map<String, dynamic>;
    final result = parseRdmExport(doc);

    final byName = {for (final f in result.folders) f.name: f};
    expect(byName.containsKey('SAMPLE BRANCH'), isTrue);
    expect(byName.containsKey("SWITCH's"), isTrue);
    final switches = byName["SWITCH's"]!;
    final parent = byName['SAMPLE BRANCH']!;
    expect(switches.parentId, parent.id);
    expect(parent.parentId, isNull);
  });

  test("passwords are never imported (RDM's AES blob can't be decrypted here)", () {
    final doc = jsonDecode(_sample) as Map<String, dynamic>;
    final result = parseRdmExport(doc);
    expect(result.connections.every((c) => c.password.isEmpty), isTrue);
    // 3 of the 4 imported entries had a SafePassword in the source.
    expect(result.passwordsNotImported, 3);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/models/models.dart';

// IPs and credentials below are entirely made up for the test -- the IPs
// are from the RFC 5737 documentation ranges (192.0.2.0/24, 198.51.100.0/24),
// guaranteed never to be a real routable address.
void main() {
  final svc = StorageService();

  test('RDM CSV export (comma, Group path, CredentialUserName/Password)', () {
    const csv = 'ConnectionType,ConnectionSubType,SubMode,Name,Group,Description,Keywords,Expiration,Parent,OTPSecret,'
        'Host,Port,CredentialUserName,CredentialDomain,CredentialPassword,OpenInConsole,WebUrl\n'
        'SSH terminali,,0,SW1 - 192.0.2.11,EXAMPLE GROUP,,,,,,192.0.2.11,22,admin,,ExamplePass1,,rdm://x\n'
        'Klasör,,0,EXAMPLE GROUP,EXAMPLE GROUP,,,,,,,,,,,,\n'
        'RDP (Microsoft Uzak Masaüstü),,0,BACKUP - 192.0.2.12,EXAMPLE GROUP,,,,,,192.0.2.12,3389,backup_svc,EXAMPLEDOM,ExamplePass2,Hayır,rdm://x\n'
        'SSH terminali,,0,SW2 - 198.51.100.11,SAMPLE CO\\Switches,,,,,,198.51.100.11,22,swadmin,,ExamplePass3,,rdm://x\n';
    final parsed = svc.parseCsv(csv);
    expect(parsed.connections.length, 3);

    final sw1 = parsed.connections.firstWhere((c) => c.name.contains('SW1'));
    expect(sw1.host, '192.0.2.11');
    expect(sw1.username, 'admin');
    expect(sw1.password, 'ExamplePass1');
    expect(sw1.protocol, ConnectionProtocol.ssh);
    final groupFolder = parsed.folders.firstWhere((f) => f.id == sw1.folderId);
    expect(groupFolder.name, 'EXAMPLE GROUP');

    final backup = parsed.connections.firstWhere((c) => c.name.contains('BACKUP'));
    expect(backup.protocol, ConnectionProtocol.rdp);
    expect(backup.domain, 'EXAMPLEDOM');
    expect(backup.password, 'ExamplePass2');

    final sw2 = parsed.connections.firstWhere((c) => c.name.contains('SW2'));
    final switches = parsed.folders.firstWhere((f) => f.id == sw2.folderId);
    expect(switches.name, 'Switches');
    final sampleCo = parsed.folders.firstWhere((f) => f.id == switches.parentId);
    expect(sampleCo.name, 'SAMPLE CO');
  });

  test('mRemoteNG CSV export (semicolon, GUID Id/Parent hierarchy)', () {
    const csv = 'Name;Id;Parent;NodeType;Description;Icon;Panel;Username;Password;Domain;Hostname;VmId;Protocol;'
        'PuttySession;Port;ConnectToConsole\n'
        'PA_SITE - 192.0.2.20;e1f3298d-3253-4782-a2cc-c27c6d0a58a2;13d71f7f-357b-4b56-ba22-1c7d9bc4098f;'
        'Connection;;SSH;General;svc_example;ExamplePass4;;192.0.2.20;;SSH2;Default Settings;22;False\n'
        'BACKUP - 192.0.2.21;93b4ccdd-27a7-4293-87db-2711c5aeb7b5;13d71f7f-357b-4b56-ba22-1c7d9bc4098f;'
        'Connection;;Remote Desktop;General;Administrator;ExamplePass5;;192.0.2.21;;RDP;Default Settings;3389;False\n'
        'SAMPLE SITE;13d71f7f-357b-4b56-ba22-1c7d9bc4098f;522aa7a7-e4b8-4cf5-a2d1-3595254b6bed;Container;;mRemoteNG;General;;;;;'
        ';RDP;Default Settings;3389;False\n';
    final parsed = svc.parseCsv(csv);
    expect(parsed.connections.length, 2);
    expect(parsed.folders.length, 1);
    expect(parsed.folders.single.name, 'SAMPLE SITE');
    expect(parsed.folders.single.parentId, null); // root GUID isn't a row -> top-level

    final pa = parsed.connections.firstWhere((c) => c.name.contains('PA_SITE'));
    expect(pa.host, '192.0.2.20');
    expect(pa.username, 'svc_example');
    expect(pa.password, 'ExamplePass4');
    expect(pa.protocol, ConnectionProtocol.ssh);
    expect(pa.folderId, parsed.folders.single.id);

    final backup = parsed.connections.firstWhere((c) => c.name.contains('BACKUP'));
    expect(backup.protocol, ConnectionProtocol.rdp);
    expect(backup.password, 'ExamplePass5');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/models/models.dart';

void main() {
  final svc = StorageService();

  test('csv roundtrip with folder path and password', () {
    final folders = [
      ConnectionFolder(id: 'p1', name: 'EXAMPLE CORP', parentId: null),
      ConnectionFolder(id: 'p2', name: 'Switches', parentId: 'p1'),
    ];
    final conns = [
      SavedConnection(
        id: 'c1', name: 'BB', host: '198.51.100.1', port: 22, username: 'admin',
        rememberPassword: true, password: 'ExamplePass1', folderId: 'p2',
        protocol: ConnectionProtocol.ssh, domain: null, rdpClipboard: true, rdpWallpaper: false,
      ),
    ];
    final csv = svc.exportCsv(folders: folders, connections: conns);
    final parsed = svc.parseCsv(csv);
    expect(parsed.connections.length, 1);
    expect(parsed.connections.first.password, 'ExamplePass1');
    expect(parsed.connections.first.host, '198.51.100.1');
    // folder path EXAMPLE CORP/Switches recreated as two nested folders
    expect(parsed.folders.length, 2);
    final leaf = parsed.folders.firstWhere((f) => f.name == 'Switches');
    final root = parsed.folders.firstWhere((f) => f.id == leaf.parentId);
    expect(root.name, 'EXAMPLE CORP');
  });

  test('csv import from a plain spreadsheet (no CommandS header)', () {
    const csv = 'Ad,Anamakine,Kullanıcı adı,Parola,Klasör\n'
        'HOST1,192.0.2.15,exampleadmin,ExamplePass2,EXAMPLE CORP\n';
    final parsed = svc.parseCsv(csv);
    expect(parsed.connections.length, 1);
    final c = parsed.connections.first;
    expect(c.host, '192.0.2.15');
    expect(c.username, 'exampleadmin');
    expect(c.password, 'ExamplePass2');
    expect(c.rememberPassword, true);
    expect(parsed.folders.single.name, 'EXAMPLE CORP');
  });

  test('csv without a host column throws a clear error', () {
    expect(() => svc.parseCsv('name,username\nfoo,bar\n'), throwsFormatException);
  });
}

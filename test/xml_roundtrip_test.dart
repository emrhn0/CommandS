import 'package:flutter_test/flutter_test.dart';
import 'package:commands/services/storage_service.dart';
import 'package:commands/models/models.dart';

void main() {
  test('xml roundtrip with special chars', () {
    final svc = StorageService();
    final folders = [ConnectionFolder(id: 'f1', name: 'Türkçe Klasör & Test', parentId: null)];
    final conns = [
      SavedConnection(
        id: 'c1', name: 'Şüphe "Test"', host: '10.0.0.1', port: 22, username: 'admin',
        rememberPassword: true, password: 'p@ss<w>ord&"\'', folderId: 'f1',
        protocol: ConnectionProtocol.ssh, domain: null, rdpClipboard: true, rdpWallpaper: false,
      ),
    ];
    final xml = svc.exportXml(folders: folders, connections: conns);
    // ignore: avoid_print
    print(xml);
    final parsed = svc.parseXml(xml);
    expect(parsed.folders.length, 1);
    expect(parsed.connections.length, 1);
    expect(parsed.connections.first.password, 'p@ss<w>ord&"\'');
    expect(parsed.connections.first.name, 'Şüphe "Test"');
  });
}

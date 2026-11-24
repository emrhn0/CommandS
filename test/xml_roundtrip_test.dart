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
        enablePassword: 'enable<&"',
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
    expect(parsed.connections.first.enablePassword, 'enable<&"');
    expect(parsed.connections.first.name, 'Şüphe "Test"');
  });

  test('xml keeps what json keeps: folder colour, device, profile, login answer, layouts', () {
    final svc = StorageService();
    final folders = [ConnectionFolder(id: 'f1', name: 'CUSTOMER-A', color: 0xFF3366CC)];
    final conns = [
      SavedConnection(
        id: 'c1', name: 'DEVICE-01', host: '192.0.2.10', folderId: 'f1',
        device: DeviceKind.cisco, deviceManual: true, credentialProfileId: 'p1', answerLoginQuestionYes: true,
      ),
    ];
    final layouts = [
      SavedLayout(id: 'l1', name: 'LAYOUT-1', folderId: 'f1', preset: 'custom', connectionIds: ['c1', null],
          shape: {'split': 'row', 'children': []}),
    ];
    final parsed = svc.parseXml(svc.exportXml(folders: folders, connections: conns, layouts: layouts));
    expect(parsed.folders.single.color, 0xFF3366CC);
    final c = parsed.connections.single;
    expect(c.device, DeviceKind.cisco);
    expect(c.deviceManual, isTrue);
    expect(c.credentialProfileId, 'p1');
    expect(c.answerLoginQuestionYes, isTrue);
    final l = parsed.layouts.single;
    expect(l.name, 'LAYOUT-1');
    expect(l.folderId, 'f1');
    expect(l.preset, 'custom');
    expect(l.connectionIds, ['c1', null]);
    expect(l.shape, {'split': 'row', 'children': []});
  });

  test('an xml layout that cannot be read is left out, the connections still come', () {
    const xml = '<CommandS version="1"><Connections>'
        '<Connection id="c1" name="DEVICE-01" host="192.0.2.10"/></Connections>'
        '<Layouts><Layout name="broken" connectionIds="not json"/></Layouts></CommandS>';
    final parsed = StorageService().parseXml(xml);
    expect(parsed.connections, hasLength(1));
    expect(parsed.layouts, isEmpty);
  });
}

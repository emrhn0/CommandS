import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum ConnectionProtocol { ssh, rdp }

/// What is at the other end of a connection, shown as its maker's logo in
/// the connection list. Learnt from what the device prints when a session
/// opens (see device_detect.dart), or picked by hand.
enum DeviceKind {
  linux('Linux'),
  vmware('VMware ESXi / vCenter'),
  windows('Windows'),
  paloalto('Palo Alto'),
  fortinet('Fortinet'),
  cisco('Cisco'),
  aruba('Aruba'),
  huawei('Huawei');

  const DeviceKind(this.label);
  final String label;

  static DeviceKind? byName(String? name) {
    for (final k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

class ConnectionFolder {
  String id;
  String name;
  String? parentId;

  ConnectionFolder({String? id, required this.name, this.parentId})
      : id = id ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
      };

  factory ConnectionFolder.fromJson(Map<String, dynamic> json) => ConnectionFolder(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parentId'] as String?,
      );
}

class SavedConnection {
  String id;
  String name;
  String host;
  int port;
  String username;
  bool rememberPassword;
  String password;
  String? folderId;
  ConnectionProtocol protocol;
  String? domain; // RDP only
  bool rdpClipboard; // RDP only — redirect local clipboard to/from the session
  bool rdpWallpaper; // RDP only — show remote desktop wallpaper (off = faster)

  /// The kind of device, for its logo. Null until it is known.
  DeviceKind? device;

  /// [device] was picked by hand, so detection leaves it alone.
  bool deviceManual;

  SavedConnection({
    String? id,
    required this.name,
    required this.host,
    this.port = 22,
    this.username = '',
    this.rememberPassword = false,
    this.password = '',
    this.folderId,
    this.protocol = ConnectionProtocol.ssh,
    this.domain,
    this.rdpClipboard = true,
    this.rdpWallpaper = false,
    this.device,
    this.deviceManual = false,
  }) : id = id ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'rememberPassword': rememberPassword,
        'password': rememberPassword ? password : '',
        'folderId': folderId,
        'protocol': protocol.name,
        'domain': domain,
        'rdpClipboard': rdpClipboard,
        'rdpWallpaper': rdpWallpaper,
        if (device != null) 'device': device!.name,
        if (deviceManual) 'deviceManual': true,
      };

  factory SavedConnection.fromJson(Map<String, dynamic> json) => SavedConnection(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String? ?? '',
        rememberPassword: json['rememberPassword'] as bool? ?? false,
        password: json['password'] as String? ?? '',
        folderId: json['folderId'] as String?,
        protocol: ConnectionProtocol.values.firstWhere(
          (p) => p.name == (json['protocol'] as String? ?? 'ssh'),
          orElse: () => ConnectionProtocol.ssh,
        ),
        domain: json['domain'] as String?,
        rdpClipboard: json['rdpClipboard'] as bool? ?? true,
        rdpWallpaper: json['rdpWallpaper'] as bool? ?? false,
        device: DeviceKind.byName(json['device'] as String?),
        deviceManual: json['deviceManual'] as bool? ?? false,
      );

  String get label => '$name - $host';
}

/// A split-view arrangement saved into a folder together with the
/// connections in its panes, so opening it brings the same sessions back in
/// the same layout.
class SavedLayout {
  String id;
  String name;
  String? folderId;

  /// A `SplitPreset` name (see services/pane_layout.dart).
  String preset;

  /// One saved connection id per pane, in reading order; null for a pane
  /// that was empty or held a quick connection, which cannot be reopened.
  List<String?> connectionIds;

  SavedLayout({
    String? id,
    required this.name,
    this.folderId,
    required this.preset,
    required this.connectionIds,
  }) : id = id ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'folderId': folderId,
        'preset': preset,
        'connectionIds': connectionIds,
      };

  factory SavedLayout.fromJson(Map<String, dynamic> json) => SavedLayout(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Layout',
        folderId: json['folderId'] as String?,
        preset: json['preset'] as String? ?? 'sideBySide',
        connectionIds: [for (final e in (json['connectionIds'] as List? ?? const [])) e as String?],
      );
}

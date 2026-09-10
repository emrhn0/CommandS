import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum ConnectionProtocol { ssh, rdp }

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
      );

  String get label => '$name - $host';
}

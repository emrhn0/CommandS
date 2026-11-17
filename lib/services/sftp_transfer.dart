import 'sftp_client.dart';

/// A transfer entry lives for the lifetime of its SSH session, even when the
/// file browser is rebuilt or moved to its own window.
class SftpTransfer {
  SftpTransfer(
    this.name,
    this.direction, {
    this.status = 'Transferring',
    this.error,
    this.localPath,
    this.remotePath,
  });

  final String name;
  final String direction; // upload or download
  String status;
  String? error;
  final String? localPath;
  final String? remotePath;

  /// Live progress while transferring; not carried between windows.
  SftpProgress? progress;

  Map<String, dynamic> toJson() => {
    'name': name,
    'direction': direction,
    'status': status,
    if (error != null) 'error': error,
    if (localPath != null) 'localPath': localPath,
    if (remotePath != null) 'remotePath': remotePath,
  };

  factory SftpTransfer.fromJson(Map<String, dynamic> json) => SftpTransfer(
    json['name'] as String? ?? '',
    json['direction'] == 'download' ? 'download' : 'upload',
    status:
        const {
          'Completed',
          'Verified',
          'Failed',
          'Verification failed',
        }.contains(json['status'])
        ? json['status'] as String
        : 'Transferring',
    error: json['error'] as String?,
    localPath: json['localPath'] as String?,
    remotePath: json['remotePath'] as String?,
  );

  static List<SftpTransfer> decodeList(Object? raw) {
    if (raw is! List) return [];
    return [
      for (final entry in raw)
        if (entry is Map && entry['name'] is String)
          SftpTransfer.fromJson(Map<String, dynamic>.from(entry)),
    ];
  }

  static void restore(List<SftpTransfer> target, Object? raw) {
    final decoded = decodeList(raw);
    target
      ..clear()
      ..addAll(decoded);
  }
}

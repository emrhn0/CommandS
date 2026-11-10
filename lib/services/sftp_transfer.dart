/// A transfer entry lives for the lifetime of its SSH session, even when the
/// file browser is rebuilt or moved to its own window.
class SftpTransfer {
  SftpTransfer(
    this.name,
    this.direction, {
    this.status = 'Transferring',
    this.error,
  });

  final String name;
  final String direction; // upload or download
  String status;
  String? error;

  Map<String, dynamic> toJson() => {
    'name': name,
    'direction': direction,
    'status': status,
    if (error != null) 'error': error,
  };

  factory SftpTransfer.fromJson(Map<String, dynamic> json) => SftpTransfer(
    json['name'] as String? ?? '',
    json['direction'] == 'download' ? 'download' : 'upload',
    status: json['status'] == 'Completed' || json['status'] == 'Failed'
        ? json['status'] as String
        : 'Transferring',
    error: json['error'] as String?,
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

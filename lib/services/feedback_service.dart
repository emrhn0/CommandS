import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_version.dart';

/// Sends a message from Settings > Support & feedback.
///
/// It goes to a Google Form as an anonymous response: the form takes posts
/// without sign-in and keeps the responses (and mails a notice) for the
/// app's maintainer. Nothing here is a secret -- the form's id only lets
/// someone post to it, which is what it is for -- and nothing identifies
/// the sender: only the message, the app version and the operating system
/// are sent. No name, account, machine name or address.
class FeedbackService {
  static const _formResponseUrl =
      'https://docs.google.com/forms/d/e/1FAIpQLSdXdaUrkArIhWABJtwyP61VVhLpJVprvEvJ3jePPWEfrsDifA/formResponse';
  static const _messageField = 'entry.257997071';

  static const int maxLength = 4000;

  /// What is sent: the message, then version and OS on a line of their own.
  @visibleForTesting
  static String compose(String message) {
    final os = Platform.isWindows ? 'Windows' : (Platform.isMacOS ? 'macOS' : Platform.operatingSystem);
    return '${message.trim()}\n\n-- CommandS $appVersion, $os';
  }

  /// Replaced in tests, which must not post to the real form.
  @visibleForTesting
  static Future<bool> Function(String body)? debugSender;

  /// True when the form took it.
  static Future<bool> send(String message) async {
    final text = message.trim();
    if (text.isEmpty) return false;
    final body = compose(text.length > maxLength ? text.substring(0, maxLength) : text);
    final test = debugSender;
    if (test != null) return test(body);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse(_formResponseUrl));
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.write(Uri(queryParameters: {_messageField: body}).query);
      final res = await req.close().timeout(const Duration(seconds: 20));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

import 'dart:io';

import 'package:commands/l10n/tr.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the backup restore button has its own words, not the window's Restore", () {
    // "Restore" is the title bar's button, "Önceki boyut" in Turkish.
    final src = File('lib/widgets/backups_panel.dart').readAsStringSync();
    expect(src, isNot(contains("tr('Restore')")));
    expect(turkish['Restore backup'], 'Geri yükle');
  });
}

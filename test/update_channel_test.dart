import 'package:commands/app_version.dart';
import 'package:commands/providers/app_state.dart';
import 'package:commands/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {

  test('betas are offered only once the Beta box is ticked', () async {
    SharedPreferences.setMockInitialValues({});
    final original = UpdateService.fetchTags;
    addTearDown(() => UpdateService.fetchTags = original);
    UpdateService.fetchTags = () async => ['v99.0.0-beta.1'];
    expect(await UpdateService.check(), isNull, reason: 'nothing saved: normal releases only');

    final app = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(app.updateChannel, ReleaseChannel.stable);
  });

  test('the ticked Beta box is read back on the next start', () async {
    SharedPreferences.setMockInitialValues({'commands.update.channel': 'beta'});
    final app = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(app.updateChannel, ReleaseChannel.beta);
  });
}

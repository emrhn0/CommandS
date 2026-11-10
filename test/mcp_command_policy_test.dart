import 'package:commands/models/models.dart';
import 'package:commands/services/mcp_command_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool free(String command, [DeviceKind? device = DeviceKind.huawei]) =>
      runsWithoutAsking(command, device);

  test('show and display commands run without asking on network devices', () {
    expect(free('display interface'), isTrue);
    expect(free('display current-configuration'), isTrue);
    expect(free('  DISPLAY   version  '), isTrue);
    expect(free('show running-config', DeviceKind.cisco), isTrue);
    expect(free('show interfaces status', DeviceKind.aruba), isTrue);
    expect(free('display interface brief', DeviceKind.hpe), isTrue);
    expect(free('show system info', DeviceKind.paloalto), isTrue);
    expect(free('get system status', DeviceKind.fortinet), isTrue);
    expect(free('show full-configuration', DeviceKind.fortinet), isTrue);
  });

  test('filters after a pipe are fine, writing pipes are not', () {
    expect(free('display interface | include up'), isTrue);
    expect(free('display current-configuration | begin interface'), isTrue);
    expect(free('show run | i vlan', DeviceKind.cisco), isTrue);
    expect(free('show run | sec interface', DeviceKind.cisco), isTrue);
    expect(free('show system info | match version', DeviceKind.paloalto), isTrue);
    expect(free('get system status | grep Version', DeviceKind.fortinet), isTrue);

    expect(free('show run | redirect flash:x.txt', DeviceKind.cisco), isFalse);
    expect(free('show run | tee flash:x.txt', DeviceKind.cisco), isFalse);
    expect(free('show run | append flash:x.txt', DeviceKind.cisco), isFalse);
    expect(free('show run > bootflash:x.txt', DeviceKind.cisco), isFalse);
    expect(free('display version |'), isFalse);
    expect(free('display version || reboot'), isFalse);
  });

  test('bars inside a filter pattern are alternatives, not new pipes', () {
    // Cisco and Huawei read "include A|B|C" as one regular expression.
    expect(free('show wireless client summary | include 0000.5e00.5301|0000.5e00.5302|IP Learn', DeviceKind.cisco), isTrue);
    expect(free('show wireless client mac-address 0000.5e00.5301 detail | include Client IPv4 Address|AP Name|Connected For|VLAN', DeviceKind.cisco), isTrue);
    expect(free('show interfaces | include ^GigabitEthernet|packets input|packets output', DeviceKind.cisco), isTrue);
    expect(free(r'show ip interface brief | include up$|Vlan\d+', DeviceKind.cisco), isTrue);
    expect(free('display interface brief | include GE|XGE'), isTrue);
    expect(free('show run | include vlan | exclude name', DeviceKind.cisco), isTrue);
    expect(free('show running-config | include 192.0.2.10', DeviceKind.cisco), isTrue);

    // A spaced bar is a new pipe, and it still has to filter.
    expect(free('show run | include x | redirect flash:x.txt', DeviceKind.cisco), isFalse);
    expect(free('show run | include x |tee flash:x.txt', DeviceKind.cisco), isFalse);
    // Even glued to a pattern, a writing pipe name asks.
    expect(free('show run | include x|redirect flash:x.txt', DeviceKind.cisco), isFalse);
    expect(free('show run | include x|app flash:x.txt', DeviceKind.cisco), isFalse);
  });

  test('changes, saving and anything else ask', () {
    for (final command in [
      'system-view',
      'save',
      'write memory',
      'configure terminal',
      'conf t',
      'interface GigabitEthernet0/0/1',
      'shutdown',
      'undo shutdown',
      'reboot',
      'reset saved-configuration',
      'delete flash:/x.cfg',
      'commit',
      'execute reboot',
      'set system hostname X',
      'display version; reboot',
      'display version && reboot',
      '',
    ]) {
      expect(free(command), isFalse, reason: command);
      expect(free(command, DeviceKind.cisco), isFalse, reason: command);
    }
  });

  test('abbreviations ask: on Cisco "sh" in interface mode is shutdown', () {
    expect(free('sh', DeviceKind.cisco), isFalse);
    expect(free('sh run', DeviceKind.cisco), isFalse);
    expect(free('dis int'), isFalse);
  });

  test('get is read-only only on Fortinet', () {
    expect(free('get', DeviceKind.cisco), isFalse);
    expect(free('get system status', DeviceKind.paloalto), isFalse);
  });

  test('paging can be turned off for the session without asking', () {
    expect(free('screen-length 0 temporary'), isTrue);
    expect(free('screen-length disable', DeviceKind.hpe), isTrue);
    expect(free('terminal length 0', DeviceKind.cisco), isTrue);
    expect(free('terminal pager 0', DeviceKind.cisco), isTrue);
    expect(free('set cli pager off', DeviceKind.paloalto), isTrue);
    expect(free('screen-length 0'), isFalse, reason: 'without temporary it is saved');
    expect(free('terminal length 0 ; reload', DeviceKind.cisco), isFalse);
  });

  test('servers, Windows and unknown devices always ask', () {
    for (final device in [null, DeviceKind.linux, DeviceKind.windows, DeviceKind.vmware]) {
      expect(free('show version', device), isFalse, reason: '$device');
      expect(free('display version', device), isFalse, reason: '$device');
    }
  });
}

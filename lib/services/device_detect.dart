import '../models/models.dart';

/// Works out what kind of device a session is talking to, from what it says
/// on its own: the identification line every SSH server sends before
/// anything else ([serverVersion], e.g. `SSH-2.0-Cisco-1.25`) and the first
/// screenful it prints after login ([output]: banner, message of the day,
/// prompt). Nothing is ever sent to the device to find out.
///
/// [settled] is set once the session has been up for a while: only then is
/// a Debian/Ubuntu version line taken to mean plain Linux, since an
/// appliance built on them prints its own banner a moment later.
///
/// Null when nothing gives it away; the next connection tries again.
DeviceKind? detectDevice({String serverVersion = '', String output = '', bool settled = false}) {
  final v = serverVersion;
  if (v.toLowerCase().contains('cisco')) return DeviceKind.cisco;
  if (v.contains('HUAWEI')) return DeviceKind.huawei;
  if (v.contains('OpenSSH_for_Windows')) return DeviceKind.windows;

  final text = output.replaceAll(_ansi, '');
  for (final (kind, pattern) in _rules) {
    if (pattern.hasMatch(text)) return kind;
  }

  if (settled && RegExp(r'Ubuntu|Debian|Raspbian').hasMatch(v)) return DeviceKind.linux;
  return null;
}

/// Colour and cursor sequences, which sit between the words of a banner.
final _ansi = RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])');

/// Most specific first: an appliance's banner beats the generic Linux
/// signs (a shell prompt, a kernel version) that it may print as well.
final List<(DeviceKind, RegExp)> _rules = [
  (DeviceKind.vmware, RegExp(r'VMware ESXi|VMware offers supported|VMware vCenter|vCenter Server Appliance')),
  (DeviceKind.paloalto, RegExp(r'Number of failed attempts since last successful login|PAN-OS')),
  (DeviceKind.fortinet, RegExp(r'Forti(Gate|OS|Switch|Analyzer|Manager|WiFi)')),
  (DeviceKind.huawei, RegExp(r'The max number of VTY users|Huawei Versatile Routing Platform|Huawei Technologies')),
  (DeviceKind.hpe, RegExp(r'^[ \t]*(?:HP|HPE) J\d{4}[A-Z] Switch\b', multiLine: true)),
  (DeviceKind.aruba, RegExp(r'ArubaOS|Aruba Networks|HPE Aruba|Aruba Instant|ProCurve')),
  (
    DeviceKind.cisco,
    RegExp(
      r'Cisco (IOS|Nexus|Systems|Adaptive Security|Catalyst|Small Business|Business|Sx\d+)'
      // Many switches name no maker on login: a custom banner, and an
      // identification line that is not their own. What they print once in
      // use still gives them away, as the session's output is read.
      r'|\bIOS[- ]XE\b|\bNX-OS\b|\bWS-C\d{4}'
      r'|^Building configuration\.\.\.'
      r'|^Current configuration ?: ?\d+ bytes'
      r"|^% Invalid input detected at '\^' marker"
      r'|^\s*macro (auto smartport|description)\b'
      r'|^\s*switchport access vlan \d+\s*$'
      r'|^\s*spanning-tree (portfast|bpduguard enable)\b',
      multiLine: true,
    ),
  ),
  (DeviceKind.windows, RegExp(r'Microsoft Windows \[Version|^PS [A-Z]:\\', multiLine: true)),
  (
    DeviceKind.linux,
    RegExp(
      r'Welcome to (Ubuntu|Debian|CentOS|Red Hat|Rocky|AlmaLinux|Fedora|Kali|Raspbian|openSUSE|Oracle Linux|Linux Mint|Proxmox)'
      r'|GNU/Linux'
      // A bash-style prompt, user@host:path$ (or # for root).
      r'|^[\w.-]+@[\w.-]+:[^\r\n]*[$#] ?$',
      multiLine: true,
    ),
  ),
];

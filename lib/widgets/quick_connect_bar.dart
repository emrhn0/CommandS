import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_version.dart';
import '../providers/app_state.dart';
import '../services/serial_session.dart';
import 'context_menu.dart';
import '../l10n/strings.dart';

/// What the quick connect box connects with.
enum QuickProtocol {
  serial('Serial', Icons.cable),
  ssh('SSH', Icons.terminal),
  rdp('RDP', Icons.desktop_windows_outlined);

  const QuickProtocol(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// RDM-style "Bağlan" strip pinned to the bottom of the connections panel —
/// type a target and hit enter/connect for a one-off session, no dialog
/// needed. Serial takes a COM port number (a device's console cable); SSH
/// falls back to PuTTY-style `login as:` / `password:` prompts in the
/// terminal; RDP lets the Remote Desktop client ask for credentials.
class QuickConnectBar extends StatefulWidget {
  const QuickConnectBar({super.key});

  @override
  State<QuickConnectBar> createState() => _QuickConnectBarState();
}

class _QuickConnectBarState extends State<QuickConnectBar> {
  final _controller = TextEditingController();

  /// Serial by default, every launch: the console cable is what this box is
  /// reached for most, the other two are a click away.
  QuickProtocol _protocol = QuickProtocol.serial;

  /// Shown in front of what is typed for a serial port, and not part of the
  /// text, so it cannot be deleted: "COM" on Windows, "/dev/" on macOS.
  static String get serialPrefix => Platform.isWindows ? 'COM' : '/dev/';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setProtocol(QuickProtocol p) {
    if (p == _protocol) return;
    setState(() {
      // A port number is no host and a host is no port: start empty.
      if ((p == QuickProtocol.serial) != (_protocol == QuickProtocol.serial)) _controller.clear();
      _protocol = p;
    });
  }

  void _connect() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    final app = context.read<AppState>();
    if (_protocol == QuickProtocol.serial) {
      final target = parseSerialTarget(raw, windows: Platform.isWindows);
      if (target == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Type the port number, e.g. 3 for COM3 (3:115200 sets the speed).'))),
        );
        return;
      }
      app.openSerial(port: target.port, baud: target.baud);
      _controller.clear();
      return;
    }
    final defaultPort = _protocol == QuickProtocol.rdp ? 3389 : 22;
    final parts = raw.split(':');
    final host = parts.first.trim();
    final port = parts.length > 1 ? int.tryParse(parts[1].trim()) ?? defaultPort : defaultPort;
    if (host.isEmpty) return;
    if (_protocol == QuickProtocol.rdp) {
      app.openQuickRdp(host: host, port: port);
    } else {
      app.openBlankHostOnly(host: host, port: port);
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final serial = _protocol == QuickProtocol.serial;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 2),
            child: Row(
              children: [
                Text(
                  trCount(app.connections.length, '{n} connection', '{n} connections'),
                  style: TextStyle(fontSize: 10, color: theme.textTheme.bodySmall?.color),
                ),
                const Spacer(),
                Text(
                  appVersion,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: TextField(
                    key: ValueKey(serial),
                    controller: _controller,
                    onSubmitted: (_) => _connect(),
                    style: const TextStyle(fontSize: 12),
                    // A port number, and an optional :speed.
                    inputFormatters: serial && Platform.isWindows
                        ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9:]'))]
                        : null,
                    decoration: InputDecoration(
                      // Short enough to fit beside the protocol picker; the
                      // strip's place and its arrow make "quick connect" clear.
                      hintText: serial ? tr('port no.') : tr('Host or IP'),
                      hintStyle: const TextStyle(fontSize: 12),
                      isDense: true,
                      contentPadding: EdgeInsets.only(top: 4, bottom: 4, left: serial ? 0 : 8, right: 8),
                      // A prefix icon, not prefixText: prefixText is only drawn
                      // once the field has focus or text, and "COM" should be
                      // there from the start.
                      prefixIcon: serial
                          ? Padding(
                              padding: const EdgeInsets.only(left: 8, right: 1),
                              child: Text(
                                serialPrefix,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: theme.textTheme.bodySmall?.color,
                                ),
                              ),
                            )
                          : null,
                      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward, size: 14),
                        tooltip: tr('Connect'),
                        visualDensity: VisualDensity.compact,
                        onPressed: _connect,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _ProtocolPicker(value: _protocol, onChanged: _setProtocol),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the protocol quick connect will use; clicking it opens the same
/// desktop menu as the connection tree, with the current choice ticked.
class _ProtocolPicker extends StatefulWidget {
  const _ProtocolPicker({required this.value, required this.onChanged});
  final QuickProtocol value;
  final ValueChanged<QuickProtocol> onChanged;

  @override
  State<_ProtocolPicker> createState() => _ProtocolPickerState();
}

class _ProtocolPickerState extends State<_ProtocolPicker> {
  Future<void> _open() async {
    final box = context.findRenderObject() as RenderBox;
    final picked = await showContextMenu(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      header: tr('Quick connect with'),
      minWidth: 170,
      actions: [
        for (final p in QuickProtocol.values) MenuAction(p.name, p.label, p.icon, checked: p == widget.value),
      ],
    );
    if (picked == null) return;
    widget.onChanged(QuickProtocol.values.byName(picked));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tr('Quick connect protocol'),
      child: Material(
        color: theme.inputDecorationTheme.fillColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: theme.dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _open,
          child: Container(
            height: 28,
            padding: const EdgeInsets.only(left: 8, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.value.icon, size: 13),
                const SizedBox(width: 5),
                Text(
                  tr(widget.value.label),
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 2),
                const Icon(Icons.expand_more, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

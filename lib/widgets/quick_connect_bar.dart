import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_version.dart';
import '../models/models.dart';
import '../providers/app_state.dart';

/// RDM-style "Bağlan" strip pinned to the bottom of the connections panel —
/// type a bare host and hit enter/connect for a one-off session, no dialog
/// needed. SSH falls back to PuTTY-style `login as:` / `password:` prompts in
/// the terminal; RDP lets the Remote Desktop client ask for credentials.
class QuickConnectBar extends StatefulWidget {
  const QuickConnectBar({super.key});

  @override
  State<QuickConnectBar> createState() => _QuickConnectBarState();
}

class _QuickConnectBarState extends State<QuickConnectBar> {
  final _controller = TextEditingController();

  /// SSH by default, every launch: it is what this box was for before it had
  /// a choice, and what most quick connections are.
  ConnectionProtocol _protocol = ConnectionProtocol.ssh;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _defaultPort => _protocol == ConnectionProtocol.rdp ? 3389 : 22;

  void _connect() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    final parts = raw.split(':');
    final host = parts.first.trim();
    final port = parts.length > 1 ? int.tryParse(parts[1].trim()) ?? _defaultPort : _defaultPort;
    if (host.isEmpty) return;
    final app = context.read<AppState>();
    if (_protocol == ConnectionProtocol.rdp) {
      app.openQuickRdp(host: host, port: port);
    } else {
      app.openBlankHostOnly(host: host, port: port);
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 2),
            child: Row(
              children: [
                Text(
                  '${app.connections.length} connection${app.connections.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 10, color: Theme.of(context).textTheme.bodySmall?.color),
                ),
                const Spacer(),
                Text(
                  appVersion,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.4),
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
                    controller: _controller,
                    onSubmitted: (_) => _connect(),
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      // Short enough to fit beside the protocol picker; the
                      // strip's place and its arrow make "quick connect" clear.
                      hintText: 'Host or IP',
                      hintStyle: const TextStyle(fontSize: 12),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward, size: 14),
                        tooltip: 'Connect',
                        visualDensity: VisualDensity.compact,
                        onPressed: _connect,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _ProtocolPicker(
                value: _protocol,
                onChanged: (p) => setState(() => _protocol = p),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the protocol quick connect will use; clicking it offers the other
/// one. A menu rather than a toggle so that it reads as a choice with a
/// current value, the same way the protocol picker in the connection dialog
/// does.
class _ProtocolPicker extends StatelessWidget {
  const _ProtocolPicker({required this.value, required this.onChanged});
  final ConnectionProtocol value;
  final ValueChanged<ConnectionProtocol> onChanged;

  static String _label(ConnectionProtocol p) => p == ConnectionProtocol.rdp ? 'RDP' : 'SSH';

  static IconData _icon(ConnectionProtocol p) =>
      p == ConnectionProtocol.rdp ? Icons.desktop_windows_outlined : Icons.terminal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final other = value == ConnectionProtocol.rdp ? ConnectionProtocol.ssh : ConnectionProtocol.rdp;
    return PopupMenuButton<ConnectionProtocol>(
      tooltip: 'Quick connect protocol',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (_) => [
        PopupMenuItem(
          value: other,
          height: 32,
          child: Row(
            children: [
              Icon(_icon(other), size: 14),
              const SizedBox(width: 8),
              Text(_label(other), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon(value), size: 13),
            const SizedBox(width: 5),
            Text(_label(value), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }
}

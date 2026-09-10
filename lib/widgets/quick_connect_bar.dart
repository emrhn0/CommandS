import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// RDM-style "Bağlan" strip pinned to the bottom of the connections panel —
/// type a bare host and hit enter/connect for a PuTTY-style host-only
/// session, no dialog needed.
class QuickConnectBar extends StatefulWidget {
  const QuickConnectBar({super.key});

  @override
  State<QuickConnectBar> createState() => _QuickConnectBarState();
}

class _QuickConnectBarState extends State<QuickConnectBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _connect() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    final parts = raw.split(':');
    final host = parts.first.trim();
    final port = parts.length > 1 ? int.tryParse(parts[1].trim()) ?? 22 : 22;
    if (host.isEmpty) return;
    context.read<AppState>().openBlankHostOnly(host: host, port: port);
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
            child: Text(
              '${app.connections.length} connection${app.connections.length == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 10, color: Theme.of(context).textTheme.bodySmall?.color),
            ),
          ),
          SizedBox(
            height: 28,
            child: TextField(
              controller: _controller,
              onSubmitted: (_) => _connect(),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Host or IP — quick connect',
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
        ],
      ),
    );
  }
}

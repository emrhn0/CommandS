import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';
import '../services/mcp_catalog.dart';
import '../services/mcp_server.dart';

/// How long a request waits for an answer before it counts as a no.
const mcpApprovalTimeout = Duration(minutes: 2);

/// Asks the user whether a command from the connected agent may run. Nothing
/// runs without a yes; no answer in time, or no window to ask in, is a no.
Future<bool> askMcpApproval(GlobalKey<NavigatorState> navigator, McpApproval approval) async {
  final context = navigator.currentContext;
  if (context == null) return false;
  unawaited(windowManager.focus().catchError((Object _) {}));
  final answer = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => McpApprovalDialog(approval: approval),
  ).timeout(mcpApprovalTimeout, onTimeout: () {
    navigator.currentState?.maybePop(false);
    return false;
  });
  return answer ?? false;
}

Future<bool> askMcpCatalogApproval(
  GlobalKey<NavigatorState> navigator,
  McpCatalogApproval approval,
) async {
  final state = navigator.currentState;
  if (state == null) return false;
  unawaited(windowManager.focus().catchError((Object _) {}));
  final route = DialogRoute<bool>(
    context: state.context,
    barrierDismissible: false,
    builder: (context) {
      final addingFolder = approval.connections.isEmpty;
      return AlertDialog(
        title: Text(addingFolder ? tr('Create this folder?') : tr('Save these connections?')),
        scrollable: true,
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Requested by the connected MCP agent.')),
              const SizedBox(height: 12),
              Text(tr('Folder')),
              SelectableText(approval.path.isEmpty ? tr('No folder (top level)') : approval.path.join(' › ')),
              if (approval.kind case final kind?) Text(tr(kind.label)),
              for (final connection in approval.connections)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(connection),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(addingFolder ? tr('Create') : tr('Save')),
          ),
        ],
      );
    },
  );
  final answer = await state.push(route).timeout(mcpApprovalTimeout, onTimeout: () {
    // Remove only this request, even if a different dialog was opened later.
    if (route.isActive) state.removeRoute(route);
    return false;
  });
  return answer ?? false;
}

class McpApprovalDialog extends StatelessWidget {
  const McpApprovalDialog({super.key, required this.approval});
  final McpApproval approval;

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return AlertDialog(
      title: Text(tr('Run this command?')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('The connected agent wants to run this on {name} (shown to it as {alias}).', {
                'name': approval.connectionName,
                'alias': approval.alias,
              }),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(approval.command, style: const TextStyle(fontFamily: 'Consolas', fontSize: 13)),
            ),
            const SizedBox(height: 10),
            Text(
              tr('Its output will be sent to the agent.'),
              style: TextStyle(fontSize: 12, color: dim),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('mcp-deny'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('Do not run')),
        ),
        FilledButton(
          key: const ValueKey('mcp-allow'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('Run')),
        ),
      ],
    );
  }
}

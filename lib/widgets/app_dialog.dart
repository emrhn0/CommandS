import 'package:flutter/material.dart';

/// The app's dialog frame, shared by every popup so they all look like the
/// connection dialog: a title bar with an icon and a close button, the body,
/// and the actions on a tinted footer band, Windows-style.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.body,
    required this.actions,
    this.icon,
    this.width = 400,
    this.closable = true,
    this.scrollable = true,
    this.maxHeight = double.infinity,
  });

  final String title;
  final IconData? icon;
  final Widget body;
  final List<Widget> actions;
  final double width;

  /// False while the dialog must not be dismissed (an update installing).
  final bool closable;

  /// False when [body] scrolls by itself (a list); it is then given the
  /// height left over, up to [maxHeight] for the whole dialog.
  final bool scrollable;
  final double maxHeight;

  static const _bodyPadding = EdgeInsets.fromLTRB(20, 16, 20, 18);

  static Widget _styled(Widget body) =>
      DefaultTextStyle.merge(style: const TextStyle(fontSize: 13, height: 1.4), child: body);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 10, 12),
              child: Row(
                children: [
                  if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 10)],
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'Close',
                    onPressed: closable ? () => Navigator.pop(context) : null,
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: scrollable
                  ? SingleChildScrollView(padding: _bodyPadding, child: _styled(body))
                  : Padding(padding: _bodyPadding, child: _styled(body)),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              // Wraps rather than overflowing with large system fonts.
              child: actions.isEmpty
                  ? const SizedBox(height: 34)
                  : Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
            ),
          ],
        ),
      ),
    );
  }
}

/// A label above its field, as desktop forms do, rather than Material's
/// label floating inside the box.
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 1, bottom: 4),
            child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ),
          child,
        ],
      ),
    );
  }
}

/// Asks for one line of text (a new name). Returns the trimmed text, or null
/// when cancelled or left empty.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String initial,
  String label = 'Name',
  String okLabel = 'Rename',
  IconData icon = Icons.edit_outlined,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) =>
        _TextInputDialog(title: title, initial: initial, label: label, okLabel: okLabel, icon: icon),
  );
  return (result == null || result.isEmpty) ? null : result;
}

/// Owns its controller, so it lives until the dialog's closing animation
/// has finished with the field, not just until the result comes back.
class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initial,
    required this.label,
    required this.okLabel,
    required this.icon,
  });

  final String title;
  final String initial;
  final String label;
  final String okLabel;
  final IconData icon;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: widget.title,
      icon: widget.icon,
      body: LabeledField(
        label: widget.label,
        child: TextField(controller: _controller, autofocus: true, onSubmitted: (_) => _submit()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _submit, child: Text(widget.okLabel)),
      ],
    );
  }
}

/// A yes/no question. [destructive] draws the confirm button in red, the way
/// the context menu marks Delete.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  IconData? icon,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final danger = Theme.of(ctx).colorScheme.error;
      return AppDialog(
        title: title,
        icon: icon ?? (destructive ? Icons.delete_outline : Icons.help_outline),
        body: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: destructive
                ? ElevatedButton.styleFrom(backgroundColor: danger, foregroundColor: Colors.white)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result == true;
}

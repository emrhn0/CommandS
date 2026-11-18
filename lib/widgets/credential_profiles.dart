import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import 'app_dialog.dart';

/// Creates a credential profile, or edits [existing], and saves it. Returns
/// the saved profile, or null when cancelled.
Future<CredentialProfile?> showCredentialProfileDialog(BuildContext context, {CredentialProfile? existing}) {
  return showDialog<CredentialProfile>(
    context: context,
    builder: (_) => _ProfileDialog(existing: existing),
  );
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({this.existing});
  final CredentialProfile? existing;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _username = TextEditingController(text: widget.existing?.username ?? '');
  late final _password = TextEditingController(text: widget.existing?.password ?? '');
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('Give the profile a name.'));
      return;
    }
    final profile = CredentialProfile(
      id: widget.existing?.id,
      name: name,
      username: _username.text.trim(),
      password: _password.text,
    );
    await context.read<AppState>().upsertProfile(profile);
    if (mounted) Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: tr(widget.existing == null ? 'New credential profile' : 'Edit credential profile'),
      icon: Icons.badge_outlined,
      width: 420,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledField(
            label: 'Profile name',
            child: TextField(
              key: const Key('profile-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(hintText: tr('Network admin'), errorText: _error),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ),
          LabeledField(
            label: 'Username',
            child: TextField(key: const Key('profile-username'), controller: _username),
          ),
          LabeledField(
            label: 'Password',
            child: TextField(
              key: const Key('profile-password'),
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                hintText: tr('Ask on connect'),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 16),
                  tooltip: _obscure ? tr('Show password') : tr('Hide password'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
          ),
          Text(
            tr('The password is encrypted on this computer, like a connection\'s.'),
            style: TextStyle(fontSize: 11.5, color: Theme.of(context).textTheme.bodySmall?.color),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
        ElevatedButton(key: const Key('profile-save'), onPressed: _save, child: Text(tr('Save'))),
      ],
    );
  }
}

/// Settings > Connections > Credential profiles: the list, with add, edit
/// and delete.
class CredentialProfilesPanel extends StatelessWidget {
  const CredentialProfilesPanel({super.key});

  Future<void> _delete(BuildContext context, CredentialProfile profile) async {
    final app = context.read<AppState>();
    final uses = app.profileUseCount(profile.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: tr('Delete "{name}"?', {'name': profile.name}),
        icon: Icons.delete_outline,
        width: 420,
        body: Text(
          uses == 0
              ? tr('No connection uses this profile.')
              : tr('{count} connections use it. They keep working: each takes its user name and password as its own.',
                  {'count': uses}),
          style: const TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(tr('Cancel'))),
          ElevatedButton(
            key: const Key('profile-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (ok == true) await app.deleteProfile(profile.id);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    final profiles = [...app.credentialProfiles]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Column(
      key: const Key('credential-profiles-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('One user name and password for many connections. Change the password here, and every connection '
              'using the profile has it. Pick a profile in a connection\'s Credentials.'),
          style: TextStyle(fontSize: 12.5, color: dim, height: 1.45),
        ),
        const SizedBox(height: 12),
        for (final p in profiles)
          Padding(
            key: Key('profile-row-${p.id}'),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                const Icon(Icons.badge_outlined, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      TextSpan(
                        text: '   ${p.username.isEmpty ? tr('no user name') : p.username}'
                            '  ·  ${tr('{count} connections', {'count': app.profileUseCount(p.id)})}',
                        style: TextStyle(color: dim),
                      ),
                    ]),
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: tr('Edit'),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  onPressed: () => showCredentialProfileDialog(context, existing: p),
                ),
                IconButton(
                  tooltip: tr('Delete'),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  onPressed: () => _delete(context, p),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('profile-add'),
            onPressed: () => showCredentialProfileDialog(context),
            icon: const Icon(Icons.add, size: 16),
            label: Text(tr('New profile')),
          ),
        ),
      ],
    );
  }
}

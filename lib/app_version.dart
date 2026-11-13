/// CI supplies the release tag. Local builds use the current source version.
const String appVersion = String.fromEnvironment('COMMANDS_VERSION', defaultValue: 'v1.1.32');

enum ReleaseChannel { stable, beta }

/// Set by the build, independent of the update channel chosen in Settings.
const String _buildChannel = String.fromEnvironment('COMMANDS_CHANNEL', defaultValue: 'stable');
const ReleaseChannel buildChannel = _buildChannel == 'beta' ? ReleaseChannel.beta : ReleaseChannel.stable;
const String appName = buildChannel == ReleaseChannel.beta ? 'CommandS Beta' : 'CommandS';
/// The same for a beta: it replaces the normal app and keeps its data.
const String appDataDirName = 'CommandS';

ReleaseChannel releaseChannelFromString(String? value) =>
    value == 'beta' ? ReleaseChannel.beta : ReleaseChannel.stable;

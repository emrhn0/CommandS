/// Not read from `pubspec.yaml` -- its version field isn't wired to the
/// actual vX.Y.Z release tags this app ships under, and there's no runtime
/// package-info plumbing to read it if it were. Bump by hand alongside the
/// git tag each release.
const String appVersion = 'v1.0.22';

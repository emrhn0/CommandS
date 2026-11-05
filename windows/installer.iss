; CommandS - Inno Setup script.
; No admin rights required (installs into the user profile). Payload folder
; is provided by CI in PayloadDir (build\windows\x64\runner\Release); for a
; local test build the default path below is used.
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef PayloadDir
  #define PayloadDir "..\build\windows\x64\runner\Release"
#endif
#ifdef BetaBuild
  #define AppIdentity "CommandS Beta"
  #define AppExecutable "beta_commands.exe"
  #define AppInstallerName "CommandS_Beta"
  #define AppGuid "{{D94019C4-79D2-4C0C-9C84-61035E49EA02}"
#else
  #define AppIdentity "CommandS"
  #define AppExecutable "commands.exe"
  #define AppInstallerName "CommandS"
  #define AppGuid "{{4C6F0A1E-7B2A-4E1B-9F0C-3A6D1C2E7B90}"
#endif

[Setup]
AppId={#AppGuid}
AppName={#AppIdentity}
AppVersion={#MyAppVersion}
; Shown in Settings > Apps as "CommandS v1.1.20" (default is "CommandS version 1.1.20").
AppVerName={#AppIdentity} v{#MyAppVersion}
UninstallDisplayName={#AppIdentity} v{#MyAppVersion}
AppPublisher=CommandS
DefaultDirName={localappdata}\Programs\{#AppIdentity}
DefaultGroupName={#AppIdentity}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename={#AppInstallerName}_{#MyAppVersion}_windows_Setup
OutputDir=..\dist2
Compression=lzma2
SolidCompression=yes
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExecutable}
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

; User data (connections/folders - shared_preferences) lives under %APPDATA%,
; outside {app}, so it survives upgrades. Cleanup below only removes the
; previous version's program files.
[InstallDelete]
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\*.exe"
Type: files; Name: "{app}\*.pdb"

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#AppIdentity}"; Filename: "{app}\{#AppExecutable}"
Name: "{userdesktop}\{#AppIdentity}"; Filename: "{app}\{#AppExecutable}"

[Run]
Filename: "{app}\{#AppExecutable}"; Description: "Launch {#AppIdentity}"; Flags: nowait postinstall skipifsilent
; The in-app updater runs this installer silently and then has nothing left to
; relaunch the app with: it had to exit for its files to be replaced, and the
; entry above is skipped in silent mode. /RELAUNCH asks the installer to do it.
; Started from here rather than from a `cmd /c "... && start ..."` chain in the
; app, because cmd.exe's quote handling mangles any such line that begins with
; a quoted path -- the updater shipped that way and never ran the installer.
Filename: "{app}\{#AppExecutable}"; Flags: nowait; Check: RelaunchRequested

[Code]
function RelaunchRequested: Boolean;
begin
  Result := WizardSilent and (Pos('/RELAUNCH', UpperCase(GetCmdTail)) > 0);
end;

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

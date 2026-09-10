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

[Setup]
AppId={{4C6F0A1E-7B2A-4E1B-9F0C-3A6D1C2E7B90}
AppName=CommandS
AppVersion={#MyAppVersion}
AppPublisher=CommandS
DefaultDirName={localappdata}\Programs\CommandS
DefaultGroupName=CommandS
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=CommandS_{#MyAppVersion}_windows_Setup
OutputDir=..\dist2
Compression=lzma2
SolidCompression=yes
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\commands.exe
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
Name: "{group}\CommandS"; Filename: "{app}\commands.exe"
Name: "{userdesktop}\CommandS"; Filename: "{app}\commands.exe"

[Run]
Filename: "{app}\commands.exe"; Description: "Launch CommandS"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

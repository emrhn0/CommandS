/// German wording for the app's UI, keyed by the English text, the same way
/// as `tr.dart`. Placeholders in braces are filled in after the lookup.
const german = <String, String>{
  // ---- Common ----
  'Cancel': 'Abbrechen',
  'Close': 'Schließen',
  'Save': 'Speichern',
  'Delete': 'Löschen',
  'Rename': 'Umbenennen',
  'Create': 'Erstellen',
  'Apply': 'Übernehmen',
  'Name': 'Name',
  'Folder': 'Ordner',
  'Host': 'Host',
  'Port': 'Port',
  'Username': 'Benutzername',
  'Password': 'Passwort',
  'Domain': 'Domäne',
  'Optional': 'Optional',
  'Connect': 'Verbinden',
  'Settings': 'Einstellungen',
  'Hide Sidebar': 'Seitenleiste ausblenden',
  'Show Sidebar': 'Seitenleiste einblenden',
  'Back': 'Zurück',
  'Try again': 'Erneut versuchen',
  'Unknown error.': 'Unbekannter Fehler.',
  'Something went wrong.': 'Etwas ist schiefgelaufen.',
  'Saved password for sudo': 'Gespeichertes Passwort für sudo',
  'Fill': 'Einfügen',
  'Session logs': 'Sitzungsprotokolle',
  'Other': 'Sonstiges',
  'Record session automatically': 'Sitzung automatisch aufzeichnen',
  'SSH output is saved as UTF-8 under <host>/<YYYY-MM-DD>/<HH-mm-ss>.log.':
      'Die SSH-Ausgabe wird als UTF-8 unter <host>/<YYYY-MM-DD>/<HH-mm-ss>.log gespeichert.',
  'Choose log folder': 'Protokollordner wählen',
  'Open folder': 'Ordner öffnen',
  'Open file': 'Datei öffnen',
  'Loading…': 'Wird geladen…',
  'Record session': 'Sitzung aufzeichnen',
  'Stop recording': 'Aufzeichnung beenden',
  'Record SSH session': 'SSH-Sitzung aufzeichnen',
  'Session recording is on': 'Sitzungsaufzeichnung läuft',
  'Session recording failed': 'Sitzungsaufzeichnung fehlgeschlagen',
  'Session recording stopped: {error}': 'Sitzungsaufzeichnung beendet: {error}',
  'Session log saved to {path}': 'Sitzungsprotokoll gespeichert unter {path}',
  'Could not record session: {error}': 'Sitzung konnte nicht aufgezeichnet werden: {error}',
  'SFTP files': 'SFTP-Dateien',
  'Remote files': 'Entfernte Dateien',
  'Local files': 'Lokale Dateien',
  'Transfers': 'Übertragungen',
  'No transfers yet': 'Noch keine Übertragungen',
  'Upload': 'Hochladen',
  'Download': 'Herunterladen',
  'Transferring': 'Wird übertragen',
  'Completed': 'Abgeschlossen',
  'Failed': 'Fehlgeschlagen',
  'Verified': 'Geprüft',
  'Verifying SHA-256': 'SHA-256 wird geprüft',
  'Replace file?': 'Datei ersetzen?',
  'File {name} already exists at the destination.': 'Die Datei {name} ist am Ziel bereits vorhanden.',
  'Replace': 'Ersetzen',
  'New remote folder': 'Neuer entfernter Ordner',
  'New local folder': 'Neuer lokaler Ordner',
  'Invalid folder name': 'Ungültiger Ordnername',
  'Parent folder': 'Übergeordneter Ordner',
  'Refresh': 'Aktualisieren',
  'SFTP password': 'SFTP-Passwort',
  'Use SFTP password': 'SFTP-Passwort verwenden',

  // ---- Window ----
  'Minimize': 'Minimieren',
  'Maximize': 'Maximieren',
  'Restore': 'Wiederherstellen',

  // ---- Sidebar / tree ----
  'New Connection': 'Neue Verbindung',
  'Filter connections': 'Verbindungen filtern',
  'Select all': 'Alle auswählen',
  'New folder': 'Neuer Ordner',
  'No matches': 'Keine Treffer',
  'Move to folder': 'In Ordner verschieben',
  'Clear selection': 'Auswahl aufheben',
  'Device': 'Gerät',
  'Automatic (learnt when you connect)': 'Automatisch (beim Verbinden erkannt)',
  'Automatic ({device})': 'Automatisch ({device})',
  'selected': 'ausgewählt',
  'New connection here': 'Neue Verbindung hier',
  'New folder here': 'Neuer Ordner hier',
  'Delete folder': 'Ordner löschen',
  'Edit…': 'Bearbeiten…',
  'Clone': 'Klonen',
  'Move to folder…': 'In Ordner verschieben…',
  'Open layout': 'Layout öffnen',
  'Delete layout': 'Layout löschen',
  'Rename folder': 'Ordner umbenennen',
  'Rename connection': 'Verbindung umbenennen',
  'Rename layout': 'Layout umbenennen',
  'Move layout to folder': 'Layout in Ordner verschieben',
  'Choose a folder': 'Ordner wählen',
  'Layout': 'Layout',
  '{n} connection': '{n} Verbindung',
  '{n} connections': '{n} Verbindungen',
  '{n} folder': '{n} Ordner',
  '{n} folders': '{n} Ordner',
  '{n} item': '{n} Element',
  '{n} items': '{n} Elemente',
  ' and ': ' und ',
  'Delete {what}?': '{what} löschen?',
  'Delete "{name}"?': '„{name}“ löschen?',
  'This cannot be undone.': 'Dies kann nicht rückgängig gemacht werden.',
  "This cannot be undone. Deleted folders' contents are NOT deleted — they move to root, unfiled.":
      'Dies kann nicht rückgängig gemacht werden. Der Inhalt gelöschter Ordner wird NICHT gelöscht — er wird ohne Ordner auf die oberste Ebene verschoben.',
  'This folder is empty.': 'Dieser Ordner ist leer.',
  'It contains {n} item. It will NOT be deleted — it moves to the root, unfiled.':
      'Er enthält {n} Element. Es wird NICHT gelöscht — es wird ohne Ordner auf die oberste Ebene verschoben.',
  'It contains {n} items. They will NOT be deleted — they move to the root, unfiled.':
      'Er enthält {n} Elemente. Sie werden NICHT gelöscht — sie werden ohne Ordner auf die oberste Ebene verschoben.',
  'Move {n} item to folder': '{n} Element in Ordner verschieben',
  'Move {n} items to folder': '{n} Elemente in Ordner verschieben',
  'None of the connections in "{name}" exist any more.': 'Keine der Verbindungen in „{name}“ existiert mehr.',

  // ---- Session state ----
  'Connected': 'Verbunden',
  'Connecting': 'Verbindung wird hergestellt',
  'Disconnected': 'Getrennt',
  'Session ended': 'Sitzung beendet',
  'Ended': 'Beendet',

  // ---- Quick connect ----
  'Host or IP': 'Host oder IP',
  'Quick connect with': 'Schnellverbindung mit',
  'Quick connect protocol': 'Protokoll der Schnellverbindung',
  'Serial': 'Seriell',
  'port no.': 'Port-Nr.',
  'Type the port number, e.g. 3 for COM3 (3:115200 sets the speed).':
      'Portnummer eingeben, z. B. 3 für COM3 (3:115200 legt die Geschwindigkeit fest).',

  // ---- Connection dialog ----
  'Edit Connection': 'Verbindung bearbeiten',
  'Save Connection': 'Verbindung speichern',
  'Connection': 'Verbindung',
  'Credentials': 'Anmeldedaten',
  'Remote desktop': 'Remotedesktop',
  'Defaults to the host': 'Standardmäßig der Host',
  'Hostname after first SSH connection, otherwise host': 'Hostname nach der ersten SSH-Verbindung, sonst der Host',
  'Ask on connect': 'Beim Verbinden fragen',
  'Show password': 'Passwort anzeigen',
  'Hide password': 'Passwort verbergen',
  'Share clipboard': 'Zwischenablage teilen',
  'Show wallpaper': 'Hintergrundbild anzeigen',
  'Save and Connect': 'Speichern und verbinden',

  // ---- Tabs ----
  'No active session': 'Keine aktive Sitzung',
  'Pick a saved connection on the left, use quick connect,\nor start a new one.':
      'Wählen Sie links eine gespeicherte Verbindung, nutzen Sie die Schnellverbindung\noder legen Sie eine neue an.',
  'Show the sidebar to pick a saved connection,\nor start a new one.':
      'Blenden Sie die Seitenleiste ein, um eine gespeicherte Verbindung zu wählen,\noder legen Sie eine neue an.',
  'Split view': 'Geteilte Ansicht',
  'Split View': 'Geteilte Ansicht',
  'Edit split view…': 'Geteilte Ansicht bearbeiten…',
  'Separate into tabs': 'In Tabs aufteilen',
  'Separate': 'Aufteilen',
  'Close all sessions': 'Alle Sitzungen schließen',
  'Open a second tab to split the view': 'Öffnen Sie einen zweiten Tab, um die Ansicht zu teilen',
  'Save connection…': 'Verbindung speichern…',
  'Edit connection…': 'Verbindung bearbeiten…',
  'Close tab': 'Tab schließen',
  'Reconnect dropped sessions': 'Getrennte Sitzungen neu verbinden',

  // ---- RDP ----
  'Remote Desktop disconnected': 'Remotedesktop getrennt',
  'The session could not be started.': 'Die Sitzung konnte nicht gestartet werden.',
  'The remote session was closed. Reconnect to start a new one.':
      'Die Remotesitzung wurde geschlossen. Verbinden Sie neu, um eine neue zu starten.',
  'Reconnect': 'Neu verbinden',
  'Duplicate': 'Duplizieren',
  'Reconnect to fill the current pane size': 'Neu verbinden, um die aktuelle Fenstergröße zu füllen',
  'Send Ctrl+Alt+Del': 'Strg+Alt+Entf senden',
  'RDP session could not start': 'RDP-Sitzung konnte nicht starten',
  'RDP session closed': 'RDP-Sitzung geschlossen',
  'RDP session opened': 'RDP-Sitzung geöffnet',
  'Open again': 'Erneut öffnen',
  'Copied': 'Kopiert',
  'Copy password': 'Passwort kopieren',
  'the RDP client': 'der RDP-Client',
  'The {client} window for {host} has closed. Open it again to reconnect.':
      'Das {client}-Fenster für {host} wurde geschlossen. Öffnen Sie es erneut, um neu zu verbinden.',
  '{host} is open in {client}, in its own window, signed in with your saved credentials. '
          'macOS has no embeddable RDP component and does not let one app place another app’s window '
          'inside a tab, so the session cannot be drawn in here.':
      '{host} ist in {client} in einem eigenen Fenster geöffnet, angemeldet mit Ihren gespeicherten '
      'Anmeldedaten. macOS hat keine einbettbare RDP-Komponente und erlaubt keiner App, das Fenster '
      'einer anderen App in einen Tab zu setzen, daher kann die Sitzung hier nicht angezeigt werden.',
  '{host} is open in {client}, in its own window, with the host and username filled in — '
          '{client} keeps its own credential store, so the password is the one thing CommandS cannot '
          'hand it. Copy it below, or run "brew install freerdp" and CommandS will sign you in with '
          'no prompt at all.':
      '{host} ist in {client} in einem eigenen Fenster geöffnet, Host und Benutzername sind ausgefüllt — '
      '{client} hat einen eigenen Anmeldedatenspeicher, daher kann CommandS ihm nur das Passwort nicht '
      'übergeben. Kopieren Sie es unten, oder führen Sie „brew install freerdp“ aus, dann meldet '
      'CommandS Sie ganz ohne Abfrage an.',
  '{host} is open in {client}, in its own window, with the host and username filled in.':
      '{host} ist in {client} in einem eigenen Fenster geöffnet, Host und Benutzername sind ausgefüllt.',

  // ---- Split view and layouts ----
  'Open tabs': 'Offene Tabs',
  'Save as layout…': 'Als Layout speichern…',
  'Save layout': 'Layout speichern',
  'Drop here': 'Hier ablegen',
  'Drop a tab here': 'Tab hier ablegen',
  'Empty this pane': 'Bereich leeren',
  'the top level': 'die oberste Ebene',
  'Saved to {folder}. Open it from there any time to bring these sessions back like this.':
      'In {folder} gespeichert. Öffnen Sie es dort jederzeit, um diese Sitzungen so wiederherzustellen.',
  'Empty panes are left out. Click a tab to put it in the first empty pane.':
      'Leere Bereiche werden weggelassen. Klicken Sie auf einen Tab, um ihn in den ersten leeren Bereich zu setzen.',
  '{n} pane holds a quick connection, which is not saved and cannot be reopened, so it is saved empty.':
      '{n} Bereich enthält eine Schnellverbindung, die nicht gespeichert ist und nicht erneut geöffnet werden kann; er wird leer gespeichert.',
  '{n} panes hold quick connections, which are not saved and cannot be reopened, so they are saved empty.':
      '{n} Bereiche enthalten Schnellverbindungen, die nicht gespeichert sind und nicht erneut geöffnet werden können; sie werden leer gespeichert.',
  'Single': 'Einzeln',
  'Side by side': 'Nebeneinander',
  'Stacked': 'Übereinander',
  'One + two': 'Eins + zwei',
  'Three columns': 'Drei Spalten',
  'Grid': 'Raster',

  // ---- Folder picker / selection ----
  'No folder (top level)': 'Kein Ordner (oberste Ebene)',
  'Search folders': 'Ordner durchsuchen',
  'No folder matches.': 'Kein passender Ordner.',
  '{n} of {total} selected': '{n} von {total} ausgewählt',
  'Nothing to show': 'Nichts anzuzeigen',
  'Password will be included': 'Passwort wird einbezogen',
  'Password will be excluded': 'Passwort wird nicht einbezogen',
  'Confirm ({n})': 'Bestätigen ({n})',

  // ---- Import / export ----
  'Import connections': 'Verbindungen importieren',
  'Export connections': 'Verbindungen exportieren',
  'Import from Remote Desktop Manager': 'Aus Remote Desktop Manager importieren',
  'From an export file (JSON, XML or CSV).': 'Aus einer Exportdatei (JSON, XML oder CSV).',
  'Save some or all of your connections as JSON, XML or CSV.':
      'Speichern Sie einige oder alle Verbindungen als JSON, XML oder CSV.',
  'Import…': 'Importieren…',
  'Export…': 'Exportieren…',
  'No connections to export yet.': 'Noch keine Verbindungen zum Exportieren.',
  'Export format': 'Exportformat',
  'Everything, for importing into CommandS again': 'Alles, zum erneuten Import in CommandS',
  'Folders and connections': 'Ordner und Verbindungen',
  'One row per connection': 'Eine Zeile pro Verbindung',
  'Export CommandS connections': 'CommandS-Verbindungen exportieren',
  'Exported to {path}': 'Exportiert nach {path}',
  'Import connections (CommandS JSON/XML/CSV or Remote Desktop Manager JSON)':
      'Verbindungen importieren (CommandS JSON/XML/CSV oder Remote Desktop Manager JSON)',
  "This XML doesn't look like a CommandS export (no <Connection>/<Folder> elements found). "
          "CommandS's own XML import only round-trips its own export — for Remote Desktop Manager, "
          'export as JSON instead, or as CSV if you need passwords included.':
      'Dieses XML sieht nicht wie ein CommandS-Export aus (keine <Connection>/<Folder>-Elemente gefunden). '
      'Der XML-Import von CommandS liest nur den eigenen Export — exportieren Sie aus Remote Desktop Manager '
      'stattdessen als JSON, oder als CSV, wenn Passwörter enthalten sein sollen.',
  'Imported {n} connection(s)': '{n} Verbindung(en) importiert',
  '{n} skipped (unsupported type)': '{n} übersprungen (nicht unterstützter Typ)',
  "{n} password(s) are AES-encrypted by RDM's own vault and can't be decrypted from this file "
          '(true for JSON or XML alike) — re-enter them, or export from RDM as CSV/spreadsheet with '
          'credentials revealed and import that instead':
      '{n} Passwort/Passwörter sind mit dem eigenen Tresor von RDM per AES verschlüsselt und können aus '
      'dieser Datei nicht entschlüsselt werden (gilt für JSON und XML) — geben Sie sie neu ein, oder '
      'exportieren Sie aus RDM als CSV/Tabelle mit sichtbaren Anmeldedaten und importieren Sie diese',
  'Import failed: {error}': 'Import fehlgeschlagen: {error}',

  // ---- Settings ----
  'Appearance': 'Darstellung',
  'Theme': 'Design',
  'Theme & colors': 'Design & Farben',
  'Opened by an AI agent over MCP': 'Von einem KI-Agenten über MCP geöffnet',
  'App theme': 'App-Design',
  'Color': 'Farbe',
  'Light': 'Hell',
  'Dark': 'Dunkel',
  'SSH terminal': 'SSH-Terminal',
  'Language': 'Sprache',
  'General': 'Allgemein',
  'Privacy': 'Datenschutz',
  'Passwords': 'Passwörter',
  'Remembered passwords are encrypted and kept on this computer. An export includes them only if you choose to.':
      'Gespeicherte Passwörter werden verschlüsselt auf diesem Computer abgelegt. Ein Export enthält sie nur, wenn Sie das wählen.',
  'Applies to CommandS itself; sessions are not affected.':
      'Gilt nur für CommandS selbst; Sitzungen sind nicht betroffen.',
  'Connections': 'Verbindungen',
  'MCP integration': 'MCP-Integration',
  'Type or paste a path': 'Pfad eingeben oder einfügen',
  'Receive beta updates': 'Beta-Updates erhalten',
  'Betas are offered too, as they come out. A beta replaces this version, with the same connections and settings, and may have bugs.':
      'Betas werden ebenfalls angeboten, sobald sie erscheinen. Eine Beta ersetzt diese Version mit denselben Verbindungen und Einstellungen und kann Fehler enthalten.',
  'Expand': 'Vergrößern',
  'Shrink': 'Verkleinern',
  'Close SFTP files': 'SFTP-Dateien schließen',
  'Close SFTP': 'SFTP schließen',
  'Run this command?': 'Diesen Befehl ausführen?',
  'The connected agent wants to run this on {name} (shown to it as {alias}).':
      'Der verbundene Agent möchte dies auf {name} ausführen (für ihn als {alias} sichtbar).',
  'Its output will be sent to the agent.': 'Die Ausgabe wird an den Agenten gesendet.',
  'Do not run': 'Nicht ausführen',
  'Run': 'Ausführen',
  'Allowed connections': 'Erlaubte Verbindungen',
  'Tick the SSH connections an agent may use; a folder ticks everything in it. The agent sees the name, address, port and username of each connection, never its password. On network devices, show and display commands run at once; every other command asks you first. Terminal output is sent as it is.':
      'Haken Sie die SSH-Verbindungen an, die ein Agent nutzen darf; ein Ordner hakt alles darin an. Der Agent sieht Name, Adresse, Port und Benutzername jeder Verbindung, nie das Passwort. Auf Netzwerkgeräten laufen show- und display-Befehle sofort; bei jedem anderen Befehl werden Sie zuerst gefragt. Die Terminalausgabe wird unverändert gesendet.',
  'Search connections': 'Verbindungen durchsuchen',
  '{n} of {total} allowed': '{n} von {total} erlaubt',
  'No saved SSH connections yet.': 'Noch keine gespeicherten SSH-Verbindungen.',
  'No connection matches.': 'Keine passende Verbindung.',
  'Right-click a connection in the list to allow it. The agent sees the name, address, port and username of each connection, never its password. On network devices, show and display commands run at once; every other command asks you first. Terminal output is sent as it is.':
      'Klicken Sie in der Liste mit der rechten Maustaste auf eine Verbindung, um sie zu erlauben. Der Agent sieht Name, Adresse, Port und Benutzername jeder Verbindung, nie das Passwort. Auf Netzwerkgeräten laufen show- und display-Befehle sofort; bei jedem anderen Befehl werden Sie zuerst gefragt. Die Terminalausgabe wird unverändert gesendet.',
  'None yet.': 'Noch keine.',
  'Remove access': 'Zugriff entfernen',
  'Allow agent access': 'Agentenzugriff erlauben',
  'Remove agent access': 'Agentenzugriff entfernen',
  'Allow MCP access': 'MCP-Zugriff erlauben',
  'Lets a connected agent open saved SSH connections, send commands, and read terminal output.':
      'Erlaubt einem verbundenen Agenten, gespeicherte SSH-Verbindungen zu öffnen, Befehle zu senden und die Terminalausgabe zu lesen.',
  'MCP server URL': 'MCP-Server-URL',
  'New address': 'Neue Adresse',
  'Create a new address?': 'Neue Adresse erstellen?',
  'The current address stops working at once. Agents connected with it lose access until you give them the new one.':
      'Die aktuelle Adresse funktioniert sofort nicht mehr. Damit verbundene Agenten verlieren den Zugriff, bis Sie ihnen die neue geben.',
  'Use this URL directly in ChatGPT Work desktop, or point a Secure MCP Tunnel at it for hosted ChatGPT Work. Keep the URL private.':
      'Verwenden Sie diese URL direkt in ChatGPT Work Desktop, oder richten Sie für gehostetes ChatGPT Work einen Secure MCP Tunnel darauf. Halten Sie die URL geheim.',
  'Updates': 'Updates',
  'Support & feedback': 'Support & Feedback',
  'Found a problem, or have an idea? Write it here. Sending is anonymous: only your message, the app version and the operating system are sent.':
      'Ein Problem gefunden oder eine Idee? Schreiben Sie sie hier. Das Senden ist anonym: Nur Ihre Nachricht, die App-Version und das Betriebssystem werden gesendet.',
  'Your message': 'Ihre Nachricht',
  'Send': 'Senden',
  'Sent. Thank you!': 'Gesendet. Vielen Dank!',
  'Could not send. Check the internet connection and try again.':
      'Senden fehlgeschlagen. Prüfen Sie die Internetverbindung und versuchen Sie es erneut.',
  'Font': 'Schriftart',
  '{font} (default)': '{font} (Standard)',
  'Other font by name…': 'Andere Schriftart nach Name…',
  'Size': 'Größe',
  'Import theme': 'Design importieren',
  'Import theme…': 'Design importieren…',
  'A JSON file in the CommandS theme format.': 'Eine JSON-Datei im CommandS-Designformat.',
  'Theme imported: {name}': 'Design importiert: {name}',
  'Could not import the theme: {error}': 'Design konnte nicht importiert werden: {error}',
  'Could not read the theme file.': 'Designdatei konnte nicht gelesen werden.',
  'Remove theme': 'Design entfernen',
  'Keep my SSH terminal colours': 'Meine SSH-Terminalfarben behalten',
  'A theme then changes only the app, not the terminal colours you set.':
      'Ein Design ändert dann nur die App, nicht die von Ihnen festgelegten Terminalfarben.',
  // Theme file errors (lib/theme/theme_presets.dart).
  'A theme file is a JSON object.': 'Eine Designdatei ist ein JSON-Objekt.',
  'Not a CommandS theme: "format" must be "commands-theme".':
      'Kein CommandS-Design: "format" muss "commands-theme" sein.',
  'Unsupported theme version; this CommandS reads version 1.':
      'Nicht unterstützte Designversion; diese CommandS-Version liest Version 1.',
  'The theme needs a "name".': 'Das Design benötigt einen "name".',
  'The theme name must be 1 to 40 characters.': 'Der Designname muss 1 bis 40 Zeichen lang sein.',
  '"dark" must be true or false.': '"dark" muss true oder false sein.',
  'The theme needs a "ui" object.': 'Das Design benötigt ein "ui"-Objekt.',
  'The theme needs a "terminal" object.': 'Das Design benötigt ein "terminal"-Objekt.',
  '"terminal.ansi" must list exactly 16 colours.': '"terminal.ansi" muss genau 16 Farben enthalten.',
  'The theme file is too large.': 'Die Designdatei ist zu groß.',
  'The file is not valid JSON.': 'Die Datei ist kein gültiges JSON.',
  'Too many imported themes; remove one first.': 'Zu viele importierte Designs; entfernen Sie zuerst eines.',
  'Font name, as installed (e.g. JetBrains Mono)': 'Schriftname wie installiert (z. B. JetBrains Mono)',
  'Use': 'Verwenden',
  'A font that is not installed falls back to the default, so a typo shows straight away in the preview.':
      'Eine nicht installierte Schriftart fällt auf den Standard zurück, ein Tippfehler zeigt sich also sofort in der Vorschau.',
  'Background': 'Hintergrund',
  'Text': 'Text',
  'Color code': 'Farbcode',
  'Pick a color': 'Farbe wählen',
  '#1E1E1E or rgb(30, 30, 30)': '#1E1E1E oder rgb(30, 30, 30)',
  'Use #RRGGBB, #RGB or rgb(r, g, b)': 'Verwenden Sie #RRGGBB, #RGB oder rgb(r, g, b)',

  // ---- Updates ----
  'Release channel': 'Release-Kanal',
  'Stable': 'Stabil',
  'Beta': 'Beta',
  'A beta replaces this version, with the same connections and settings. It may have bugs; updates return you to the next normal release.':
      'Eine Beta ersetzt diese Version mit denselben Verbindungen und Einstellungen. Sie kann Fehler enthalten; Updates bringen Sie zur nächsten regulären Version zurück.',
  'Installed version': 'Installierte Version',
  'Check for updates': 'Nach Updates suchen',
  'Checking for updates…': 'Suche nach Updates…',
  'Could not reach GitHub to check for updates. Check the internet connection and try again.':
      'GitHub war für die Update-Suche nicht erreichbar. Prüfen Sie die Internetverbindung und versuchen Sie es erneut.',
  "You're up to date — {version} is the latest version.": 'Alles aktuell — {version} ist die neueste Version.',
  'CommandS {version} is available': 'CommandS {version} ist verfügbar',
  'CommandS Beta {version} is available': 'CommandS Beta {version} ist verfügbar',
  'Update to {version} now?': 'Jetzt auf {version} aktualisieren?',
  'Update to {version}': 'Auf {version} aktualisieren',
  'Yes, update': 'Ja, aktualisieren',
  'Update now': 'Jetzt aktualisieren',
  'Open download page': 'Downloadseite öffnen',
  'the update': 'das Update',
  'Downloading {version}…': '{version} wird heruntergeladen…',
  'Downloading {version}… {percent}%': '{version} wird heruntergeladen… {percent} %',
  'Downloading…': 'Wird heruntergeladen…',
  'Downloading… {percent}%': 'Wird heruntergeladen… {percent} %',
  'CommandS will close and reopen on the new version by itself.':
      'CommandS schließt sich und startet von selbst mit der neuen Version.',
  'You are running {version}.': 'Sie verwenden {version}.',
  'Download is {size}.': 'Download-Größe: {size}.',
  'Downloading opens the release page in your browser. Unzip the app and drag it to '
          'Applications, replacing the old one.':
      'Der Download öffnet die Release-Seite in Ihrem Browser. Entpacken Sie die App und ziehen Sie sie '
      'in „Programme“, um die alte zu ersetzen.',
  'Downloading opens the release page in your browser.': 'Der Download öffnet die Release-Seite in Ihrem Browser.',
  'You can still download it yourself from the release page.':
      'Sie können es weiterhin selbst von der Release-Seite herunterladen.',
  'Skip this version': 'Diese Version überspringen',
  'Yes': 'Ja',
  'No': 'Nein',
  'No password is saved for this connection, so you will need to type it.':
      'Für diese Verbindung ist kein Passwort gespeichert, Sie müssen es also eingeben.',
  'Remind me later': 'Später erinnern',
};

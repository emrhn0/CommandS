/// Turkish wording for the app's UI, keyed by the English text. Placeholders
/// in braces (`{n}`, `{name}` ...) are filled in after the lookup, so each
/// translation places them where Turkish grammar wants them.
const turkish = <String, String>{
  // ---- Common ----
  'Cancel': 'İptal',
  'Close': 'Kapat',
  'Save': 'Kaydet',
  'Delete': 'Sil',
  'Rename': 'Yeniden adlandır',
  'Create': 'Oluştur',
  'Apply': 'Uygula',
  'Name': 'Ad',
  'Folder': 'Klasör',
  'Host': 'Sunucu',
  'Port': 'Port',
  'Username': 'Kullanıcı adı',
  'Password': 'Şifre',
  'Domain': 'Etki alanı',
  'Optional': 'İsteğe bağlı',
  'Connect': 'Bağlan',
  'Settings': 'Ayarlar',
  'Back': 'Geri',
  'Try again': 'Tekrar dene',
  'Unknown error.': 'Bilinmeyen hata.',
  'Something went wrong.': 'Bir şeyler ters gitti.',

  // ---- Window ----
  'Minimize': 'Simge durumuna küçült',
  'Maximize': 'Ekranı kapla',
  'Restore': 'Önceki boyut',

  // ---- Sidebar / tree ----
  'New Connection': 'Yeni Bağlantı',
  'Filter connections': 'Bağlantılarda ara',
  'Select all': 'Tümünü seç',
  'New folder': 'Yeni klasör',
  'No matches': 'Eşleşme yok',
  'Move to folder': 'Klasöre taşı',
  'Clear selection': 'Seçimi temizle',
  'New connection here': 'Buraya yeni bağlantı',
  'Delete folder': 'Klasörü sil',
  'Edit…': 'Düzenle…',
  'Clone': 'Kopyala',
  'Move to folder…': 'Klasöre taşı…',
  'Open layout': 'Düzeni aç',
  'Delete layout': 'Düzeni sil',
  'Rename folder': 'Klasörü yeniden adlandır',
  'Rename connection': 'Bağlantıyı yeniden adlandır',
  'Rename layout': 'Düzeni yeniden adlandır',
  'Move layout to folder': 'Düzeni klasöre taşı',
  'Choose a folder': 'Klasör seç',
  'Layout': 'Düzen',
  '{n} connection': '{n} bağlantı',
  '{n} connections': '{n} bağlantı',
  '{n} folder': '{n} klasör',
  '{n} folders': '{n} klasör',
  ' and ': ' ve ',
  'Delete {what}?': '{what} silinsin mi?',
  'Delete "{name}"?': '"{name}" silinsin mi?',
  'This cannot be undone.': 'Bu işlem geri alınamaz.',
  "This cannot be undone. Deleted folders' contents are NOT deleted — they move to root, unfiled.": 'Bu işlem geri alınamaz. Silinen klasörlerin içindekiler SİLİNMEZ — klasörsüz olarak en üst düzeye taşınır.',
  'This folder is empty.': 'Bu klasör boş.',
  'It contains {n} item. It will NOT be deleted — it moves to the root, unfiled.':
      'İçinde {n} öğe var. Bu öğe SİLİNMEZ — klasörsüz olarak en üst düzeye taşınır.',
  'It contains {n} items. They will NOT be deleted — they move to the root, unfiled.':
      'İçinde {n} öğe var. Bu öğeler SİLİNMEZ — klasörsüz olarak en üst düzeye taşınır.',
  'Move {n} item to folder': '{n} öğeyi klasöre taşı',
  'Move {n} items to folder': '{n} öğeyi klasöre taşı',
  'None of the connections in "{name}" exist any more.': '"{name}" içindeki bağlantıların hiçbiri artık yok.',

  // ---- Session state ----
  'Connected': 'Bağlı',
  'Connecting': 'Bağlanıyor',
  'Disconnected': 'Bağlantı kesildi',
  'Session ended': 'Oturum sona erdi',
  'Ended': 'Sona erdi',

  // ---- Quick connect ----
  'Host or IP': 'Sunucu veya IP',
  'Quick connect with': 'Hızlı bağlantı türü',
  'Quick connect protocol': 'Hızlı bağlantı protokolü',

  // ---- Connection dialog ----
  'Edit Connection': 'Bağlantıyı Düzenle',
  'Save Connection': 'Bağlantıyı Kaydet',
  'Connection': 'Bağlantı',
  'Credentials': 'Kimlik bilgileri',
  'Remote desktop': 'Uzak masaüstü',
  'Defaults to the host': 'Boş bırakılırsa sunucu adresi',
  'Ask on connect': 'Bağlanırken sor',
  'Show password': 'Şifreyi göster',
  'Hide password': 'Şifreyi gizle',
  'Share clipboard': 'Panoyu paylaş',
  'Show wallpaper': 'Duvar kağıdını göster',
  'Save and Connect': 'Kaydet ve Bağlan',

  // ---- Tabs ----
  'No active session': 'Açık oturum yok',
  'Pick a saved connection on the left, use quick connect,\nor start a new one.':
      'Soldan kayıtlı bir bağlantı seçin, hızlı bağlantıyı kullanın\nya da yeni bir bağlantı oluşturun.',
  'Split view': 'Bölünmüş görünüm',
  'Open a second tab to split the view': 'Görünümü bölmek için ikinci bir sekme açın',
  'Save connection…': 'Bağlantıyı kaydet…',
  'Edit connection…': 'Bağlantıyı düzenle…',
  'Close tab': 'Sekmeyi kapat',

  // ---- RDP ----
  'Remote Desktop disconnected': 'Uzak Masaüstü bağlantısı kesildi',
  'The session could not be started.': 'Oturum başlatılamadı.',
  'The remote session was closed. Reconnect to start a new one.':
      'Uzak oturum kapatıldı. Yeni bir oturum için yeniden bağlanın.',
  'Reconnect': 'Yeniden bağlan',
  'Reconnect to fill the current pane size': 'Panelin boyutuna sığması için yeniden bağlan',
  'Send Ctrl+Alt+Del': 'Ctrl+Alt+Del gönder',
  'RDP session could not start': 'RDP oturumu başlatılamadı',
  'RDP session closed': 'RDP oturumu kapandı',
  'RDP session opened': 'RDP oturumu açıldı',
  'Open again': 'Yeniden aç',
  'Copied': 'Kopyalandı',
  'Copy password': 'Şifreyi kopyala',
  'the RDP client': 'RDP istemcisi',
  'The {client} window for {host} has closed. Open it again to reconnect.':
      '{host} için {client} penceresi kapandı. Yeniden bağlanmak için tekrar açın.',
  '{host} is open in {client}, in its own window, signed in with your saved credentials. '
          'macOS has no embeddable RDP component and does not let one app place another app’s window '
          'inside a tab, so the session cannot be drawn in here.':
      '{host}, {client} içinde kendi penceresinde, kayıtlı kimlik bilgilerinizle açıldı. macOS’ta '
      'gömülebilir bir RDP bileşeni yok ve bir uygulama başka bir uygulamanın penceresini sekmeye '
      'yerleştiremiyor; bu yüzden oturum burada gösterilemiyor.',
  '{host} is open in {client}, in its own window, with the host and username filled in — '
          '{client} keeps its own credential store, so the password is the one thing CommandS cannot '
          'hand it. Copy it below, or run "brew install freerdp" and CommandS will sign you in with '
          'no prompt at all.':
      '{host}, {client} içinde kendi penceresinde, sunucu ve kullanıcı adı doldurulmuş olarak açıldı — '
      '{client} kendi kimlik deposunu kullandığı için CommandS ona yalnızca şifreyi veremiyor. '
      'Şifreyi aşağıdan kopyalayın ya da "brew install freerdp" çalıştırın; CommandS sizi hiç '
      'sormadan oturuma alır.',
  '{host} is open in {client}, in its own window, with the host and username filled in.':
      '{host}, {client} içinde kendi penceresinde, sunucu ve kullanıcı adı doldurulmuş olarak açıldı.',

  // ---- Split view and layouts ----
  'Open tabs': 'Açık sekmeler',
  'Save as layout…': 'Düzen olarak kaydet…',
  'Save layout': 'Düzeni kaydet',
  'Drop here': 'Buraya bırakın',
  'Drop a tab here': 'Buraya bir sekme sürükleyin',
  'Empty this pane': 'Bu paneli boşalt',
  'the top level': 'en üst düzey',
  'Saved to {folder}. Open it from there any time to bring these sessions back like this.': '{folder} konumuna kaydedildi. Bu oturumları bu düzende geri getirmek için oradan istediğiniz zaman açın.',
  'Empty panes are left out. Click a tab to put it in the first empty pane.':
      'Boş paneller dahil edilmez. Bir sekmeye tıklayarak ilk boş panele yerleştirin.',
  '{n} pane holds a quick connection, which is not saved and cannot be reopened, so it is saved empty.': '{n} panelde hızlı bağlantı var; hızlı bağlantılar kayıtlı olmadığından yeniden açılamaz, bu panel boş kaydedilir.',
  '{n} panes hold quick connections, which are not saved and cannot be reopened, so they are saved empty.': '{n} panelde hızlı bağlantı var; hızlı bağlantılar kayıtlı olmadığından yeniden açılamaz, bu paneller boş kaydedilir.',
  'Single': 'Tek',
  'Side by side': 'Yan yana',
  'Stacked': 'Üst üste',
  'One + two': 'Bir + iki',
  'Three columns': 'Üç sütun',
  'Grid': 'Izgara',

  // ---- Folder picker / selection ----
  'No folder (top level)': 'Klasör yok (en üst düzey)',
  'Search folders': 'Klasörlerde ara',
  'No folder matches.': 'Eşleşen klasör yok.',
  '{n} of {total} selected': '{total} bağlantıdan {n} tanesi seçili',
  'Nothing to show': 'Gösterilecek bir şey yok',
  'Password will be included': 'Şifre dahil edilecek',
  'Password will be excluded': 'Şifre dahil edilmeyecek',
  'Confirm ({n})': 'Onayla ({n})',

  // ---- Import / export ----
  'Import connections': 'Bağlantıları içe aktar',
  'Export connections': 'Bağlantıları dışa aktar',
  'Import from Remote Desktop Manager': 'Remote Desktop Manager’dan içe aktar',
  'From a CommandS export (JSON, XML or CSV), or a Remote Desktop Manager export.':
      'Bir CommandS dışa aktarımından (JSON, XML veya CSV) ya da Remote Desktop Manager dışa aktarımından.',
  'Save some or all of your connections as JSON, XML or CSV.':
      'Bağlantılarınızın bir kısmını ya da tamamını JSON, XML veya CSV olarak kaydedin.',
  'Import…': 'İçe aktar…',
  'Export…': 'Dışa aktar…',
  'No connections to export yet.': 'Henüz dışa aktarılacak bağlantı yok.',
  'Export format': 'Dışa aktarma biçimi',
  'Everything, for importing into CommandS again': 'Her şey, CommandS’e yeniden aktarmak için',
  'Folders and connections': 'Klasörler ve bağlantılar',
  'One row per connection': 'Her bağlantı bir satır',
  'Export CommandS connections': 'CommandS bağlantılarını dışa aktar',
  'Exported to {path}': '{path} konumuna aktarıldı',
  'Import connections (CommandS JSON/XML/CSV or Remote Desktop Manager JSON)':
      'Bağlantıları içe aktar (CommandS JSON/XML/CSV veya Remote Desktop Manager JSON)',
  "This XML doesn't look like a CommandS export (no <Connection>/<Folder> elements found). "
          "CommandS's own XML import only round-trips its own export — for Remote Desktop Manager, "
          'export as JSON instead, or as CSV if you need passwords included.':
      'Bu XML bir CommandS dışa aktarımına benzemiyor (<Connection>/<Folder> öğesi bulunamadı). '
      'CommandS’in XML içe aktarımı yalnızca kendi dışa aktarımını okur — Remote Desktop Manager için '
      'JSON olarak, şifreler de gerekiyorsa CSV olarak dışa aktarın.',
  'Imported {n} connection(s)': '{n} bağlantı içe aktarıldı',
  '{n} skipped (unsupported type)': '{n} tanesi atlandı (desteklenmeyen tür)',
  "{n} password(s) are AES-encrypted by RDM's own vault and can't be decrypted from this file "
          '(true for JSON or XML alike) — re-enter them, or export from RDM as CSV/spreadsheet with '
          'credentials revealed and import that instead':
      '{n} şifre RDM’nin kendi kasasıyla AES ile şifrelenmiş ve bu dosyadan çözülemiyor (JSON ve XML için '
      'aynı) — şifreleri yeniden girin ya da RDM’den kimlik bilgileri açık olacak şekilde CSV/tablo '
      'olarak dışa aktarıp onu içe aktarın',
  'Import failed: {error}': 'İçe aktarma başarısız: {error}',

  // ---- Settings ----
  'Appearance': 'Görünüm',
  'Theme': 'Tema',
  'Light': 'Açık',
  'Dark': 'Koyu',
  'SSH terminal': 'SSH terminali',
  'Language': 'Dil',
  'Applies to CommandS itself; sessions are not affected.':
      'Yalnızca CommandS’in kendi arayüzünü değiştirir; oturumlar etkilenmez.',
  'Connections': 'Bağlantılar',
  'Updates': 'Güncellemeler',
  'Font': 'Yazı tipi',
  '{font} (default)': '{font} (varsayılan)',
  'Other font by name…': 'Adıyla başka bir yazı tipi…',
  'Size: {n} pt': 'Boyut: {n} pt',
  'Font name, as installed (e.g. JetBrains Mono)': 'Yüklü yazı tipinin adı (ör. JetBrains Mono)',
  'Use': 'Kullan',
  'A font that is not installed falls back to the default, so a typo shows straight away in the preview.':
      'Yüklü olmayan bir yazı tipi varsayılana döner; yazım hatası önizlemede hemen görünür.',
  'Background': 'Arka plan',
  'Text': 'Yazı',
  'Color code': 'Renk kodu',
  '#1E1E1E or rgb(30, 30, 30)': '#1E1E1E veya rgb(30, 30, 30)',
  'Use #RRGGBB, #RGB or rgb(r, g, b)': '#RRGGBB, #RGB veya rgb(r, g, b) kullanın',

  // ---- Updates ----
  'Installed version': 'Yüklü sürüm',
  'Check for updates': 'Güncellemeleri denetle',
  'Checking for updates…': 'Güncellemeler denetleniyor…',
  'Could not reach GitHub to check for updates. Check the internet connection and try again.': 'Güncellemeleri denetlemek için GitHub’a ulaşılamadı. İnternet bağlantısını kontrol edip tekrar deneyin.',
  "You're up to date — {version} is the latest version.": 'Güncelsiniz — {version} en son sürüm.',
  'CommandS {version} is available': 'CommandS {version} yayında',
  'Update to {version} now?': 'Şimdi {version} sürümüne güncellensin mi?',
  'Update to {version}': '{version} sürümüne güncelle',
  'Yes, update': 'Evet, güncelle',
  'Update now': 'Şimdi güncelle',
  'Open download page': 'İndirme sayfasını aç',
  'the update': 'güncelleme',
  'Downloading {version}…': '{version} indiriliyor…',
  'Downloading {version}… {percent}%': '{version} indiriliyor… %{percent}',
  'Downloading…': 'İndiriliyor…',
  'Downloading… {percent}%': 'İndiriliyor… %{percent}',
  'CommandS will close and reopen on the new version by itself.':
      'CommandS kapanıp yeni sürümle kendiliğinden yeniden açılacak.',
  'You are running {version}.': 'Kullandığınız sürüm: {version}.',
  'Download is {size}.': 'İndirme boyutu: {size}.',
  'Downloading opens the release page in your browser. Unzip the app and drag it to '
          'Applications, replacing the old one.':
      'İndirme, sürüm sayfasını tarayıcınızda açar. Uygulamayı zip’ten çıkarıp eskisinin yerine '
      'Uygulamalar klasörüne sürükleyin.',
  'Downloading opens the release page in your browser.': 'İndirme, sürüm sayfasını tarayıcınızda açar.',
  'You can still download it yourself from the release page.':
      'Yine de sürüm sayfasından kendiniz indirebilirsiniz.',
  'Skip this version': 'Bu sürümü atla',
  'Remind me later': 'Daha sonra hatırlat',
};

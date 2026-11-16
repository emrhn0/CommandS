/// Compares names in Turkish alphabetical order, ignoring case:
/// a b c ç d e f g ğ h ı i j k l m n o ö p q r s ş t u ü v w x y z.
///
/// Dart's own `compareTo` orders by code unit, which puts ç, ğ, ı, ö, ş and
/// ü after z, and lower-cases I to i rather than ı.
int compareTurkish(String a, String b) {
  final ka = _key(a), kb = _key(b);
  final n = ka.length < kb.length ? ka.length : kb.length;
  for (var i = 0; i < n; i++) {
    final d = ka[i] - kb[i];
    if (d != 0) return d;
  }
  final byLength = ka.length - kb.length;
  // Same letters: a fixed order anyway, so sorting is stable to the eye.
  return byLength != 0 ? byLength : a.compareTo(b);
}

const _alphabet = 'abcçdefgğhıijklmnoöpqrsştuüvwxyz';

List<int> _key(String s) {
  final out = <int>[];
  for (final rune in s.runes) {
    var ch = String.fromCharCode(rune);
    // Turkish casing: I is the capital of ı, İ the capital of i.
    if (ch == 'I') {
      ch = 'ı';
    } else if (ch == 'İ') {
      ch = 'i';
    } else {
      ch = ch.toLowerCase();
    }
    final letter = _alphabet.indexOf(ch);
    if (letter >= 0) {
      out.add(0x10000 + letter);
    } else if (rune < 0x80) {
      // Digits, spaces and punctuation before letters, as usual.
      out.add(rune);
    } else {
      // Other scripts after the Turkish letters, by code point.
      out.add(0x20000 + rune);
    }
  }
  return out;
}

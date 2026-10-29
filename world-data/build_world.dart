// Dünya konum verisini üretir (ROADMAP J1, küresel GPS) → assets/world/ ve
// lib/domain/location/world_countries.g.dart.
//
// Kaynaklar (lisansları Lisanslar sayfasında ve site/world-data/README.md'de):
// - Şehirler: GeoNames cities15000 (nüfusu 15.000+), CC BY 4.0.
//   Türkiye satırları alınmaz: Türkiye'de 973 ilçelik kendi listemiz (Diyanet'e
//   göre kalibre) kullanılır. Her şehrin saat dilimi aşağıdaki çokgenlerden
//   (şehrin koordinatında) hesaplanır; GeoNames'in kendi alanı yalnızca
//   çokgen bulunamazsa (kıyı) yedek.
// - Saat dilimi sınırları: timezone-boundary-builder "timezones" (tam kimlikli
//   sürüm, birleştirilmemiş), OpenStreetMap verisinden, ODbL 1.0. Douglas-Peucker
//   ile ~1 km (0,01°) sadeleştirilir, 0,001°'ye yuvarlanır. Sonuç türetilmiş bir
//   veritabanıdır ve ODbL ile yayımlanır (qalbora-site: world-data/).
// - Ülke adları (TR/EN): Unicode CLDR, Unicode License v3.
//
// Saat dilimi kimlikleri IANA adıyla saklanır (ör. Europe/Oslo). Uygulama
// `timezone` paketinin küçük verisini (latest_10y) yükler; orada tzdb'nin
// "link" kimlikleri yok (Europe/Oslo, Europe/Berlin'in eşi). Bunlar için
// 1970-2040 arasında saat kuralları birebir aynı olan bölge bulunur ve
// lib/domain/location/world_time_zones.g.dart'a yazılır; hesapta o kullanılır.
// Eşdeğeri bulunamayan kimlik varsa araç durur.
//
// Kullanım (proje kökünde): dart run tool/build_world.dart <önbellek-klasörü>
// Önbellekte dosya varsa yeniden indirilmez. Çıktılar üzerine yazılır.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/data/latest_all.dart' as tzall;
import 'package:timezone/timezone.dart' as tz;

const tzRelease = '2026e';
const cldrVersion = '49.0.0';
const _downloads = {
  'cities15000.zip': 'https://download.geonames.org/export/dump/cities15000.zip',
  'timezones.geojson.zip':
      'https://github.com/evansiroky/timezone-boundary-builder/releases/download/$tzRelease/timezones.geojson.zip',
  'territories_tr.json':
      'https://raw.githubusercontent.com/unicode-org/cldr-json/$cldrVersion/cldr-json/cldr-localenames-full/main/tr/territories.json',
  'territories_en.json':
      'https://raw.githubusercontent.com/unicode-org/cldr-json/$cldrVersion/cldr-json/cldr-localenames-full/main/en/territories.json',
};

/// Sadeleştirme toleransı ve koordinat adımı (derece).
const tolerance = 0.01, quantum = 0.001;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Kullanım: dart run tool/build_world.dart <önbellek-klasörü>');
    exit(64);
  }
  final cache = Directory(args.first)..createSync(recursive: true);
  for (final MapEntry(key: name, value: url) in _downloads.entries) {
    final f = File('${cache.path}/$name');
    if (f.existsSync()) continue;
    stdout.writeln('İndiriliyor: $url');
    final r = await Process.run('curl', ['-sSL', '-m', '900', '-o', f.path, url]);
    if (r.exitCode != 0 || !f.existsSync()) throw StateError('İndirilemedi: $url ${r.stderr}');
  }
  for (final (zip, inner) in [('cities15000.zip', 'cities15000.txt'), ('timezones.geojson.zip', 'combined.json')]) {
    if (File('${cache.path}/$inner').existsSync()) continue;
    final r = await Process.run('tar', ['-xf', '${cache.path}/$zip', '-C', cache.path]);
    if (r.exitCode != 0) throw StateError('Açılamadı: $zip ${r.stderr}');
  }

  tzdata.initializeTimeZones();
  final small = Map.of(tz.timeZoneDatabase.locations);
  tzall.initializeTimeZones();
  final everything = Map.of(tz.timeZoneDatabase.locations);
  final known = everything.keys.toSet();

  // --- Saat dilimi çokgenleri ---
  stdout.writeln('Çokgenler okunuyor…');
  final geo = jsonDecode(File('${cache.path}/combined.json').readAsStringSync()) as Map<String, Object?>;
  final features = (geo['features']! as List).cast<Map<String, Object?>>();
  final full = <_Poly>[], simple = <_Poly>[];
  final zones = <String>[];
  final missing = <String>{};
  for (final f in features) {
    final id = (f['properties']! as Map)['tzid'] as String;
    if (!known.contains(id)) missing.add(id);
    final zi = zones.length;
    zones.add(id);
    final g = f['geometry']! as Map<String, Object?>;
    final polys = g['type'] == 'Polygon' ? [g['coordinates']! as List] : (g['coordinates']! as List).cast<List>();
    for (final p in polys) {
      final rings = [for (final r in p.cast<List>()) _ring(r)];
      full.add(_Poly(zi, rings));
      final s = [
        for (final r in rings)
          if (_simplify(r, tolerance) case final q when q.length >= 8) _quantize(q, quantum),
      ];
      if (s.isNotEmpty) simple.add(_Poly(zi, s));
    }
  }
  if (missing.isNotEmpty) {
    stderr.writeln('timezone paketinde hiç olmayan kimlikler: ${missing.join(', ')}');
    exit(1);
  }
  final tzBytes = _encodePolygons(zones, simple);
  Directory('assets/world').createSync(recursive: true);
  File('assets/world/timezones.bin').writeAsBytesSync(tzBytes);
  stdout.writeln('Saat dilimi: ${zones.length} kimlik, ${simple.length} çokgen, '
      '${(tzBytes.length / 1024).toStringAsFixed(0)} KB');

  // --- Şehirler ---
  stdout.writeln('Şehirler okunuyor…');
  final rows = <_City>[];
  var fromGeoNamesTz = 0;
  for (final line in File('${cache.path}/cities15000.txt').readAsLinesSync()) {
    final c = line.split('\t');
    if (c.length < 18 || c[8] == 'TR') continue;
    final lat = double.parse(c[4]), lon = double.parse(c[5]);
    var zone = _lookup(full, zones, lat, lon);
    if (zone == null) {
      // Kıyıda, çokgenin dışında kalan şehir: GeoNames'in kendi alanı.
      if (!known.contains(c[17])) throw StateError('Saat dilimi bulunamadı: ${c[1]} ${c[17]}');
      zone = c[17];
      fromGeoNamesTz++;
    }
    rows.add(_City(int.parse(c[0]), c[1], c[2], c[8], c[10], lat, lon, int.tryParse(c[14]) ?? 0, zone));
  }
  rows.sort((a, b) => a.cc != b.cc ? a.cc.compareTo(b.cc) : a.id.compareTo(b.id));
  final cityZones = {for (final r in rows) r.tz}.toList()..sort();
  // Biçim (lib/domain/location/world_cities.dart okur): "#" açıklama, "#tz"
  // saat dilimi tablosu, "@XX" ülke başlığı; altında o ülkenin şehirleri,
  // GeoNames kimliğine göre artan. Satır: kimlik farkı (öncekiyle; ülkenin
  // ilkinde kimliğin kendisi), ad, ASCII ad (adla aynıysa boş), bölge (admin1)
  // kodu, enlem, boylam (3 hane, ~110 m), nüfus (bin), saat dilimi sırası.
  final out = StringBuffer()
    ..writeln('# Qalbora dünya şehirleri: GeoNames cities15000 (CC BY 4.0, Türkiye hariç); '
        'saat dilimi: timezone-boundary-builder $tzRelease (ODbL 1.0). tool/build_world.dart')
    ..writeln('# @ülke; kimlik farkı, ad, ascii ad, bölge, enlem, boylam, nüfus (bin), saat dilimi sırası')
    ..writeln('#tz\t${cityZones.join('\t')}');
  var country = '';
  var prevId = 0;
  for (final r in rows) {
    if (r.cc != country) {
      country = r.cc;
      prevId = 0;
      out.writeln('@$country');
    }
    out.writeln([
      r.id - prevId, r.name, r.ascii == r.name ? '' : r.ascii, r.admin1,
      r.lat.toStringAsFixed(3), r.lon.toStringAsFixed(3), (r.population / 1000).round(),
      cityZones.indexOf(r.tz),
    ].join('\t'));
    prevId = r.id;
  }
  File('assets/world/cities.tsv').writeAsStringSync(out.toString());
  stdout.writeln('Şehirler: ${rows.length} (saat dilimi GeoNames yedeğinden: $fromGeoNamesTz), '
      '${(out.length / 1024).toStringAsFixed(0)} KB');

  // --- Link kimlikleri → küçük verideki eşdeğer bölge ---
  final used = {...zones, ...cityZones};
  final aliases = <String, String>{};
  for (final id in used.where((z) => !small.containsKey(z)).toList()..sort()) {
    final target = _equivalent(everything[id]!, small.keys, everything);
    if (target == null) throw StateError('Eşdeğer bölge yok: $id');
    aliases[id] = target;
  }
  final aliasDart = StringBuffer()
    ..writeln('// Üretildi: tool/build_world.dart — elle değiştirmeyin.')
    ..writeln('//')
    ..writeln('// tzdb link kimlikleri → uygulamanın yüklediği saat dilimi verisindeki (latest_10y)')
    ..writeln('// eşdeğer bölge: 1970-2040 arasında saat kuralları birebir aynı. Kimlik IANA')
    ..writeln('// adıyla saklanır ve gösterilir; hesap eşdeğer bölgeyle yapılır.')
    ..writeln('const timeZoneAliases = <String, String>{');
  for (final MapEntry(:key, :value) in aliases.entries) {
    aliasDart.writeln("  '$key': '$value',");
  }
  aliasDart.writeln('};');
  File('lib/domain/location/world_time_zones.g.dart').writeAsStringSync(aliasDart.toString());
  stdout.writeln('Link kimlikleri: ${aliases.length} (${aliases.entries.take(6).map((e) => '${e.key}→${e.value}').join(', ')} …)');

  // --- Ülke adları (CLDR) ---
  Map<String, String> names(String lang) {
    final j = jsonDecode(File('${cache.path}/territories_$lang.json').readAsStringSync()) as Map<String, Object?>;
    final t = (((j['main']! as Map)[lang]! as Map)['localeDisplayNames']! as Map)['territories']! as Map;
    return t.cast<String, String>();
  }
  final trNames = names('tr'), enNames = names('en');
  final codes = {for (final r in rows) r.cc}.toList()..sort();
  final dart = StringBuffer()
    ..writeln('// Üretildi: tool/build_world.dart — elle değiştirmeyin.')
    ..writeln('// Ülke adları: Unicode CLDR $cldrVersion (Unicode License v3).')
    ..writeln()
    ..writeln('/// Ülke kodu → (Türkçe, İngilizce) ad; dünya şehirlerinde geçen ülkeler.')
    ..writeln('const worldCountryNames = <String, (String, String)>{');
  for (final cc in codes) {
    final tr = trNames[cc], en = enNames[cc];
    if (tr == null || en == null) throw StateError('CLDR adı yok: $cc');
    dart.writeln("  '$cc': (${_dartString(tr)}, ${_dartString(en)}),");
  }
  dart.writeln('};');
  File('lib/domain/location/world_countries.g.dart').writeAsStringSync(dart.toString());
  stdout.writeln('Ülkeler: ${codes.length}');

  // ODbL 4.6: türetilmiş veritabanı ve üretim yöntemi herkese açık sunulur
  // (qalbora-site/world-data/; test, uygulamadakilerle aynı olduğunu denetler).
  Directory('site/world-data').createSync(recursive: true);
  File('assets/world/timezones.bin').copySync('site/world-data/timezones.bin');
  File('assets/world/cities.tsv').copySync('site/world-data/cities.tsv');
  File('tool/build_world.dart').copySync('site/world-data/build_world.dart');
  stdout.writeln('site/world-data/ güncellendi (qalbora-site reposuna da kopyalanmalı).');
}

String _dartString(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

class _City {
  _City(this.id, this.name, this.ascii, this.cc, this.admin1, this.lat, this.lon, this.population, this.tz);
  final int id;
  final String name, ascii, cc, admin1;
  final double lat, lon;
  final int population;
  final String tz;
}

/// Halka: düz [x0, y0, x1, y1, …] (boylam, enlem).
Float64List _ring(List r) {
  final out = Float64List(r.length * 2);
  for (var i = 0; i < r.length; i++) {
    final p = r[i] as List;
    out[i * 2] = (p[0] as num).toDouble();
    out[i * 2 + 1] = (p[1] as num).toDouble();
  }
  return out;
}

class _Poly {
  _Poly(this.zone, this.rings)
      : minX = _min(rings.first, 0), minY = _min(rings.first, 1),
        maxX = _max(rings.first, 0), maxY = _max(rings.first, 1);
  final int zone;
  final List<Float64List> rings;
  final double minX, minY, maxX, maxY;
  static double _min(Float64List r, int o) { var m = double.infinity; for (var i = o; i < r.length; i += 2) { m = min(m, r[i]); } return m; }
  static double _max(Float64List r, int o) { var m = -double.infinity; for (var i = o; i < r.length; i += 2) { m = max(m, r[i]); } return m; }
}

bool _inRing(Float64List r, double x, double y) {
  var inside = false;
  final n = r.length ~/ 2;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final xi = r[i * 2], yi = r[i * 2 + 1], xj = r[j * 2], yj = r[j * 2 + 1];
    if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

String? _lookup(List<_Poly> polys, List<String> zones, double lat, double lon) {
  for (final p in polys) {
    if (lon < p.minX || lon > p.maxX || lat < p.minY || lat > p.maxY) continue;
    if (!_inRing(p.rings.first, lon, lat)) continue;
    if (p.rings.skip(1).any((h) => _inRing(h, lon, lat))) continue;
    return zones[p.zone];
  }
  return null;
}

/// Kapalı halkayı ikiye bölüp Douglas-Peucker (başı ve sonu aynı nokta).
Float64List _simplify(Float64List r, double tol) {
  final n = r.length ~/ 2;
  if (n < 5) return r;
  final keep = Uint8List(n)..[0] = 1..[n - 1] = 1..[n ~/ 2] = 1;
  void dp(int s, int e) {
    final stack = [s, e];
    while (stack.isNotEmpty) {
      final b = stack.removeLast(), a = stack.removeLast();
      final x1 = r[a * 2], y1 = r[a * 2 + 1], x2 = r[b * 2], y2 = r[b * 2 + 1];
      final dx = x2 - x1, dy = y2 - y1;
      final len = sqrt(dx * dx + dy * dy);
      var best = -1;
      var bd = tol;
      for (var i = a + 1; i < b; i++) {
        final x = r[i * 2], y = r[i * 2 + 1];
        final d = len == 0 ? sqrt((x - x1) * (x - x1) + (y - y1) * (y - y1)) : (dy * x - dx * y + x2 * y1 - y2 * x1).abs() / len;
        if (d > bd) { bd = d; best = i; }
      }
      if (best > 0) { keep[best] = 1; stack..addAll([a, best])..addAll([best, b]); }
    }
  }
  dp(0, n ~/ 2);
  dp(n ~/ 2, n - 1);
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    if (keep[i] == 1) out..add(r[i * 2])..add(r[i * 2 + 1]);
  }
  return Float64List.fromList(out);
}

/// 0,001° adımına yuvarlar; art arda aynı noktaları atar.
Float64List _quantize(Float64List r, double q) {
  final out = <double>[];
  for (var i = 0; i < r.length; i += 2) {
    final x = (r[i] / q).round() * q, y = (r[i + 1] / q).round() * q;
    if (out.length >= 2 && out[out.length - 2] == x && out[out.length - 1] == y) continue;
    out..add(x)..add(y);
  }
  return Float64List.fromList(out);
}

/// İkili biçim (lib/domain/location/time_zone_polygons.dart okur):
/// "QTZ1", kimlik sayısı, kimlikler (uzunluk + UTF-8), çokgen sayısı; her
/// çokgen: kimlik sırası, halka sayısı; her halka: nokta sayısı, 0,001° birimli
/// fark kodlu (zigzag varint) boylam/enlem çiftleri.
Uint8List _encodePolygons(List<String> zones, List<_Poly> polys) {
  final b = BytesBuilder();
  void varint(int v) {
    while (v >= 0x80) {
      b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    b.addByte(v);
  }
  void zigzag(int v) => varint(v >= 0 ? v * 2 : -v * 2 - 1);
  b.add(ascii.encode('QTZ1'));
  varint(zones.length);
  for (final z in zones) {
    final u = utf8.encode(z);
    varint(u.length);
    b.add(u);
  }
  varint(polys.length);
  for (final p in polys) {
    varint(p.zone);
    varint(p.rings.length);
    for (final r in p.rings) {
      varint(r.length ~/ 2);
      var px = 0, py = 0;
      for (var i = 0; i < r.length; i += 2) {
        final x = (r[i] / quantum).round(), y = (r[i + 1] / quantum).round();
        zigzag(x - px);
        zigzag(y - py);
        px = x;
        py = y;
      }
    }
  }
  return b.toBytes();
}

/// [link] ile 1970-2040 arasında her 15 günde ve her yaz saati geçişinin iki
/// yanında aynı ofseti veren, küçük veride de bulunan bölge (karşılaştırma tam
/// veriyle: küçük veri yalnızca son yılları taşır). Önce aynı bölge önekindeki
/// (Europe/…) adaylar. 1970'ten beri eşi yoksa 2010'dan beri eşi aranır.
String? _equivalent(tz.Location link, Iterable<String> smallNames, Map<String, tz.Location> full) {
  final region = link.name.split('/').first;
  final candidates = smallNames.toList()
    ..sort((a, b) {
      final ra = a.startsWith('$region/') ? 0 : 1, rb = b.startsWith('$region/') ? 0 : 1;
      return ra != rb ? ra - rb : a.compareTo(b);
    });
  for (final from in [1970, 2010]) {
    final start = DateTime.utc(from).millisecondsSinceEpoch, end = DateTime.utc(2040).millisecondsSinceEpoch;
    final samples = <int>[
      for (var t = start; t < end; t += 15 * 24 * 3600 * 1000) t,
      for (final t in link.transitionAt)
        if (t >= start && t < end) ...[t - 3600000, t + 3600000],
    ];
    for (final name in candidates) {
      final c = full[name]!;
      if (samples.every((t) => c.timeZone(t).offset == link.timeZone(t).offset)) {
        if (from != 1970) stdout.writeln('  ${link.name}: 1970\'ten beri eşi yok, 2010\'dan beri $name');
        return name;
      }
    }
  }
  return null;
}

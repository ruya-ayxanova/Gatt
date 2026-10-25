import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as m;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, HapticFeedback;
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

List<String> names = ['صبح اذانی', 'گون دوغومو', 'ناهار اذانی', 'ایکیندی اذانی', 'گون باتومی', 'آخشام اذانی', 'گجه اذانی', 'گجه یاریسی'];
List<int> adhanIdx = [0, 2, 3, 5, 6]; // ezan çalınacak vakitler
final plugin = FlutterLocalNotificationsPlugin();
NotificationDetails adhanDetails(String res, [String? big]) => NotificationDetails(
      android: AndroidNotificationDetails('azan_$res', 'Ezan ($res)',
          channelDescription: 'Ezan vakitleri',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound(res),
          audioAttributesUsage: AudioAttributesUsage.alarm,
          styleInformation: big == null ? null : BigTextStyleInformation(big)),
    );
NotificationDetails remindDetails([String? big]) => NotificationDetails(
      android: AndroidNotificationDetails('hatirlatma', 'Ezan öncesi uyarı',
          channelDescription: 'Ezandan önce hatırlatma',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: big == null ? null : BigTextStyleInformation(big)),
    );

class Method {
  final String name;
  final double fajr, maghrib, isha;
  const Method(this.name, this.fajr, this.maghrib, this.isha);
}

const methods = [
  Method('Tahran Üniversitesi Jeofizik Enstitüsü (Sedaa ve Sima)', 17.7, 4.5, 14),
  Method('Caferi (Leva Araştırma Enstitüsü, Kum)', 16, 4, 14),
  Method('Diyanet (Türkiye)', 18, .833, 17),
  Method('Müslüman Dünya Ligi', 18, .833, 17),
];
int methodIdx = 0, remindMin = 10;
List<int> remindIdx = [];
Map<int, String> snd = {}; // vakit -> müezzin (ses kaynağı adı)
List<List<String>> muez = []; // [kaynak adı, görünen ad]
String defSound() => muez.any((e) => e[0] == 'azan') ? 'azan' : (muez.isNotEmpty ? muez.first[0] : 'azan');

Future<void> saveAdhanPrefs() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setInt('method', methodIdx);
    await p.setInt('rmin', remindMin);
    await p.setInt('ladj', lunarAdj);
    await p.setStringList('remind', remindIdx.map((e) => e.toString()).toList());
    await p.setString('vol', jsonEncode(vol.map((k, v) => MapEntry(k.toString(), v))));
    await p.setStringList('adhan', adhanIdx.map((e) => e.toString()).toList());
    await p.setString('snd', jsonEncode(snd.map((k, v) => MapEntry(k.toString(), v))));
  } catch (_) {}
}

class City {
  final String group, name;
  final double lat, lng;
  City(this.group, this.name, this.lat, this.lng);
}

double fix(double a, double b) => a - b * (a / b).floorToDouble();
double rad(double d) => d * m.pi / 180;
double deg(double r) => r * 180 / m.pi;

// Tahran Üniversitesi yöntemi: sabah 17,7°, akşam 4,5°, yatsı 14°
List<double> calc(DateTime date, double lat, double lng) {
  final off = DateTime(date.year, date.month, date.day, 12).timeZoneOffset.inMinutes / 60;
  final d = DateTime.utc(date.year, date.month, date.day, 12).millisecondsSinceEpoch / 86400000.0 + 2440587.5 - 2451545;
  final g = fix(357.529 + .98560028 * d, 360), q = fix(280.459 + .98564736 * d, 360);
  final l = fix(q + 1.915 * m.sin(rad(g)) + .02 * m.sin(rad(2 * g)), 360), e = 23.439 - 3.6e-7 * d;
  final ra = fix(deg(m.atan2(m.cos(rad(e)) * m.sin(rad(l)), m.cos(rad(l)))) / 15, 24);
  final dec = deg(m.asin(m.sin(rad(e)) * m.sin(rad(l))));
  final eq = fix(q / 15 - ra + 12, 24) - 12, noon = 12 + off - lng / 15 - eq;
  double t(double a) => deg(m.acos((-m.sin(rad(a)) - m.sin(rad(dec)) * m.sin(rad(lat))) / (m.cos(rad(dec)) * m.cos(rad(lat))))) / 15;
  final asr = -deg(m.atan(1 / (1 + m.tan(rad((lat - dec).abs())))));
  final mt = methods[methodIdx];
  final f = noon - t(mt.fajr), ss = noon + t(.833);
  return [f, noon - t(.833), noon, noon + t(asr), ss, noon + t(mt.maghrib), noon + t(mt.isha), ss + (f + 24 - ss) / 2];
}

String fmt(double h) {
  if (h.isNaN) return '--:--';
  final mm = (fix(h, 24) * 60).round() % 1440;
  return '${(mm ~/ 60).toString().padLeft(2, '0')}:${(mm % 60).toString().padLeft(2, '0')}';
}

List<String> mg = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
List<String> mj = ['آغلار گولر', 'گولن آی', 'قیزاران آی', 'قورا بیشیرن', 'قویروق دوغان', 'زومار آیی', 'خزل آیی', 'قیروو آیی', 'آذر', 'چیلله', 'دوندوران آی', 'بایرام آیی'];
List<String> dn = ['دوز گونو', 'آرا گون', 'اود گونو', 'سو گونو', 'آینی گونو', 'یئل لی گون', 'سود گونو']; // Pazartesi'den başlar

const br = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178];

List<int> jalCal(int jy) {
  final gy = jy + 621;
  var leapJ = -14, jp = br[0], jump = 0, jm = 0;
  for (var i = 1; i < br.length; i++) {
    jm = br[i];
    jump = jm - jp;
    if (jy < jm) break;
    leapJ += (jump ~/ 33) * 8 + (jump % 33) ~/ 4;
    jp = jm;
  }
  var n = jy - jp;
  leapJ += (n ~/ 33) * 8 + ((n % 33) + 3) ~/ 4;
  if (jump % 33 == 4 && jump - n == 4) leapJ += 1;
  final leapG = (gy ~/ 4) - ((((gy ~/ 100) + 1) * 3) ~/ 4) - 150;
  final march = 20 + leapJ - leapG;
  if (jump - n < 6) n = n - jump + ((jump + 4) ~/ 33) * 33;
  final leap = (((n + 1) % 33) - 1) % 4;
  return [leap, gy, march];
}

int g2d(int gy, int gm, int gd) {
  final d = (((gy + (gm - 8) ~/ 6 + 100100) * 1461) ~/ 4) + ((153 * ((gm + 9) % 12) + 2) ~/ 5) + gd - 34840408;
  return d - ((((gy + 100100 + (gm - 8) ~/ 6) ~/ 100) * 3) ~/ 4) + 752;
}

List<int> d2g(int jdn) {
  var j = 4 * jdn + 139361631;
  j += ((((4 * jdn + 183187720) ~/ 146097) * 3) ~/ 4) * 4 - 3908;
  final i = ((j % 1461) ~/ 4) * 5 + 308;
  final gd = (i % 153) ~/ 5 + 1, gm = (i ~/ 153) % 12 + 1;
  return [j ~/ 1461 - 100100 + (8 - gm) ~/ 6, gm, gd];
}

int j2d(int jy, int jm, int jd) {
  final r = jalCal(jy);
  return g2d(r[1], 3, r[2]) + (jm - 1) * 31 - (jm ~/ 7) * (jm - 7) + jd - 1;
}

List<int> d2j(int jdn) {
  final gy = d2g(jdn)[0];
  var jy = gy - 621;
  final r = jalCal(jy);
  var k = jdn - g2d(gy, 3, r[2]);
  if (k >= 0) {
    if (k <= 185) return [jy, 1 + k ~/ 31, k % 31 + 1];
    k -= 186;
  } else {
    jy -= 1;
    k += 179;
    if (r[0] == 1) k += 1;
  }
  return [jy, 7 + k ~/ 30, k % 30 + 1];
}

List<int> toJ(DateTime d) => d2j(g2d(d.year, d.month, d.day));
int jlen(int jy, int jm) => jm <= 6 ? 31 : (jm <= 11 ? 30 : (jalCal(jy)[0] == 0 ? 30 : 29));
String dkey(DateTime d) => '${d.year}-${d.month}-${d.day}';
String dateText(DateTime d) => '${wdn[d.weekday - 1]} - ${dateText0(d)}';

String dateText0(DateTime d) {
  final j = toJ(d);
  return '${j[2]} ${mj[j[1] - 1]} ${j[0]} - ${d.day} ${mg[d.month - 1]} ${d.year}';
}

List<String> hn = ['Muharrem', 'Safer', 'Rebiülevvel', 'Rebiülahir', 'Cemaziyelevvel', 'Cemaziyelahir', 'Recep', 'Şaban', 'Ramazan', 'Şevval', 'Zilkade', 'Zilhicce'];
int lunarAdj = 1; // İran'ın resmi Hicri Kameri tarihine göre ±gün düzeltmesi

// ★ işaretli günler resmi tatildir
const irSolar = <String, String>{
  '1-1': '★Nevruz Bayramı', '1-2': '★Nevruz Bayramı', '1-3': '★Nevruz Bayramı', '1-4': '★Nevruz Bayramı',
  '1-12': '★İslam Cumhuriyeti Günü', '1-13': '★Sizdeh Bedar', '2-1': 'Sadi Günü', '2-25': 'Firdevsi Günü',
  '3-14': "★Humeyni'nin vefatı", '3-15': '★15 Hordad Kıyamı', '7-20': 'Hafız Günü', '8-13': 'Öğrenci Günü',
  '9-16': 'Öğrenci Günü', '9-30': 'Yelda Gecesi - چیلله گئجه‌سی (شب یلدا)', '9-21': '۲۱ آذر قیامی (آذربایجان ملّی حؤکومتینین ایل دؤنومو)', '12-3': 'دونیا آنا دیلی گونو (۲۱ فورییه)', '6-27': 'شهریار آنما گونو (شعر و ادب گونو)', '4-2': 'صمد بهرنگینین دوغومو (۲ تیر)', '7-26': "İmam Rıza'nın Nişabur'a gelişi / Beden Eğitimi ve Spor Günü", '11-22': '★İslam Devrimi Zaferi', '12-29': '★Petrol Sanayisinin Millileşmesi',
};
const irLunar = <String, String>{
  '1-9': '★Tasua', '1-10': '★Aşura', '2-20': '★Erbain', '2-28': "★Hz. Peygamber'in vefatı ve İmam Hasan'ın şehadeti",
  '2-29': "★İmam Rıza'nın şehadeti", '3-17': "★Hz. Peygamber'in ve İmam Sadık'ın doğumu", '6-3': "★Hz. Fatıma'nın şehadeti",
  '7-13': "★Hz. Ali'nin doğumu", '7-27': '★Mebas', '8-15': "★Hz. Mehdi'nin doğumu", '9-21': "★Hz. Ali'nin şehadeti",
  '10-1': '★Ramazan Bayramı', '10-2': '★Ramazan Bayramı', '10-25': "★İmam Sadık'ın şehadeti", '12-10': '★Kurban Bayramı',
  '12-18': '★Gadir-i Hum',
};
const gFixed = <String, List<String>>{
  '1-1': ['TR ★Yılbaşı', 'AZ ★Yeni il bayramı'], '1-2': ['AZ ★Yeni il bayramı'], '1-20': ['AZ Ümumxalq Hüzn Günü'],
  '2-21': ['Dünya Ana Dil Günü - دونیا آنا دیلی گونو'], '3-8': ['TR Dünya Kadınlar Günü', 'AZ ★Beynəlxalq Qadınlar Günü'], '3-12': ["TR İstiklal Marşı'nın Kabulü"], '3-18': ['TR Çanakkale Zaferi'],
  '3-20': ['AZ ★Novruz bayramı'], '3-21': ['AZ ★Novruz bayramı'], '3-22': ['AZ ★Novruz bayramı'], '3-23': ['AZ ★Novruz bayramı'], '3-24': ['AZ ★Novruz bayramı'],
  '4-23': ['TR ★Ulusal Egemenlik ve Çocuk Bayramı'], '5-1': ['TR ★Emek ve Dayanışma Günü'], '5-9': ['AZ ★Faşizm üzərində Qələbə Günü'],
  '5-19': ["TR ★Atatürk'ü Anma, Gençlik ve Spor Bayramı"], '5-28': ['AZ ★Müstəqillik Günü'], '6-15': ['AZ ★Milli Qurtuluş Günü'],
  '6-26': ['AZ ★Silahlı Qüvvələr Günü'], '7-15': ['TR ★Demokrasi ve Milli Birlik Günü'], '8-30': ['TR ★Zafer Bayramı'],
  '10-18': ['AZ ★Dövlət Müstəqilliyi Günü'], '10-28': ['TR Cumhuriyet Bayramı arifesi (yarım gün)'], '10-29': ['TR ★Cumhuriyet Bayramı'],
  '11-8': ['AZ ★Zəfər Günü'], '11-9': ['AZ ★Dövlət Bayrağı Günü'], '11-10': ["TR Atatürk'ü Anma Günü"], '11-12': ['AZ Konstitusiya Günü'],
  '11-17': ['AZ Milli Dirçəliş Günü'], '11-24': ['TR Öğretmenler Günü'], '12-31': ['AZ ★Dünya Azərbaycanlılarının Həmrəyliyi Günü'],
};
const trLunar = <String, List<String>>{
  '10-1': ['TR/AZ ★Ramazan Bayramı'], '10-2': ['TR/AZ ★Ramazan Bayramı'], '10-3': ['TR ★Ramazan Bayramı'],
  '12-10': ['TR/AZ ★Kurban Bayramı'], '12-11': ['TR/AZ ★Kurban Bayramı'], '12-12': ['TR ★Kurban Bayramı'], '12-13': ['TR ★Kurban Bayramı'],
};

double isl2jd(int y, int mo, int d) => d + (29.5 * (mo - 1)).ceil() + (y - 1) * 354 + ((3 + 11 * y) ~/ 30) + 1948439.5 - 1;

// Hesapla bulunan (tablo yöntemi) Hicri Kameri tarih; resmi ilandan ±1 gün farklı olabilir
List<int> toH(DateTime d, int adj) {
  final days = DateTime.utc(d.year, d.month, d.day).add(Duration(days: adj)).millisecondsSinceEpoch ~/ 86400000;
  final jd = days + 2440587.5;
  final y = ((30 * (jd - 1948439.5) + 10646) / 10631).floor();
  final mo = m.min(12, ((jd - (29 + isl2jd(y, 1, 1))) / 29.5).ceil() + 1);
  final dy = (jd - isl2jd(y, mo, 1)).floor() + 1;
  return [y, mo, dy];
}

List<String> eventsFor(DateTime d, bool jal, [bool qam = false]) {
  final out = <String>[];
  if (qam) {
    final h = toH(d, lunarAdj), h0 = toH(d, 0);
    final b = irLunar['${h[1]}-${h[2]}'];
    if (b != null) out.add('İR $b');
    out.addAll(trLunar['${h0[1]}-${h0[2]}'] ?? const []);
  } else if (jal) {
    final j = toJ(d), h = toH(d, lunarAdj);
    final a = irSolar['${j[1]}-${j[2]}'], b = irLunar['${h[1]}-${h[2]}'];
    if (a != null) out.add(a);
    if (b != null) out.add(b);
    if (d.weekday == DateTime.wednesday && j[1] >= 11) {
      final diff = j2d(j[0] + 1, 1, 1) - g2d(d.year, d.month, d.day);
      if (diff >= 1 && diff <= 28) {
        out.add(const ['توریاق چارشنبه‌سی (چارشنبه سوری)', 'یئل چارشنبه‌سی', 'اؤد چارشنبه‌سی', 'سو چارشنبه‌سی'][(diff - 1) ~/ 7]);
      }
    }
  } else {
    final h = toH(d, 0);
    out.addAll(gFixed['${d.month}-${d.day}'] ?? const []);
    out.addAll(trLunar['${h[1]}-${h[2]}'] ?? const []);
  }
  return out;
}

bool isHoliday(DateTime d, bool jal, [bool qam = false]) =>
    eventsFor(d, jal, qam).any((e) => e.contains('★')) || (jal && d.weekday == DateTime.friday);

const irProv = <String, String>{'تهران': 'تهران', 'اسلامشهر': 'تهران', 'ورامین': 'تهران', 'شهریار': 'تهران', 'کرج': 'البرز', 'قم': 'قم', 'اراک': 'مرکزی', 'ساوه': 'مرکزی', 'قزوین': 'قزوین', 'زنجان': 'زنجان', 'ابهر': 'زنجان', 'رشت': 'گیلان', 'لاهیجان': 'گیلان', 'بندر انزلی': 'گیلان', 'لنگرود': 'گیلان', 'آستارا': 'گیلان', 'رودسر': 'گیلان', 'ساری': 'مازندران', 'آمل': 'مازندران', 'بابل': 'مازندران', 'قائم‌شهر': 'مازندران', 'بهشهر': 'مازندران', 'گرگان': 'گلستان', 'گنبد کاووس': 'گلستان', 'آزادشهر': 'گلستان', 'سمنان': 'سمنان', 'شاهرود': 'سمنان', 'دامغان': 'سمنان', 'بجنورد': 'خراسان شمالی', 'مشهد': 'خراسان رضوی', 'نیشابور': 'خراسان رضوی', 'سبزوار': 'خراسان رضوی', 'تربت حیدریه': 'خراسان رضوی', 'قوچان': 'خراسان رضوی', 'کاشمر': 'خراسان رضوی', 'گناباد': 'خراسان رضوی', 'بیرجند': 'خراسان جنوبی', 'تبریز': 'آذربایجان شرقی', 'مراغه': 'آذربایجان شرقی', 'مرند': 'آذربایجان شرقی', 'اهر': 'آذربایجان شرقی', 'سراب': 'آذربایجان شرقی', 'میانه': 'آذربایجان شرقی', 'بناب': 'آذربایجان شرقی', 'شبستر': 'آذربایجان شرقی', 'ارومیه': 'آذربایجان غربی', 'خوی': 'آذربایجان غربی', 'میاندوآب': 'آذربایجان غربی', 'مهاباد': 'آذربایجان غربی', 'بوکان': 'آذربایجان غربی', 'سلماس': 'آذربایجان غربی', 'ماکو': 'آذربایجان غربی', 'چهاربرج': 'آذربایجان غربی', 'اردبیل': 'اردبیل', 'پارس‌آباد': 'اردبیل', 'مشگین‌شهر': 'اردبیل', 'خلخال': 'اردبیل', 'سنندج': 'کردستان', 'سقز': 'کردستان', 'بانه': 'کردستان', 'مریوان': 'کردستان', 'قروه': 'کردستان', 'کرمانشاه': 'کرمانشاه', 'همدان': 'همدان', 'ملایر': 'همدان', 'نهاوند': 'همدان', 'ایلام': 'ایلام', 'خرم‌آباد': 'لرستان', 'بروجرد': 'لرستان', 'دورود': 'لرستان', 'اهواز': 'خوزستان', 'دزفول': 'خوزستان', 'آبادان': 'خوزستان', 'خرمشهر': 'خوزستان', 'ماهشهر': 'خوزستان', 'بهبهان': 'خوزستان', 'ایذه': 'خوزستان', 'یاسوج': 'کهگیلویه و بویراحمد', 'شهرکرد': 'چهارمحال و بختیاری', 'اصفهان': 'اصفهان', 'کاشان': 'اصفهان', 'نجف‌آباد': 'اصفهان', 'خمینی‌شهر': 'اصفهان', 'شاهین‌شهر': 'اصفهان', 'یزد': 'یزد', 'شیراز': 'فارس', 'لار': 'فارس', 'جهرم': 'فارس', 'مرودشت': 'فارس', 'کازرون': 'فارس', 'فسا': 'فارس', 'بوشهر': 'بوشهر', 'بندرعباس': 'هرمزگان', 'زاهدان': 'سیستان و بلوچستان', 'زابل': 'سیستان و بلوچستان', 'چابهار': 'سیستان و بلوچستان', 'ایرانشهر': 'سیستان و بلوچستان', 'کرمان': 'کرمان', 'سیرجان': 'کرمان', 'رفسنجان': 'کرمان', 'جیرفت': 'کرمان', 'بم': 'کرمان'};
const langNames = ['Türkçe', 'Azərbaycan dili', 'آذربایجان دیلی', 'فارسی', 'English', 'العربية', 'Русский', 'Deutsch', 'Français', 'Español', 'Italiano', 'Português', 'Polski'];
int langIdx = 0, nameIdx = 2;
final langRev = ValueNotifier<int>(0);
final textScale = ValueNotifier<double>(1.0);
final themeId = ValueNotifier<int>(0);

class Preset {
  final String key;
  final int seed;
  final List<int> pv;
  final int? tert;
  final bool amoled, outlined, center;
  final String? font; // telefonun kendi yazı aileleri
  final double radius; // köşe yuvarlaklığı
  final int cell; // takvim günü: 0 daire, 1 yuvarlak kare, 2 kare
  final int layout; // vakitler: 0 liste, 1 ızgara, 2 yatay şerit
  const Preset(this.key, this.seed, this.pv,
      {this.tert, this.amoled = false, this.outlined = false, this.center = false, this.font, this.radius = 16, this.cell = 1, this.layout = 0});
}

const presets = [
  Preset('Zümrüt yeşili', 0xFF047857, [0xFF17302B, 0xFF2F6F5E, 0xFFD6A038], radius: 16, cell: 1, layout: 0),
  Preset('Gece mavisi', 0xFF1D4ED8, [0xFF0B1B4D, 0xFF1E40AF, 0xFF60A5FA], font: 'sans-serif-light', radius: 26, cell: 0, layout: 1, center: true),
  Preset('Gün batımı', 0xFFEA580C, [0xFFFB923C, 0xFFDB2777, 0xFF4C1D95], font: 'serif', radius: 30, cell: 0, layout: 2, center: true),
  Preset('Bordo', 0xFF9F1239, [0xFF4C0519, 0xFF9F1239, 0xFFE11D48], font: 'serif', radius: 6, cell: 2, layout: 0, outlined: true),
  Preset('Mor', 0xFF7C3AED, [0xFF2E1065, 0xFF6D28D9, 0xFFA78BFA], font: 'sans-serif-medium', radius: 22, cell: 1, layout: 1),
  Preset('Turkuaz', 0xFF0891B2, [0xFF134E4A, 0xFF0F766E, 0xFF2DD4BF], font: 'sans-serif-condensed', radius: 12, cell: 1, layout: 2, outlined: true),
  Preset('Altın', 0xFFB45309, [0xFF78350F, 0xFFB8821F, 0xFFFDE68A], font: 'serif', radius: 18, cell: 0, layout: 0, center: true),
  Preset('Siyah (AMOLED)', 0xFFD6A038, [0xFF000000, 0xFF1F1F1F, 0xFFD6A038], amoled: true, font: 'sans-serif-medium', radius: 10, cell: 2, layout: 1, outlined: true),
  Preset('Azerbaycan', 0xFF0092BC, [0xFF0092BC, 0xFFE00034, 0xFF00AF66], tert: 0xFFE00034, radius: 14, cell: 1, layout: 0),
  Preset('Türkiye', 0xFFE30A17, [0xFFE30A17, 0xFF9B0711], font: 'sans-serif-medium', radius: 8, cell: 1, layout: 2),
];

Preset get cp => presets[themeId.value];

ThemeData buildTheme(Brightness b) {
  final p = presets[themeId.value];
  var cs = ColorScheme.fromSeed(seedColor: seedColor.value, brightness: b);
  if (p.tert != null) cs = cs.copyWith(tertiary: Color(p.tert!));
  final dark = b == Brightness.dark;
  final black = p.amoled && dark;
  if (black) cs = cs.copyWith(surface: Colors.black);
  const gold = Color(0xFFD6A038);
  final bar = black ? Colors.black : (dark ? cs.primaryContainer : cs.primary);
  final onBar = black ? gold : (dark ? cs.onPrimaryContainer : cs.onPrimary);
  final bg = black ? Colors.black : Color.alphaBlend(cs.primary.withOpacity(dark ? 0.12 : 0.07), cs.surface);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(p.radius));
  return ThemeData(
    colorScheme: cs,
    useMaterial3: true,
    fontFamily: p.font,
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
        backgroundColor: bar,
        foregroundColor: onBar,
        centerTitle: p.center,
        iconTheme: IconThemeData(color: onBar),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(bottom: Radius.circular(p.radius)))),
    tabBarTheme: TabBarTheme(labelColor: onBar, unselectedLabelColor: onBar.withOpacity(0.7), indicatorColor: onBar),
    cardTheme: CardTheme(
        color: black ? const Color(0xFF141414) : Color.alphaBlend(cs.primary.withOpacity(dark ? 0.16 : 0.10), cs.surface),
        elevation: p.outlined ? 0 : 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(p.radius), side: p.outlined ? BorderSide(color: cs.outline) : BorderSide.none)),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
    dialogTheme: DialogTheme(shape: shape),
    inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(p.radius))),
  );
}

const volLevels = [25, 50, 75, 100, 150];
Map<int, int> vol = {};
String resFor(int i) {
  final base = snd[i] ?? defSound();
  final v = vol[i] ?? 100;
  return v == 100 ? base : '${base}_v$v';
}

bool get rtl => langIdx == 2 || langIdx == 3 || langIdx == 5;

const _t = <String, String>{
  "Uygulama ayarları": "Tətbiq ayarları|تطبیق آیارلاری|تنظیمات برنامه|App settings|إعدادات التطبيق|Настройки приложения|App-Einstellungen|Paramètres de l'application|Ajustes de la aplicación|Impostazioni app|Configurações do app|Ustawienia aplikacji",
  "Şehir seçimi": "Şəhər seçimi|شهر سئچیمی|انتخاب شهر|Choose city|اختيار المدينة|Выбор города|Stadt wählen|Choisir la ville|Elegir ciudad|Scegli la città|Escolher cidade|Wybierz miasto",
  "Vakit ayarları": "Vaxt ayarları|واخت آیارلاری|تنظیمات اوقات شرعی|Prayer time settings|إعدادات أوقات الصلاة|Настройки времени намаза|Gebetszeiten-Einstellungen|Paramètres des heures de prière|Ajustes de horarios de oración|Impostazioni orari di preghiera|Configurações dos horários de oração|Ustawienia czasów modlitw",
  "Ana sayfa ve bildirimler": "Ana səhifə və bildirişlər|آنا صحیفه و بیلدیریشلر|صفحه اصلی و اعلان‌ها|Home page and notifications|الصفحة الرئيسية والإشعارات|Главная и уведомления|Startseite und Benachrichtigungen|Accueil et notifications|Inicio y notificaciones|Home e notifiche|Início e notificações|Strona główna i powiadomienia",
  "Renk seçimi": "Rəng seçimi|رنگ سئچیمی|انتخاب رنگ|Choose color|اختيار اللون|Выбор цвета|Farbe wählen|Choisir la couleur|Elegir color|Scegli il colore|Escolher cor|Wybierz kolor",
  "Dil": "Dil|دیل|زبان|Language|اللغة|Язык|Sprache|Langue|Idioma|Lingua|Idioma|Język",
  "Uygulama dili": "Tətbiq dili|تطبیق دیلی|زبان برنامه|App language|لغة التطبيق|Язык приложения|App-Sprache|Langue de l'application|Idioma de la aplicación|Lingua dell'app|Idioma do app|Język aplikacji",
  "Ay, gün ve vakit adlarının dili": "Ay, gün və vaxt adlarının dili|آی، گون و واخت آدلارینین دیلی|زبان نام ماه‌ها، روزها و اوقات|Language of month, day and prayer names|لغة أسماء الشهور والأيام والأوقات|Язык названий месяцев, дней и времён|Sprache der Monats-, Tages- und Gebetsnamen|Langue des noms de mois, jours et prières|Idioma de los nombres de meses, días y oraciones|Lingua dei nomi di mesi, giorni e preghiere|Idioma dos nomes de meses, dias e orações|Język nazw miesięcy, dni i modlitw",
  "Miladi": "Miladi|میلادی|میلادی|Gregorian|ميلادي|Григорианский|Gregorianisch|Grégorien|Gregoriano|Gregoriano|Gregoriano|Gregoriański",
  "Şemsî": "Şəmsi|شمسی|شمسی|Solar Hijri|هجري شمسي|Солнечный хиджры|Solar-Hidschra|Hégirien solaire|Hégira solar|Egira solare|Hégira solar|Słoneczny hidżry",
  "Kameri": "Qəməri|قمری|قمری|Lunar Hijri|هجري قمري|Лунный хиджры|Mond-Hidschra|Hégirien lunaire|Hégira lunar|Egira lunare|Hégira lunar|Księżycowy hidżry",
  "Not": "Qeyd|قئید|یادداشت|Note|ملاحظة|Заметка|Notiz|Note|Nota|Nota|Nota|Notatka",
  "Ezanı 10 saniye sonra dene": "Azanı 10 saniyə sonra yoxla|اذانی ۱۰ ثانیه سونرا یوخلا|اذان را ۱۰ ثانیه بعد امتحان کن|Test adhan in 10 seconds|جرّب الأذان بعد 10 ثوانٍ|Проверить азан через 10 секунд|Adhan in 10 Sekunden testen|Tester l'adhan dans 10 secondes|Probar el adhan en 10 segundos|Prova l'adhan tra 10 secondi|Testar o adhan em 10 segundos|Przetestuj adhan za 10 sekund",
  "Hicri Kameri düzeltme (İran)": "Hicri-Qəməri düzəliş (İran)|هجری قمری دوزلیش (ایران)|اصلاح تاریخ قمری (ایران)|Lunar Hijri adjustment (Iran)|تعديل الهجري القمري (إيران)|Коррекция лунного хиджры (Иран)|Mondkalender-Korrektur (Iran)|Ajustement hégirien lunaire (Iran)|Ajuste de la hégira lunar (Irán)|Correzione egira lunare (Iran)|Ajuste da hégira lunar (Irã)|Korekta kalendarza księżycowego (Iran)",
  "Dini günler hesapla bulunur, resmi ilandan 1 gün farklı olabilir": "Dini günlər hesablama ilə tapılır, rəsmi elandan 1 gün fərqli ola bilər|دینی گونلر حسابلاما ایله تاپیلیر، رسمی اعلاندان ۱ گون فرقلی اولا بیلر|روزهای دینی محاسبه‌ای است و ممکن است ۱ روز با اعلام رسمی تفاوت داشته باشد|Religious days are calculated and may differ by 1 day from the official announcement|الأيام الدينية محسوبة وقد تختلف يوماً عن الإعلان الرسمي|Религиозные даты рассчитаны и могут отличаться на 1 день от официальных|Religiöse Tage werden berechnet und können um 1 Tag von der offiziellen Angabe abweichen|Les jours religieux sont calculés et peuvent différer d'un jour de l'annonce officielle|Los días religiosos se calculan y pueden diferir 1 día del anuncio oficial|I giorni religiosi sono calcolati e possono differire di 1 giorno dall'annuncio ufficiale|Os dias religiosos são calculados e podem diferir 1 dia do anúncio oficial|Dni religijne są obliczane i mogą różnić się o 1 dzień od oficjalnego ogłoszenia",
  "Ana sayfada göster": "Ana səhifədə göstər|آنا صحیفه ده گؤستر|نمایش در صفحه اصلی|Show on home page|عرض في الصفحة الرئيسية|Показывать на главной|Auf Startseite anzeigen|Afficher sur l'accueil|Mostrar en inicio|Mostra nella home|Mostrar no início|Pokaż na stronie głównej",
  "Bildirimler": "Bildirişlər|بیلدیریشلر|اعلان‌ها|Notifications|الإشعارات|Уведомления|Benachrichtigungen|Notifications|Notificaciones|Notifiche|Notificações|Powiadomienia",
  "Tema": "Tema|تما|پوسته|Theme|المظهر|Тема|Design|Thème|Tema|Tema|Tema|Motyw",
  "Telefon ayarına göre": "Telefon ayarına görə|تلفون آیارینا گؤره|مطابق تنظیمات گوشی|Follow phone setting|حسب إعداد الهاتف|Как в телефоне|Wie Telefon|Selon le téléphone|Según el teléfono|Come il telefono|Como o telefone|Jak w telefonie",
  "Gündüz": "Gündüz|گوندوز|روز|Day|نهاري|День|Hell|Jour|Día|Giorno|Dia|Dzień",
  "Gece": "Gecə|گجه|شب|Night|ليلي|Ночь|Dunkel|Nuit|Noche|Notte|Noite|Noc",
  "Ana renk": "Əsas rəng|آنا رنگ|رنگ اصلی|Main color|اللون الأساسي|Основной цвет|Hauptfarbe|Couleur principale|Color principal|Colore principale|Cor principal|Kolor główny",
  "Ad, enlem (−66 ile 66) ve boylam (−180 ile 180) gerekli": "Ad, enlik (−66…66) və uzunluq (−180…180) lazımdır|آد، انلیک (−۶۶…۶۶) و اوزونلوق (−۱۸۰…۱۸۰) لازیمدیر|نام، عرض (۶۶− تا ۶۶) و طول (۱۸۰− تا ۱۸۰) لازم است|Name, latitude (−66 to 66) and longitude (−180 to 180) required|الاسم وخط العرض (−66 إلى 66) وخط الطول (−180 إلى 180) مطلوبة|Нужны название, широта (−66…66) и долгота (−180…180)|Name, Breite (−66 bis 66) und Länge (−180 bis 180) erforderlich|Nom, latitude (−66 à 66) et longitude (−180 à 180) requis|Se requieren nombre, latitud (−66 a 66) y longitud (−180 a 180)|Servono nome, latitudine (−66…66) e longitudine (−180…180)|Nome, latitude (−66 a 66) e longitude (−180 a 180) são obrigatórios|Wymagane: nazwa, szerokość (−66…66) i długość (−180…180)",
  "Yerli şehir": "Yerli şəhər|یئرلی شهر|شهر داخلی|Domestic city|مدينة محلية|Город (Иран)|Stadt im Iran|Ville (Iran)|Ciudad (Irán)|Città (Iran)|Cidade (Irã)|Miasto (Iran)",
  "Yabancı şehir": "Xarici şəhər|خارجی شهر|شهر خارجی|Foreign city|مدينة أجنبية|Другая страна|Ausländische Stadt|Ville étrangère|Ciudad extranjera|Città estera|Cidade estrangeira|Miasto zagraniczne",
  "Yeni şehir": "Yeni şəhər|یئنی شهر|شهر جدید|New city|مدينة جديدة|Новый город|Neue Stadt|Nouvelle ville|Nueva ciudad|Nuova città|Nova cidade|Nowe miasto",
  "Kaydet": "Yadda saxla|یادداشدا ساخلا|ذخیره|Save|حفظ|Сохранить|Speichern|Enregistrer|Guardar|Salva|Salvar|Zapisz",
  "Şehrim listede yok": "Şəhərim siyahıda yoxdur|شهریم سیاهیدا یوخدور|شهر من در لیست نیست|My city is not listed|مدينتي غير موجودة|Моего города нет в списке|Meine Stadt fehlt|Ma ville n'est pas listée|Mi ciudad no está en la lista|La mia città non è in elenco|Minha cidade não está na lista|Mojego miasta nie ma na liście",
  "Eyalet": "Vilayət|ویلایت|استان|Province|المحافظة|Провинция|Provinz|Province|Provincia|Provincia|Província|Prowincja",
  "Şehir": "Şəhər|شهر|شهر|City|المدينة|Город|Stadt|Ville|Ciudad|Città|Cidade|Miasto",
  "Ülke": "Ölkə|اؤلکه|کشور|Country|الدولة|Страна|Land|Pays|País|Paese|País|Kraj",
  "Şehir adı": "Şəhər adı|شهر آدی|نام شهر|City name|اسم المدينة|Название города|Stadtname|Nom de la ville|Nombre de la ciudad|Nome della città|Nome da cidade|Nazwa miasta",
  "Enlem (ör. 36.5)": "Enlik (məs. 36.5)|انلیک (مثلاً ۳۶٫۵)|عرض جغرافیایی (مثلاً ۳۶٫۵)|Latitude (e.g. 36.5)|خط العرض (مثال 36.5)|Широта (напр. 36.5)|Breite (z. B. 36.5)|Latitude (ex. 36.5)|Latitud (p. ej. 36.5)|Latitudine (es. 36.5)|Latitude (ex.: 36.5)|Szerokość (np. 36.5)",
  "Boylam (ör. 46.15)": "Uzunluq (məs. 46.15)|اوزونلوق (مثلاً ۴۶٫۱۵)|طول جغرافیایی (مثلاً ۴۶٫۱۵)|Longitude (e.g. 46.15)|خط الطول (مثال 46.15)|Долгота (напр. 46.15)|Länge (z. B. 46.15)|Longitude (ex. 46.15)|Longitud (p. ej. 46.15)|Longitudine (es. 46.15)|Longitude (ex.: 46.15)|Długość (np. 46.15)",
  "Ezan": "Azan|اذان|اذان|Adhan|الأذان|Азан|Adhan|Adhan|Adhan|Adhan|Adhan|Adhan",
  "Ezan öncesi uyarı": "Azandan əvvəl xəbərdarlıq|اذاندان اول خبردارلیق|هشدار قبل از اذان|Alert before adhan|تنبيه قبل الأذان|Напоминание до азана|Warnung vor dem Adhan|Alerte avant l'adhan|Aviso antes del adhan|Avviso prima dell'adhan|Aviso antes do adhan|Alert przed adhanem",
  "Hesaplama yöntemi": "Hesablama üsulu|حسابلاما اوصولو|روش محاسبه|Calculation method|طريقة الحساب|Метод расчёта|Berechnungsmethode|Méthode de calcul|Método de cálculo|Metodo di calcolo|Método de cálculo|Metoda obliczania",
  "Ezan otomatik çalsın": "Azan avtomatik oxunsun|اذان اوتوماتیک اوخونسون|پخش خودکار اذان|Play adhan automatically|تشغيل الأذان تلقائياً|Автовоспроизведение азана|Adhan automatisch abspielen|Jouer l'adhan automatiquement|Reproducir el adhan automáticamente|Riproduci l'adhan automaticamente|Tocar o adhan automaticamente|Odtwarzaj adhan automatycznie",
  "Müezzin": "Müəzzin|مؤذن|مؤذن|Muezzin|المؤذن|Муэдзин|Muezzin|Muezzin|Muecín|Muezzin|Muezim|Muezin",
  "Ezandan önce uyarı ver": "Azandan əvvəl xəbərdarlıq et|اذاندان اول خبردارلیق ائت|هشدار قبل از اذان|Alert before adhan|تنبيه قبل الأذان|Напоминать до азана|Vor dem Adhan warnen|Alerter avant l'adhan|Avisar antes del adhan|Avvisa prima dell'adhan|Avisar antes do adhan|Przypominaj przed adhanem",
  "Kaç dakika önce": "Neçə dəqiqə əvvəl|نئچه دقیقه اول|چند دقیقه قبل|Minutes before|قبل كم دقيقة|За сколько минут|Minuten vorher|Minutes avant|Minutos antes|Minuti prima|Minutos antes|Ile minut wcześniej",
  "dk": "dəq|دق|دقیقه|min|د|мин|Min.|min|min|min|min|min",
  "dk kaldı": "dəq qalıb|دق قالیب|دقیقه مانده|min left|د متبقية|мин осталось|Min. übrig|min restantes|min restantes|min rimanenti|min restantes|min pozostało",
  "Vakit listesi": "Vaxt siyahısı|واخت سیاهیسی|فهرست اوقات|Prayer times list|قائمة الأوقات|Список времён|Gebetszeitenliste|Liste des horaires|Lista de horarios|Elenco orari|Lista de horários|Lista czasów",
  "Günün olayları ve tatiller": "Günün hadisələri və tətillər|گونون حادثه لری و تعطیللر|رویدادها و تعطیلات روز|Day events and holidays|أحداث اليوم والعطل|События и праздники дня|Tagesereignisse und Feiertage|Événements et jours fériés|Eventos y festivos del día|Eventi e festività del giorno|Eventos e feriados do dia|Wydarzenia i święta dnia",
  "Hicri Kameri tarih": "Hicri-Qəməri tarix|هجری قمری تاریخ|تاریخ قمری|Lunar Hijri date|التاريخ الهجري القمري|Дата по лунному хиджре|Mond-Hidschra-Datum|Date hégirienne lunaire|Fecha de la hégira lunar|Data egira lunare|Data da hégira lunar|Data księżycowa hidżry",
  "Not kutusu": "Qeyd xanası|قئید خاناسی|کادر یادداشت|Note box|مربع الملاحظات|Поле заметки|Notizfeld|Champ de note|Campo de nota|Campo nota|Campo de nota|Pole notatki",
  "Ezan bildiriminde tarihi göster": "Azan bildirişində tarixi göstər|اذان بیلدیریشینده تاریخی گؤستر|نمایش تاریخ در اعلان اذان|Show date in adhan notification|عرض التاريخ في إشعار الأذان|Показывать дату в уведомлении|Datum in der Adhan-Benachrichtigung anzeigen|Afficher la date dans la notification de l'adhan|Mostrar la fecha en la notificación del adhan|Mostra la data nella notifica dell'adhan|Mostrar a data na notificação do adhan|Pokaż datę w powiadomieniu adhanu",
  "Bildirimde takvimi göster": "Bildirişdə təqvimi göstər|بیلدیریشده تقویمی گؤستر|نمایش تقویم در اعلان|Show calendar in notification|عرض التقويم في الإشعار|Показывать календарь в уведомлении|Kalender in Benachrichtigung anzeigen|Afficher le calendrier dans la notification|Mostrar el calendario en la notificación|Mostra il calendario nella notifica|Mostrar o calendário na notificação|Pokaż kalendarz w powiadomieniu",
  "Çalar saat": "Zəngli saat|زنگلی ساعات|ساعت زنگ‌دار|Alarm clock|المنبه|Будильник|Wecker|Réveil|Despertador|Sveglia|Despertador|Budzik",
  "Analog": "Analoq|آنالوق|آنالوگ|Analog|تناظري|Аналоговые|Analog|Analogique|Analógico|Analogico|Analógico|Analogowy",
  "Dijital": "Rəqəmsal|رقمسال|دیجیتال|Digital|رقمي|Цифровые|Digital|Numérique|Digital|Digitale|Digital|Cyfrowy",
  "İkisi birden": "Hər ikisi|هر ایکیسی|هر دو|Both|كلاهما|Оба|Beides|Les deux|Ambos|Entrambi|Ambos|Oba",
  "Henüz alarm yok": "Hələ zəng yoxdur|هله زنگ یوخدور|هنوز آلارمی نیست|No alarms yet|لا توجد منبهات بعد|Будильников пока нет|Noch keine Wecker|Aucune alarme pour le moment|Aún no hay alarmas|Nessuna sveglia|Nenhum alarme ainda|Brak budzików",
  "Bildirim çubuğunda bugünün tarihini göster": "Bildiriş panelində bugünkü tarixi göstər|بیلدیریش پانئلینده بوگونکو تاریخی گؤستر|نمایش تاریخ امروز در نوار اعلان|Show today's date in the notification bar|عرض تاريخ اليوم في شريط الإشعارات|Показывать сегодняшнюю дату в шторке|Heutiges Datum in der Benachrichtigungsleiste anzeigen|Afficher la date du jour dans la barre de notifications|Mostrar la fecha de hoy en la barra de notificaciones|Mostra la data di oggi nella barra delle notifiche|Mostrar a data de hoje na barra de notificações|Pokaż dzisiejszą datę na pasku powiadomień",
  "Kıble": "Qiblə|قبله|قبله|Qibla|القبلة|Кибла|Qibla|Qibla|Qibla|Qibla|Qibla|Kibla",
  "Kâbe'ye uzaklık": "Kəbəyə məsafə|کعبه یه مسافه|فاصله تا کعبه|Distance to the Kaaba|المسافة إلى الكعبة|Расстояние до Каабы|Entfernung zur Kaaba|Distance jusqu'à la Kaaba|Distancia a la Kaaba|Distanza dalla Kaaba|Distância até a Caaba|Odległość do Kaaby",
  "Pusula sensörü bulunamadı": "Kompas sensoru tapılmadı|کومپاس سنسورو تاپیلمادی|حسگر قطب‌نما پیدا نشد|Compass sensor not found|لم يتم العثور على مستشعر البوصلة|Датчик компаса не найден|Kompasssensor nicht gefunden|Capteur de boussole introuvable|No se encontró el sensor de brújula|Sensore bussola non trovato|Sensor de bússola não encontrado|Nie znaleziono czujnika kompasu",
  "Pusulayı kalibre etmek için telefonu 8 şeklinde hareket ettirin": "Kompası kalibrləmək üçün telefonu 8 şəklində hərəkət etdirin|کومپاسی کالیبره ائتمک اوچون تلفونو ۸ شکلینده هره که ائتدیرین|برای کالیبره کردن قطب‌نما گوشی را به شکل ۸ حرکت دهید|Move the phone in a figure 8 to calibrate the compass|حرّك الهاتف على شكل 8 لمعايرة البوصلة|Для калибровки компаса двигайте телефон восьмёркой|Bewegen Sie das Telefon in einer 8, um den Kompass zu kalibrieren|Bougez le téléphone en forme de 8 pour calibrer la boussole|Mueva el teléfono en forma de 8 para calibrar la brújula|Muovi il telefono a forma di 8 per calibrare la bussola|Mova o telefone em forma de 8 para calibrar a bússola|Poruszaj telefonem w kształcie ósemki, aby skalibrować kompas",
  "Kıble yönündesiniz": "Qibləyə dönmüsünüz|قبله یه دؤنموسونوز|رو به قبله هستید|You are facing the Qibla|أنت متجه نحو القبلة|Вы смотрите в сторону Киблы|Sie blicken Richtung Qibla|Vous faites face à la Qibla|Está mirando hacia la Qibla|Sei rivolto verso la Qibla|Você está virado para a Qibla|Jesteś zwrócony w stronę Kibli",
  "Yazı boyutu": "Yazı ölçüsü|یازی اؤلچوسو|اندازه متن|Text size|حجم الخط|Размер текста|Textgröße|Taille du texte|Tamaño del texto|Dimensione del testo|Tamanho do texto|Rozmiar tekstu",
  "Sıfırla": "Sıfırla|سیفیرلا|بازنشانی|Reset|إعادة تعيين|Сбросить|Zurücksetzen|Réinitialiser|Restablecer|Ripristina|Redefinir|Resetuj",
  "Örnek metin: Ezan vakitleri ve takvim": "Nümunə mətn: Azan vaxtları və təqvim|نمونه متن: اذان واختلاری و تقویم|متن نمونه: اوقات اذان و تقویم|Sample text: Prayer times and calendar|نص تجريبي: أوقات الأذان والتقويم|Пример текста: время намаза и календарь|Beispieltext: Gebetszeiten und Kalender|Texte d'exemple : horaires de prière et calendrier|Texto de ejemplo: horarios de oración y calendario|Testo di esempio: orari di preghiera e calendario|Texto de exemplo: horários de oração e calendário|Przykładowy tekst: czasy modlitw i kalendarz",
  "Ezan ses seviyesi": "Azan səs səviyyəsi|اذان سس سویه سی|میزان صدای اذان|Adhan volume|مستوى صوت الأذان|Громкость азана|Adhan-Lautstärke|Volume de l'adhan|Volumen del adhan|Volume dell'adhan|Volume do adhan|Głośność adhanu",
  "Ses seviyesi telefonun alarm sesiyle birlikte çalışır": "Səs səviyyəsi telefonun zəng səsi ilə birlikdə işləyir|سس سویه سی تلفونون آلارم سسی ایله بیرلیکده ایشله یر|میزان صدا همراه با صدای آلارم گوشی عمل می‌کند|Volume works together with the phone's alarm volume|يعمل مستوى الصوت مع مستوى صوت المنبه في الهاتف|Громкость работает вместе с громкостью будильника телефона|Die Lautstärke wirkt zusammen mit der Alarmlautstärke des Telefons|Le volume fonctionne avec le volume des alarmes du téléphone|El volumen funciona junto con el volumen de alarma del teléfono|Il volume agisce insieme al volume sveglia del telefono|O volume funciona junto com o volume de alarme do telefone|Głośność działa razem z głośnością alarmu telefonu",
  "Hakkında": "Haqqında|هاقّیندا|درباره ما|About|حول|О приложении|Über|À propos|Acerca de|Informazioni|Sobre|O aplikacji",
  "Ezan ve tarih bildirimi sorunları": "Azan və tarix bildirişi problemləri|اذان و تاریخ بیلدیریشی پروبلئملری|مشکلات پخش اذان و اعلان تاریخ|Adhan and date notification problems|مشاكل تشغيل الأذان وإشعار التاريخ|Проблемы с азаном и уведомлением о дате|Probleme mit Adhan und Datumsbenachrichtigung|Problèmes d'adhan et de notification de date|Problemas con el adhan y la notificación de fecha|Problemi con adhan e notifica della data|Problemas com o adhan e a notificação de data|Problemy z adhanem i powiadomieniem o dacie",
  "Aç": "Aç|آچ|باز کردن|Open|فتح|Открыть|Öffnen|Ouvrir|Abrir|Apri|Abrir|Otwórz",
  "Bildirimleri yeniden kur": "Bildirişləri yenidən qur|بیلدیریشلری یئنیدن قور|تنظیم دوباره اعلان‌ها|Reschedule notifications|إعادة ضبط الإشعارات|Перенастроить уведомления|Benachrichtigungen neu planen|Reprogrammer les notifications|Reprogramar notificaciones|Riprogramma le notifiche|Reagendar notificações|Zaplanuj powiadomienia ponownie",
  "Takvim, ezan vakitleri, kıble ve çalar saat": "Təqvim, azan vaxtları, qiblə və zəngli saat|تقویم، اذان واختلاری، قبله و زنگلی ساعات|تقویم، اوقات اذان، قبله و ساعت زنگ‌دار|Calendar, prayer times, Qibla and alarm clock|تقويم وأوقات الأذان والقبلة والمنبه|Календарь, время намаза, кибла и будильник|Kalender, Gebetszeiten, Qibla und Wecker|Calendrier, horaires de prière, Qibla et réveil|Calendario, horarios de oración, Qibla y despertador|Calendario, orari di preghiera, Qibla e sveglia|Calendário, horários de oração, Qibla e despertador|Kalendarz, czasy modlitw, Kibla i budzik",
  "Sürüm": "Versiya|نسخه|نسخه|Version|الإصدار|Версия|Version|Version|Versión|Versione|Versão|Wersja",
  "Hazır temalar": "Hazır temalar|حاضیر تمالار|پوسته‌های آماده|Preset themes|سمات جاهزة|Готовые темы|Fertige Designs|Thèmes prédéfinis|Temas predefinidos|Temi predefiniti|Temas prontos|Gotowe motywy",
  "Zümrüt yeşili": "Zümrüd yaşılı|زومرود یاشیلی|سبز زمردی|Emerald green|أخضر زمردي|Изумрудный|Smaragdgrün|Vert émeraude|Verde esmeralda|Verde smeraldo|Verde esmeralda|Szmaragdowy",
  "Gece mavisi": "Gecə mavisi|گجه مایی سی|آبی شب|Midnight blue|أزرق ليلي|Полуночный синий|Mitternachtsblau|Bleu nuit|Azul noche|Blu notte|Azul noite|Granatowy",
  "Gün batımı": "Gün batımı|گون باتیمی|غروب|Sunset|غروب|Закат|Sonnenuntergang|Coucher de soleil|Atardecer|Tramonto|Pôr do sol|Zachód słońca",
  "Bordo": "Bordo|بوردو|عنابی|Burgundy|عنابي|Бордовый|Bordeaux|Bordeaux|Burdeos|Bordeaux|Bordô|Bordowy",
  "Mor": "Bənövşəyi|بنؤوشه یی|بنفش|Purple|بنفسجي|Фиолетовый|Lila|Violet|Morado|Viola|Roxo|Fioletowy",
  "Turkuaz": "Firuzəyi|فیروزه ای|فیروزه‌ای|Turquoise|فيروزي|Бирюзовый|Türkis|Turquoise|Turquesa|Turchese|Turquesa|Turkusowy",
  "Altın": "Qızılı|قیزیلی|طلایی|Gold|ذهبي|Золотой|Gold|Or|Dorado|Oro|Dourado|Złoty",
  "Siyah (AMOLED)": "Qara (AMOLED)|قارا (AMOLED)|مشکی (AMOLED)|Black (AMOLED)|أسود (AMOLED)|Чёрный (AMOLED)|Schwarz (AMOLED)|Noir (AMOLED)|Negro (AMOLED)|Nero (AMOLED)|Preto (AMOLED)|Czarny (AMOLED)",
  "Azerbaycan": "Azərbaycan|آذربایجان|آذربایجان|Azerbaijan|أذربيجان|Азербайджан|Aserbaidschan|Azerbaïdjan|Azerbaiyán|Azerbaigian|Azerbaijão|Azerbejdżan",
  "Türkiye": "Türkiyə|تورکیه|ترکیه|Türkiye|تركيا|Турция|Türkei|Turquie|Turquía|Turchia|Turquia|Turcja",
  "Bildirim iznini açın": "Bildiriş icazəsini açın|بیلدیریش ایجازه سینی آچین|مجوز اعلان را روشن کنید|Turn on notification permission",
  "Alarm ve hatırlatıcı iznini açın": "Zəng və xatırlatma icazəsini açın|آلارم و خاطیرلاتما ایجازه سینی آچین|مجوز آلارم و یادآور را روشن کنید|Allow alarms and reminders",
  "Pil kullanımını \"Kısıtlama yok\" yapın": "Batareya istifadəsini \"Məhdudiyyətsiz\" edin|باتاریا ایستیفاده سینی «محدودیتسیز» ائدین|مصرف باتری را «بدون محدودیت» کنید|Set battery usage to \"Unrestricted\"",
  "Alarm sesinin kapalı olmadığından emin olun": "Zəng səsinin söndürülmədiyinə əmin olun|آلارم سسینین سؤندورولمهدیگینه امین اولون|مطمئن شوید صدای آلارم خاموش نیست|Make sure the alarm volume is not muted",
  "Uygulamanın arka planda çalışmasına izin verin (Xiaomi, Huawei, Samsung)": "Tətbiqin arxa fonda işləməsinə icazə verin (Xiaomi, Huawei, Samsung)|تطبیقین آرخا فوندا ایشله مه سینه ایجازه وئرین (Xiaomi, Huawei, Samsung)|اجازه دهید برنامه در پس‌زمینه اجرا شود (شیائومی، هوآوی، سامسونگ)|Allow the app to run in the background (Xiaomi, Huawei, Samsung)",
  "Ezan 14 gün için kuruldu": "Azan 14 gün üçün quruldu|اذان ۱۴ گون اوچون قورولدو|اذان برای ۱۴ روز تنظیم شد|Adhan set for 14 days|تم ضبط الأذان لمدة 14 يوماً|Азан настроен на 14 дней|Adhan für 14 Tage eingestellt|Adhan réglé pour 14 jours|Adhan configurado para 14 días|Adhan impostato per 14 giorni|Adhan definido para 14 dias|Adhan ustawiony na 14 dni",
  "10 saniye sonra ezan çalmalı": "10 saniyə sonra azan oxunmalıdır|۱۰ ثانیه سونرا اذان اوخونمالیدیر|اذان تا ۱۰ ثانیه دیگر پخش می‌شود|Adhan should play in 10 seconds|سيُشغَّل الأذان بعد 10 ثوانٍ|Азан прозвучит через 10 секунд|Adhan sollte in 10 Sekunden erklingen|L'adhan devrait retentir dans 10 secondes|El adhan sonará en 10 segundos|L'adhan dovrebbe partire tra 10 secondi|O adhan deve tocar em 10 segundos|Adhan zabrzmi za 10 sekund",
  "Ayarlar kaydedildi, ezan yeniden kuruldu": "Ayarlar saxlandı, azan yenidən quruldu|آیارلار ساخلاندی، اذان یئنیدن قورولدو|تنظیمات ذخیره و اذان دوباره تنظیم شد|Settings saved, adhan rescheduled|تم الحفظ وإعادة ضبط الأذان|Настройки сохранены, азан перенастроен|Einstellungen gespeichert, Adhan neu geplant|Paramètres enregistrés, adhan reprogrammé|Ajustes guardados, adhan reprogramado|Impostazioni salvate, adhan riprogrammato|Configurações salvas, adhan reagendado|Ustawienia zapisane, adhan zaplanowany ponownie",
  "Hicri Kameri": "Hicri-Qəməri|هجری قمری|قمری|Lunar Hijri|هجري قمري|Лунный хиджры|Mond-Hidschra|Hégirien lunaire|Hégira lunar|Egira lunare|Hégira lunar|Księżycowy hidżry",
  "Hicri Şemsî": "Hicri-Şəmsi|هجری شمسی|شمسی|Solar Hijri|هجري شمسي|Солнечный хиджры|Solar-Hidschra|Hégirien solaire|Hégira solar|Egira solare|Hégira solar|Słoneczny hidżry",
};

String T(String k) {
  if (langIdx == 0) return k;
  final v = _t[k];
  if (v == null) return k;
  final p = v.split('|');
  return langIdx - 1 < p.length ? p[langIdx - 1] : k;
}

class Tx extends StatelessWidget {
  final String k;
  final TextStyle? style;
  const Tx(this.k, {super.key, this.style});
  @override
  Widget build(BuildContext context) => Text(T(k), style: style);
}

const _p = [
  "Sabah|Doğuş|Öğle|İkindi|Gün batımı|Akşam|Yatsı|Gece yarısı",
  "Sübh azanı|Gün doğumu|Nahar azanı|İkindi azanı|Gün batımı|Axşam azanı|Gecə azanı|Gecə yarısı",
  "صبح اذانی|گون دوغومو|ناهار اذانی|ایکیندی اذانی|گون باتومی|آخشام اذانی|گجه اذانی|گجه یاریسی",
  "اذان صبح|طلوع آفتاب|اذان ظهر|اذان عصر|غروب آفتاب|اذان مغرب|اذان عشاء|نیمه‌شب",
  "Fajr|Sunrise|Dhuhr|Asr|Sunset|Maghrib|Isha|Midnight",
  "الفجر|الشروق|الظهر|العصر|الغروب|المغرب|العشاء|منتصف الليل",
  "Фаджр|Восход|Зухр|Аср|Закат|Магриб|Иша|Полночь",
  "Fadschr|Sonnenaufgang|Dhuhr|Asr|Sonnenuntergang|Maghrib|Ischa|Mitternacht",
  "Fajr|Lever du soleil|Dhouhr|Asr|Coucher du soleil|Maghrib|Icha|Minuit",
  "Fayr|Amanecer|Dhuhr|Asr|Atardecer|Magrib|Isha|Medianoche",
  "Fajr|Alba|Dhuhr|Asr|Tramonto|Maghrib|Isha|Mezzanotte",
  "Fajr|Nascer do sol|Dhuhr|Asr|Pôr do sol|Maghrib|Isha|Meia-noite",
  "Fadżr|Wschód słońca|Zuhr|Asr|Zachód słońca|Maghrib|Isza|Północ",
];
const _g = [
  "Ocak|Şubat|Mart|Nisan|Mayıs|Haziran|Temmuz|Ağustos|Eylül|Ekim|Kasım|Aralık",
  "Yanvar|Fevral|Mart|Aprel|May|İyun|İyul|Avqust|Sentyabr|Oktyabr|Noyabr|Dekabr",
  "یانوار|فئورال|مارت|آپرئل|مای|ایون|ایول|آوقوست|سئنتیابر|اوکتیابر|نویابر|دکابر",
  "ژانویه|فوریه|مارس|آوریل|مه|ژوئن|ژوئیه|اوت|سپتامبر|اکتبر|نوامبر|دسامبر",
  "January|February|March|April|May|June|July|August|September|October|November|December",
  "يناير|فبراير|مارس|أبريل|مايو|يونيو|يوليو|أغسطس|سبتمبر|أكتوبر|نوفمبر|ديسمبر",
  "Январь|Февраль|Март|Апрель|Май|Июнь|Июль|Август|Сентябрь|Октябрь|Ноябрь|Декабрь",
  "Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember",
  "Janvier|Février|Mars|Avril|Mai|Juin|Juillet|Août|Septembre|Octobre|Novembre|Décembre",
  "Enero|Febrero|Marzo|Abril|Mayo|Junio|Julio|Agosto|Septiembre|Octubre|Noviembre|Diciembre",
  "Gennaio|Febbraio|Marzo|Aprile|Maggio|Giugno|Luglio|Agosto|Settembre|Ottobre|Novembre|Dicembre",
  "Janeiro|Fevereiro|Março|Abril|Maio|Junho|Julho|Agosto|Setembro|Outubro|Novembro|Dezembro",
  "Styczeń|Luty|Marzec|Kwiecień|Maj|Czerwiec|Lipiec|Sierpień|Wrzesień|Październik|Listopad|Grudzień",
];
const _j = [
  "Ferverdin|Erdibehişt|Hordad|Tir|Mordad|Şehriver|Mihr|Aban|Azer|Dey|Behmen|İsfend",
  "Ağlar Gülər|Gülən Ay|Qızaran Ay|Qora Bişirən|Quyruq Doğan|Zumar Ayı|Xəzəl Ayı|Qıroğ Ayı|Azər|Çillə|Donduran Ay|Bayram Ayı",
  "آغلار گولر|گولن آی|قیزاران آی|قورا بیشیرن|قویروق دوغان|زومار آیی|خزل آیی|قیروو آیی|آذر|چیلله|دوندوران آی|بایرام آیی",
  "فروردین|اردیبهشت|خرداد|تیر|مرداد|شهریور|مهر|آبان|آذر|دی|بهمن|اسفند",
  "Farvardin|Ordibehesht|Khordad|Tir|Mordad|Shahrivar|Mehr|Aban|Azar|Dey|Bahman|Esfand",
  "فروردين|أرديبهشت|خرداد|تير|مرداد|شهريور|مهر|آبان|آذر|دي|بهمن|إسفند",
  "Фарвардин|Ордибехешт|Хордад|Тир|Мордад|Шахривар|Мехр|Абан|Азар|Дей|Бахман|Эсфанд",
  "Farwardin|Ordibehescht|Chordad|Tir|Mordad|Schahriwar|Mehr|Aban|Azar|Dey|Bahman|Esfand",
  "Farvardin|Ordibehesht|Khordad|Tir|Mordad|Shahrivar|Mehr|Aban|Azar|Dey|Bahman|Esfand",
  "Farvardin|Ordibehesht|Khordad|Tir|Mordad|Shahrivar|Mehr|Aban|Azar|Dey|Bahman|Esfand",
  "Farvardin|Ordibehesht|Khordad|Tir|Mordad|Shahrivar|Mehr|Aban|Azar|Dey|Bahman|Esfand",
  "Farvardin|Ordibehesht|Khordad|Tir|Mordad|Shahrivar|Mehr|Aban|Azar|Dey|Bahman|Esfand",
  "Farwardin|Ordibehesz|Chordad|Tir|Mordad|Szahriwar|Mehr|Aban|Azar|Dej|Bahman|Esfand",
];
const _h = [
  "Muharrem|Safer|Rebiülevvel|Rebiülahir|Cemaziyelevvel|Cemaziyelahir|Recep|Şaban|Ramazan|Şevval|Zilkade|Zilhicce",
  "Məhərrəm|Səfər|Rəbiüləvvəl|Rəbiülaxır|Cəmadiyələvvəl|Cəmadiyəlaxır|Rəcəb|Şəban|Ramazan|Şəvval|Zilqədə|Zilhiccə",
  "محرم|صفر|ربیع‌الاول|ربیع‌الثانی|جمادی‌الاول|جمادی‌الثانی|رجب|شعبان|رمضان|شوال|ذی‌القعده|ذی‌الحجه",
  "محرم|صفر|ربیع‌الاول|ربیع‌الثانی|جمادی‌الاول|جمادی‌الثانی|رجب|شعبان|رمضان|شوال|ذی‌القعده|ذی‌الحجه",
  "Muharram|Safar|Rabi' al-awwal|Rabi' al-thani|Jumada al-awwal|Jumada al-thani|Rajab|Sha'ban|Ramadan|Shawwal|Dhu al-Qi'dah|Dhu al-Hijjah",
  "محرم|صفر|ربيع الأول|ربيع الآخر|جمادى الأولى|جمادى الآخرة|رجب|شعبان|رمضان|شوال|ذو القعدة|ذو الحجة",
  "Мухаррам|Сафар|Раби уль-авваль|Раби уль-ахир|Джумада уль-уля|Джумада уль-ахира|Раджаб|Шаабан|Рамадан|Шавваль|Зуль-каада|Зуль-хиджжа",
  "Muharram|Safar|Rabi' al-awwal|Rabi' ath-thani|Dschumada al-ula|Dschumada ath-thaniya|Radschab|Scha'ban|Ramadan|Schawwal|Dhu l-Qa'da|Dhu l-Hiddscha",
  "Mouharram|Safar|Rabi' al-awwal|Rabi' ath-thani|Joumada al-oula|Joumada ath-thania|Rajab|Chaabane|Ramadan|Chawwal|Dhou al-qi'da|Dhou al-hijja",
  "Muharram|Safar|Rabi al-awwal|Rabi al-zani|Yumada al-ula|Yumada al-zania|Rayab|Shaban|Ramadán|Shawwal|Dhu al-Qada|Dhu al-Hiyya",
  "Muharram|Safar|Rabi' al-awwal|Rabi' al-thani|Giumada al-ula|Giumada al-thania|Rajab|Sha'ban|Ramadan|Shawwal|Dhu al-qa'da|Dhu al-hijja",
  "Muharram|Safar|Rabi al-awwal|Rabi al-thani|Jumada al-awwal|Jumada al-thani|Rajab|Shaban|Ramadã|Shawwal|Dhu al-Qadah|Dhu al-Hijjah",
  "Muharram|Safar|Rabi al-awwal|Rabi al-sani|Dżumada al-ula|Dżumada al-sania|Radżab|Szaban|Ramadan|Szawwal|Zu al-kada|Zu al-hidżdża",
];
const _d = [
  "Pzt|Sal|Çar|Per|Cum|Cmt|Paz",
  "B.e.|Ç.a.|Çər|C.a.|Cümə|Şnb|Baz",
  "دوز گونو|آرا گون|اود گونو|سو گونو|آینی گونو|یئل لی گون|سود گونو",
  "دوشنبه|سه‌شنبه|چهارشنبه|پنجشنبه|جمعه|شنبه|یکشنبه",
  "Mon|Tue|Wed|Thu|Fri|Sat|Sun",
  "الإثنين|الثلاثاء|الأربعاء|الخميس|الجمعة|السبت|الأحد",
  "Пн|Вт|Ср|Чт|Пт|Сб|Вс",
  "Mo|Di|Mi|Do|Fr|Sa|So",
  "Lun|Mar|Mer|Jeu|Ven|Sam|Dim",
  "Lun|Mar|Mié|Jue|Vie|Sáb|Dom",
  "Lun|Mar|Mer|Gio|Ven|Sab|Dom",
  "Seg|Ter|Qua|Qui|Sex|Sáb|Dom",
  "Pon|Wt|Śr|Czw|Pt|Sob|Nie",
];

const _wd = [
  "Pazartesi|Salı|Çarşamba|Perşembe|Cuma|Cumartesi|Pazar",
  "Bazar ertəsi|Çərşənbə axşamı|Çərşənbə|Cümə axşamı|Cümə|Şənbə|Bazar",
  "دوز گونو|آرا گون|اود گونو|سو گونو|آینی گونو|یئل لی گون|سود گونو",
  "دوشنبه|سه‌شنبه|چهارشنبه|پنجشنبه|جمعه|شنبه|یکشنبه",
  "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday",
  "الإثنين|الثلاثاء|الأربعاء|الخميس|الجمعة|السبت|الأحد",
  "Понедельник|Вторник|Среда|Четверг|Пятница|Суббота|Воскресенье",
  "Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag",
  "Lundi|Mardi|Mercredi|Jeudi|Vendredi|Samedi|Dimanche",
  "Lunes|Martes|Miércoles|Jueves|Viernes|Sábado|Domingo",
  "Lunedì|Martedì|Mercoledì|Giovedì|Venerdì|Sabato|Domenica",
  "Segunda-feira|Terça-feira|Quarta-feira|Quinta-feira|Sexta-feira|Sábado|Domingo",
  "Poniedziałek|Wtorek|Środa|Czwartek|Piątek|Sobota|Niedziela",
];
List<String> wdn = _wd[2].split('|');

void applyNames() {
  wdn = _wd[nameIdx].split('|');
  names = _p[nameIdx].split('|');
  mg = _g[nameIdx].split('|');
  mj = _j[nameIdx].split('|');
  hn = _h[nameIdx].split('|');
  dn = _d[nameIdx].split('|');
}

String calText(DateTime d) {
  final j = toJ(d), h = toH(d, lunarAdj);
  final b = StringBuffer('${wdn[d.weekday - 1]}\n${j[2]} ${mj[j[1] - 1]} ${j[0]}\n${d.day} ${mg[d.month - 1]} ${d.year}\n${h[2]} ${hn[h[1] - 1]} ${h[0]}');
  for (final e in {...eventsFor(d, true), ...eventsFor(d, false)}) {
    b.write('\n$e');
  }
  final n = notes[dkey(d)];
  if (n != null && n.trim().isNotEmpty) b.write('\n${T('Not')}: $n');
  return b.toString();
}

bool showDateNotif = true;
int clockMode = 2;

class Alarm {
  int h, m;
  bool on;
  Alarm(this.h, this.m, this.on);
}

List<Alarm> alarms = [];

Future<void> persistAlarms() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('alarms', alarms.map((a) => '${a.h}:${a.m}:${a.on ? 1 : 0}').toList());
  } catch (_) {}
}

NotificationDetails dateDetails(int ms) => NotificationDetails(
      android: AndroidNotificationDetails('tarih', 'Bugünün tarihi',
          channelDescription: 'Kalıcı tarih bildirimi',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          playSound: false,
          enableVibration: false,
          showWhen: false,
          timeoutAfter: ms),
    );

final alarmDetails = NotificationDetails(
  android: AndroidNotificationDetails('alarm', 'Çalar saat',
      channelDescription: 'Alarmlar',
      importance: Importance.max,
      priority: Priority.high,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      additionalFlags: Int32List.fromList(<int>[4]),
      category: AndroidNotificationCategory.alarm),
);

Future<void> scheduleAlarms() async {
  for (var i = 0; i < 50; i++) {
    await plugin.cancel(8000 + i);
  }
  for (var i = 0; i < alarms.length; i++) {
    final a = alarms[i];
    if (!a.on) continue;
    final now = tz.TZDateTime.now(tz.local);
    var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, a.h, a.m);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    final label = '${a.h.toString().padLeft(2, '0')}:${a.m.toString().padLeft(2, '0')}';
    try {
      await plugin.zonedSchedule(8000 + i, T('Çalar saat'), label, at, alarmDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time);
    } catch (_) {
      await plugin.zonedSchedule(8000 + i, T('Çalar saat'), label, at, alarmDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time);
    }
  }
}

double qiblaBearing(double lat, double lng) {
  const klat = 21.4225, klng = 39.8262; // Kâbe
  final p1 = rad(lat), p2 = rad(klat), dl = rad(klng - lng);
  final y = m.sin(dl) * m.cos(p2);
  final x = m.cos(p1) * m.sin(p2) - m.sin(p1) * m.cos(p2) * m.cos(dl);
  return (deg(m.atan2(y, x)) + 360) % 360;
}

double kaabaKm(double lat, double lng) {
  const klat = 21.4225, klng = 39.8262;
  final a = m.pow(m.sin(rad(klat - lat) / 2), 2) + m.cos(rad(lat)) * m.cos(rad(klat)) * m.pow(m.sin(rad(klng - lng) / 2), 2);
  return 2 * 6371 * m.asin(m.sqrt(a));
}

const appPkg = 'com.takvim.takvim';

Future<void> openSys(String action, {String? data, Map<String, dynamic>? args}) async {
  try {
    await AndroidIntent(action: action, data: data, arguments: args).launch();
  } catch (_) {
    try {
      await const AndroidIntent(action: 'android.settings.SETTINGS').launch();
    } catch (_) {}
  }
}

String err = '';

Future<void> sched(int id, String title, String body, tz.TZDateTime t, [NotificationDetails? d]) async {
  try {
    await plugin.zonedSchedule(id, title, body, t, d ?? adhanDetails(defSound()),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
  } catch (_) {
    await plugin.zonedSchedule(id, title, body, t, d ?? adhanDetails(defSound()),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
  }
}

Future<void> schedule(City c) async {
  await plugin.cancelAll();
  final now = DateTime.now();
  var id = 0;
  for (var k = 0; k < 14; k++) {
    final day = DateTime(now.year, now.month, now.day + k);
    final tm = calc(day, c.lat, c.lng);
    final ct = showCalNotif ? calText(day) : null;
    for (var i = 0; i < 8; i++) {
      if (tm[i].isNaN) continue;
      final at = day.add(Duration(minutes: (tm[i] * 60).round()));
      if (adhanIdx.contains(i) && at.isAfter(now)) {
        await sched(id++, names[i], notifDate ? dateText(day) : '', tz.TZDateTime.from(at, tz.local), adhanDetails(resFor(i), ct));
      }
      final rt = at.subtract(Duration(minutes: remindMin));
      if (remindIdx.contains(i) && rt.isAfter(now)) {
        await sched(id++, names[i], '$remindMin ${T('dk kaldı')}', tz.TZDateTime.from(rt, tz.local), remindDetails(ct == null ? null : '$remindMin ${T('dk kaldı')}\n$ct'));
      }
    }
  }
  if (showDateNotif) {
    for (var k = 0; k < 14; k++) {
      final day = DateTime(now.year, now.month, now.day + k);
      final title = wdn[day.weekday - 1], body = dateText0(day);
      if (k == 0) {
        final nextMid = DateTime(now.year, now.month, now.day + 1, 0, 1);
        await plugin.show(7000, title, body, dateDetails(nextMid.difference(now).inMilliseconds));
      } else {
        await sched(7000 + k, title, body, tz.TZDateTime.from(DateTime(day.year, day.month, day.day, 0, 1), tz.local), dateDetails(86340000));
      }
    }
  }
  await scheduleAlarms();
}

Future<void> setup(void Function(String) mark) async {
  try {
    tzdata.initializeTimeZones();
    var name = 'UTC';
    try {
      mark('saat dilimi');
      name = await FlutterTimezone.getLocalTimezone().timeout(const Duration(seconds: 6));
    } catch (e) {
      err += 'saat dilimi: $e\n';
    }
    try {
      tz.setLocalLocation(tz.getLocation(name));
    } catch (e) {
      err += 'saat dilimi ($name): $e\n';
    }
    mark('bildirim hazırlığı');
    await plugin
        .initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')))
        .timeout(const Duration(seconds: 6));
  } catch (e) {
    err += 'başlatma: $e\n';
  }
}

Future<void> perms() async {
  final a = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  try {
    await a?.requestNotificationsPermission().timeout(const Duration(seconds: 30));
  } catch (e) {
    err += 'bildirim izni: $e\n';
  }
  try {
    await a?.requestExactAlarmsPermission().timeout(const Duration(seconds: 30));
  } catch (e) {
    err += 'alarm izni: $e\n';
  }
}

final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
final seedColor = ValueNotifier<Color>(const Color(0xFF047857));
const seeds = [0xFF17302B, 0xFF1565C0, 0xFF6A1B9A, 0xFFB71C1C, 0xFFEF6C00, 0xFF00796B];
bool showTimes = true, showEvents = true, showQamari = true, showNote = true, notifDate = true, showCalNotif = true;
Map<String, String> notes = {};

Future<void> saveBool(String k, bool v) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(k, v);
  } catch (_) {}
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AnimatedBuilder(
      animation: Listenable.merge([themeMode, seedColor, langRev, textScale, themeId]),
      builder: (_, __) => MaterialApp(
          title: 'تورک تقویمی و اذانی',
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: themeMode.value,
          builder: (c, w) => MediaQuery(
              data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(MediaQuery.textScalerOf(c).scale(1.0) * textScale.value)),
              child: Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: w!)),
          home: const Home())));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<City> cities = [];
  City? city;
  String msg = '';
  String step = 'başlıyor';
  bool jal = false, qam = false;
  int vy = 0, vm = 1;
  DateTime sel = DateTime.now();

  void mark(String x) {
    if (mounted) setState(() => step = x);
  }

  @override
  void initState() {
    super.initState();
    setView(sel);
    langRev.addListener(_onLang);
    load();
  }

  void _onLang() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    langRev.removeListener(_onLang);
    super.dispose();
  }

  Future<void> load() async {
    await setup(mark);
    mark('müezzinler');
    try {
      final t = await rootBundle.loadString('muezzins.txt');
      muez = t.trim().split('\n').where((l) => l.contains('|')).map((l) => l.split('|')).toList();
    } catch (_) {}
    if (muez.isEmpty) muez = [['azan', 'azan']];
    mark('şehir listesi');
    try {
      final raw = await rootBundle.loadString('cities.txt');
      cities = raw.trim().split('\n').map((l) {
        final a = l.split('|');
        return City(a[0], a[1], double.parse(a[2]), double.parse(a[3]));
      }).toList();
      cities.add(City('İran', 'چهاربرج', 36.5, 46.15));
    } catch (e) {
      err += 'şehir listesi: $e\n';
    }
    if (cities.isEmpty) {
      setState(() {});
      return;
    }
    mark('kayıtlı şehir');
    var c = cities.first;
    try {
      final p = await SharedPreferences.getInstance().timeout(const Duration(seconds: 6));
      final n = p.getString('city');
      final cu = p.getString('custom');
      if (cu != null) {
        for (final e in (jsonDecode(cu) as List)) {
          cities.add(City('Özel', e[0] as String, (e[1] as num).toDouble(), (e[2] as num).toDouble()));
        }
      }
      final th = p.getString('theme');
      final cl = p.getInt('cal');
      if (cl != null) {
        jal = cl == 1;
        qam = cl == 2;
      } else {
        jal = p.getBool('jal') ?? false;
      }
      lunarAdj = p.getInt('ladj') ?? 1;
      langIdx = p.getInt('lang') ?? 0;
      nameIdx = p.getInt('nlang') ?? 2;
      applyNames();
      langRev.value++;
      methodIdx = (p.getInt('method') ?? 0).clamp(0, methods.length - 1).toInt();
      remindMin = p.getInt('rmin') ?? 10;
      remindIdx = (p.getStringList('remind') ?? []).map(int.parse).toList();
      textScale.value = p.getDouble('tscale') ?? 1.0;
      final vj = p.getString('vol');
      if (vj != null) vol = (jsonDecode(vj) as Map).map((k, v) => MapEntry(int.parse(k as String), v as int));
      final sj = p.getString('snd');
      if (sj != null) snd = (jsonDecode(sj) as Map).map((k, v) => MapEntry(int.parse(k as String), v as String));
      showTimes = p.getBool('showTimes') ?? true;
      showEvents = p.getBool('showEvents') ?? true;
      showQamari = p.getBool('showQamari') ?? true;
      showNote = p.getBool('showNote') ?? true;
      notifDate = p.getBool('notifDate') ?? true;
      showCalNotif = p.getBool('calNotif') ?? true;
      showDateNotif = p.getBool('dateNotif') ?? true;
      clockMode = p.getInt('clockMode') ?? 2;
      alarms = (p.getStringList('alarms') ?? []).map((e) {
        final x = e.split(':');
        return Alarm(int.parse(x[0]), int.parse(x[1]), x[2] == '1');
      }).toList();
      themeId.value = (p.getInt('themeId') ?? 0).clamp(0, presets.length - 1).toInt();
      final sd = p.getInt('seed');
      if (sd != null) seedColor.value = Color(sd);
      final ns = p.getString('notes');
      if (ns != null) notes = Map<String, String>.from(jsonDecode(ns));
      setView(sel);
      if (th == 'dark') themeMode.value = ThemeMode.dark;
      if (th == 'light') themeMode.value = ThemeMode.light;
      final ad = p.getStringList('adhan');
      if (ad != null) adhanIdx = ad.map(int.parse).toList();
      c = cities.firstWhere((x) => x.name == n,
          orElse: () => cities.firstWhere((x) => x.name == 'چهاربرج', orElse: () => cities.first));
    } catch (e) {
      err += 'kayıt: $e\n';
    }
    setState(() => city = c);
    await perms();
    try {
      await schedule(c);
      setState(() => msg = T('Ezan 14 gün için kuruldu'));
    } catch (e) {
      setState(() => err += 'alarm kurma: $e\n');
    }
  }

  Future<void> test() async {
    try {
      await sched(9999, 'Deneme', dateText(DateTime.now()), tz.TZDateTime.now(tz.local).add(const Duration(seconds: 10)));
      setState(() => msg = T('10 saniye sonra ezan çalmalı'));
    } catch (e) {
      setState(() => err += 'deneme: $e\n');
    }
  }

  Future<void> pickCity() async {
    final c = await Navigator.push<City>(context, MaterialPageRoute(builder: (_) => CityPage(cities: cities, current: city)));
    if (c == null) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (c.group == 'Özel' && !cities.any((x) => x.group == 'Özel' && x.name == c.name)) {
        cities.add(c);
        await p.setString('custom', jsonEncode([for (final x in cities.where((x) => x.group == 'Özel')) [x.name, x.lat, x.lng]]));
      }
      await p.setString('city', c.name);
      await schedule(c);
      setState(() {
        city = c;
        msg = T('Ezan 14 gün için kuruldu');
      });
    } catch (e) {
      setState(() {
        city = c;
        err += 'şehir değiştirme: $e\n';
      });
    }
  }

  Future<void> openSettings() async {
    final items = [T('Şehir seçimi'), T('Vakit ayarları'), T('Ana sayfa ve bildirimler'), T('Renk seçimi'), T('Dil'), T('Yazı boyutu')];
    final r = await showDialog<int>(
        context: context,
        builder: (c) => SimpleDialog(title: const Tx('Uygulama ayarları'), children: [
              for (var i = 0; i < items.length; i++)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, i),
                    child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(items[i], style: const TextStyle(fontSize: 16)))),
            ]));
    if (r == null || !mounted) return;
    if (r == 0) {
      await pickCity();
      return;
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => r == 1 ? const PrayerSettingsPage() : (r == 4 ? const LanguagePage() : (r == 5 ? const TextSizePage() : SettingsPage(section: r)))));
    try {
      await schedule(city!);
      setState(() => msg = T('Ayarlar kaydedildi, ezan yeniden kuruldu'));
    } catch (e) {
      setState(() => err += 'alarm kurma: $e\n');
    }
  }

  void setView(DateTime d) {
    if (qam) {
      final h = toH(d, lunarAdj);
      vy = h[0];
      vm = h[1];
    } else if (jal) {
      final j = toJ(d);
      vy = j[0];
      vm = j[1];
    } else {
      vy = d.year;
      vm = d.month;
    }
  }

  void stepMonth(int n) {
    var y = vy, m = vm + n;
    if (m < 1) {
      m = 12;
      y--;
    }
    if (m > 12) {
      m = 1;
      y++;
    }
    setState(() {
      vy = y;
      vm = m;
    });
  }

  List<DateTime> viewDays() {
    final out = <DateTime>[];
    if (qam) {
      final base = (isl2jd(vy, vm, 1) - 2440587.5).round() - lunarAdj;
      final n = (isl2jd(vm == 12 ? vy + 1 : vy, vm == 12 ? 1 : vm + 1, 1) - isl2jd(vy, vm, 1)).round();
      for (var i = 0; i < n; i++) {
        final g = DateTime.utc(1970).add(Duration(days: base + i));
        out.add(DateTime(g.year, g.month, g.day));
      }
    } else if (jal) {
      final n = jlen(vy, vm), j0 = j2d(vy, vm, 1);
      for (var i = 0; i < n; i++) {
        final g = d2g(j0 + i);
        out.add(DateTime(g[0], g[1], g[2]));
      }
    } else {
      final n = DateTime(vy, vm + 1, 0).day;
      for (var i = 1; i <= n; i++) {
        out.add(DateTime(vy, vm, i));
      }
    }
    return out;
  }

  Future<void> saveNotes() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('notes', jsonEncode(notes));
    } catch (_) {}
  }

  Widget timesBlock(List<double> tm, ColorScheme cs) {
    final p = cp;
    final now = DateTime.now();
    final nowH = now.hour + now.minute / 60;
    final nextIdx = dkey(sel) == dkey(now) ? tm.indexWhere((x) => !x.isNaN && x > nowH) : -1;
    Widget tile(int i, {double? w, double? h}) {
      final nx = i == nextIdx;
      final fg = nx ? cs.onPrimary : cs.onPrimaryContainer;
      return Container(
        width: w,
        height: h,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: nx ? cs.primary : cs.primaryContainer.withOpacity(0.55),
          borderRadius: BorderRadius.circular(p.radius),
          border: p.outlined ? Border.all(color: nx ? cs.primary : cs.outline) : null,
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(names[i], textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: fg)),
          const SizedBox(height: 4),
          Text(fmt(tm[i]), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: fg)),
        ]),
      );
    }

    if (p.layout == 1) {
      return GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.4,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [for (var i = 0; i < 8; i++) tile(i)]);
    }
    if (p.layout == 2) {
      return SizedBox(
          height: 96,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (var i = 0; i < 8; i++) Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: tile(i, w: 112, h: 96)),
          ]));
    }
    return Column(children: [
      for (var i = 0; i < 8; i++)
        ListTile(
            dense: true,
            title: Text(names[i]),
            trailing: Text(fmt(tm[i]),
                style: TextStyle(fontSize: 18, fontWeight: i == nextIdx ? FontWeight.bold : FontWeight.normal, color: i == nextIdx ? cs.primary : null))),
    ]);
  }

  Widget cell(DateTime d, ColorScheme cs) {
    final k = dkey(d), isSel = k == dkey(sel), isToday = k == dkey(DateTime.now());
    return InkWell(
      onTap: () => setState(() => sel = d),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSel ? cs.primary : null,
          border: isToday ? Border.all(color: cs.tertiary, width: 2) : null,
          borderRadius: BorderRadius.circular(cp.cell == 0 ? 100.0 : (cp.cell == 1 ? cp.radius * 0.6 : 3.0)),
        ),
        child: Stack(alignment: Alignment.center, children: [
          Text('${qam ? toH(d, lunarAdj)[2] : (jal ? toJ(d)[2] : d.day)}', style: TextStyle(color: isSel ? cs.onPrimary : (isHoliday(d, jal, qam) ? cs.error : null))),
          if (notes.containsKey(k)) Positioned(bottom: 4, child: CircleAvatar(radius: 3, backgroundColor: cs.tertiary)),
        ]),
      ),
    );
  }

  Widget grid(ColorScheme cs) {
    final ds = viewDays();
    final off = (ds.first.weekday - 6) % 7; // hafta Cumartesi'den başlar
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 7; i++)
          Center(child: Text(dn[(5 + i) % 7], style: const TextStyle(fontSize: 11), textAlign: TextAlign.center)),
        for (var i = 0; i < off; i++) const SizedBox(),
        for (final d in ds) cell(d, cs),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (city == null) {
      return Scaffold(
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text('Adım: $step'),
                    if (err.isNotEmpty) SelectableText(err, style: const TextStyle(color: Colors.red)),
                  ]))));
    }
    final tm = calc(sel, city!.lat, city!.lng);
    final j = toJ(sel);
    final cs = Theme.of(context).colorScheme;
    final title = qam ? '${hn[vm - 1]} $vy' : (jal ? '${mj[vm - 1]} $vy' : '${mg[vm - 1]} $vy');
    final hs = toH(sel, lunarAdj);
    final dayTitle = qam
        ? '${hs[2]} ${hn[hs[1] - 1]} ${hs[0]}'
        : (jal ? '${j[2]} ${mj[j[1] - 1]} ${j[0]}' : '${sel.day} ${mg[sel.month - 1]} ${sel.year}');
    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: ListView(children: [
            const ListTile(
                title: Text('تورک تقویمی و اذانی', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), subtitle: Text('v1.0')),
            const Divider(),
            ListTile(
                leading: const Icon(Icons.nightlight_round),
                title: const Tx('Vakit ayarları'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const PrayerSettingsPage()));
                }),
            ListTile(
                leading: const Icon(Icons.alarm),
                title: const Tx('Çalar saat'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ClockPage()));
                }),
            ListTile(
                leading: const Icon(Icons.explore),
                title: const Tx('Kıble'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => QiblaPage(lat: city!.lat, lng: city!.lng, name: city!.name)));
                }),
            const Divider(),
            ListTile(
                leading: const Icon(Icons.warning_amber_rounded, color: Colors.red),
                title: const Tx('Ezan ve tarih bildirimi sorunları', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => TroublePage(onReset: () async {
                                await schedule(city!);
                                if (mounted) setState(() => msg = T('Ezan 14 gün için kuruldu'));
                              })));
                }),
            ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Tx('Hakkında'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage()));
                }),
          ]),
        ),
      ),
      appBar: AppBar(title: const Text('تورک تقویمی و اذانی'), actions: [
        IconButton(
            icon: const Icon(Icons.explore),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => QiblaPage(lat: city!.lat, lng: city!.lng, name: city!.name)))),
        IconButton(icon: const Icon(Icons.access_time), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ClockPage()))),
        IconButton(icon: const Icon(Icons.settings), onPressed: openSettings),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Tx('Miladi')),
            ButtonSegment(value: 1, label: Tx('Şemsî')),
            ButtonSegment(value: 2, label: Tx('Kameri')),
          ],
          selected: {jal ? 1 : (qam ? 2 : 0)},
          onSelectionChanged: (s) async {
            final v = s.first;
            jal = v == 1;
            qam = v == 2;
            setView(sel);
            setState(() {});
            try {
              final p = await SharedPreferences.getInstance();
              await p.setInt('cal', v);
            } catch (_) {}
          },
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => stepMonth(-1)),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => stepMonth(1)),
        ]),
        grid(cs),
        const Divider(),
        Text(dayTitle, style: Theme.of(context).textTheme.titleMedium),
        if (jal && showQamari) Text('${T('Hicri Kameri')}: ${hs[2]} ${hn[hs[1] - 1]} ${hs[0]}'),
        if (qam) Text('${T('Hicri Şemsî')}: ${j[2]} ${mj[j[1] - 1]} ${j[0]}'),
        if (showEvents)
          for (final e in eventsFor(sel, jal, qam))
          ListTile(
            dense: true,
            leading: Icon(e.contains('★') ? Icons.celebration : Icons.event_note, color: e.contains('★') ? cs.error : null),
            title: Text(e.replaceAll('★', '')),
          ),
        if (showTimes) timesBlock(tm, cs),
        if (showNote)
        TextFormField(
          key: ValueKey(dkey(sel)),
          initialValue: notes[dkey(sel)] ?? '',
          maxLines: 3,
          decoration: InputDecoration(labelText: T('Not'), border: OutlineInputBorder()),
          onChanged: (v) {
            if (v.trim().isEmpty) {
              notes.remove(dkey(sel));
            } else {
              notes[dkey(sel)] = v;
            }
            saveNotes();
          },
        ),
        const SizedBox(height: 12),
        ListTile(leading: const Icon(Icons.location_on), title: Text(city!.name), subtitle: Text(city!.group), onTap: pickCity),
        FilledButton(onPressed: test, child: const Tx('Ezanı 10 saniye sonra dene')),
        Padding(padding: const EdgeInsets.only(top: 12), child: Text(msg)),
        if (err.isNotEmpty) SelectableText(err, style: const TextStyle(color: Colors.red)),
      ]),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final int section;
  const SettingsPage({super.key, required this.section});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  Future<void> saveTheme(ThemeMode m) async {
    themeMode.value = m;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('theme', m == ThemeMode.dark ? 'dark' : (m == ThemeMode.light ? 'light' : 'system'));
    } catch (_) {}
    setState(() {});
  }

  Future<void> pickPreset(int i) async {
    final p = presets[i];
    themeId.value = i;
    seedColor.value = Color(p.seed);
    if (p.amoled) themeMode.value = ThemeMode.dark;
    try {
      final pr = await SharedPreferences.getInstance();
      await pr.setInt('themeId', i);
      await pr.setInt('seed', p.seed);
      if (p.amoled) await pr.setString('theme', 'dark');
    } catch (_) {}
    setState(() {});
  }

  Future<void> saveSeed(int c) async {
    seedColor.value = Color(c);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('seed', c);
    } catch (_) {}
    setState(() {});
  }

  Future<void> setLadj(int v) async {
    lunarAdj = v.clamp(-2, 2).toInt();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('ladj', lunarAdj);
    } catch (_) {}
    setState(() {});
  }

  Future<void> toggle(int i, bool on) async {
    if (on) {
      if (!adhanIdx.contains(i)) adhanIdx.add(i);
    } else {
      adhanIdx.remove(i);
    }
    adhanIdx.sort();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('adhan', adhanIdx.map((e) => e.toString()).toList());
    } catch (_) {}
    setState(() {});
  }

  Widget flag(String title, String k, bool v, void Function(bool) set) =>
      SwitchListTile(title: Text(title), value: v, onChanged: (x) async {
        set(x);
        await saveBool(k, x);
        setState(() {});
      });

  @override
  Widget build(BuildContext context) {
    final titles = ['', T('Vakit ayarları'), T('Ana sayfa ve bildirimler'), T('Renk seçimi')];
    final List<Widget> body;
    if (widget.section == 1) {
      body = [
        const ListTile(title: Text('Ezan çalacak vakitler')),
        for (var i = 0; i < 8; i++) SwitchListTile(title: Text(names[i]), value: adhanIdx.contains(i), onChanged: (v) => toggle(i, v)),
        const Divider(),
        ListTile(
          title: const Tx('Hicri Kameri düzeltme (İran)'),
          subtitle: const Tx('Dini günler hesapla bulunur, resmi ilandan 1 gün farklı olabilir'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.remove), onPressed: () => setLadj(lunarAdj - 1)),
            Text('$lunarAdj'),
            IconButton(icon: const Icon(Icons.add), onPressed: () => setLadj(lunarAdj + 1)),
          ]),
        ),
      ];
    } else if (widget.section == 2) {
      body = [
        const ListTile(title: Tx('Ana sayfada göster')),
        flag(T('Vakit listesi'), 'showTimes', showTimes, (x) => showTimes = x),
        flag(T('Günün olayları ve tatiller'), 'showEvents', showEvents, (x) => showEvents = x),
        flag(T('Hicri Kameri tarih'), 'showQamari', showQamari, (x) => showQamari = x),
        flag(T('Not kutusu'), 'showNote', showNote, (x) => showNote = x),
        const Divider(),
        const ListTile(title: Tx('Bildirimler')),
        flag(T('Ezan bildiriminde tarihi göster'), 'notifDate', notifDate, (x) => notifDate = x),
        flag(T('Bildirimde takvimi göster'), 'calNotif', showCalNotif, (x) => showCalNotif = x),
        flag(T('Bildirim çubuğunda bugünün tarihini göster'), 'dateNotif', showDateNotif, (x) => showDateNotif = x),
      ];
    } else {
      body = [
        const ListTile(title: Tx('Tema')),
        RadioListTile<ThemeMode>(
            title: const Tx('Telefon ayarına göre'), value: ThemeMode.system, groupValue: themeMode.value, onChanged: (m) => saveTheme(m!)),
        RadioListTile<ThemeMode>(
            title: const Tx('Gündüz'), value: ThemeMode.light, groupValue: themeMode.value, onChanged: (m) => saveTheme(m!)),
        RadioListTile<ThemeMode>(
            title: const Tx('Gece'), value: ThemeMode.dark, groupValue: themeMode.value, onChanged: (m) => saveTheme(m!)),
        const Divider(),
        const ListTile(title: Tx('Hazır temalar')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            for (var i = 0; i < presets.length; i++)
              GestureDetector(
                onTap: () => pickPreset(i),
                child: Container(
                  width: 150,
                  height: 84,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [for (final c in presets[i].pv) Color(c)]),
                    borderRadius: BorderRadius.circular(16),
                    border: themeId.value == i ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
                    boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.bottomStart,
                    child: Text(T(presets[i].key),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 3, color: Colors.black87)])),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        const Divider(),
        const ListTile(title: Tx('Ana renk')),
        Wrap(children: [
          for (final c in seeds)
            GestureDetector(
              onTap: () => saveSeed(c),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: CircleAvatar(
                    radius: 22,
                    backgroundColor: Color(c),
                    child: seedColor.value.value == c ? const Icon(Icons.check, color: Colors.white) : null),
              ),
            ),
        ]),
      ];
    }
    return Scaffold(appBar: AppBar(title: Text(titles[widget.section])), body: ListView(children: body));
  }
}

class CityPage extends StatefulWidget {
  final List<City> cities;
  final City? current;
  const CityPage({super.key, required this.cities, this.current});
  @override
  State<CityPage> createState() => _CityState();
}

class _CityState extends State<CityPage> with SingleTickerProviderStateMixin {
  late final TabController tc = TabController(length: 3, vsync: this);
  late String prov, country, irCity, foCity;
  final nameC = TextEditingController(), latC = TextEditingController(), lngC = TextEditingController();

  List<String> irNames(String p) => [for (final c in widget.cities) if (c.group == 'İran' && irProv[c.name] == p) c.name];
  List<String> foNames(String g) => ([for (final c in widget.cities) if (c.group == g) c.name]..sort());

  @override
  void initState() {
    super.initState();
    final cur = widget.current;
    final iran = cur != null && cur.group == 'İran';
    prov = (iran ? irProv[cur!.name] : null) ?? 'آذربایجان غربی';
    irCity = (iran && irNames(prov).contains(cur!.name)) ? cur.name : irNames(prov).first;
    country = (cur != null && cur.group != 'İran') ? cur.group : 'Türkiye';
    foCity = (cur != null && foNames(country).contains(cur.name)) ? cur.name : foNames(country).first;
    if (cur != null && cur.group != 'İran') tc.index = 1;
  }

  @override
  void dispose() {
    tc.dispose();
    nameC.dispose();
    latC.dispose();
    lngC.dispose();
    super.dispose();
  }

  void done(String group, String name) => Navigator.pop(context, widget.cities.firstWhere((c) => c.group == group && c.name == name));

  void saveCustom() {
    final la = double.tryParse(latC.text.replaceAll(',', '.')), lo = double.tryParse(lngC.text.replaceAll(',', '.'));
    if (nameC.text.trim().isEmpty || la == null || lo == null || la.abs() > 66 || lo.abs() > 180) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tx('Ad, enlem (−66 ile 66) ve boylam (−180 ile 180) gerekli')));
      return;
    }
    Navigator.pop(context, City('Özel', nameC.text.trim(), la, lo));
  }

  Widget drop(String label, String value, List<String> items, void Function(String) on) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: [for (final x in items) DropdownMenuItem(value: x, child: Text(x))],
          onChanged: (v) => on(v!),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final provs = irProv.values.toSet().toList()..sort();
    final countries = widget.cities.map((c) => c.group).where((g) => g != 'İran').toSet().toList();
    return Scaffold(
      appBar: AppBar(
        title: const Tx('Şehir seçimi'),
        bottom: TabBar(controller: tc, tabs: const [Tab(child: Tx('Yerli şehir')), Tab(child: Tx('Yabancı şehir')), Tab(child: Tx('Yeni şehir'))]),
      ),
      body: TabBarView(controller: tc, children: [
        ListView(padding: const EdgeInsets.all(16), children: [
          drop(T('Eyalet'), prov, provs, (v) => setState(() {
                prov = v;
                irCity = irNames(v).first;
              })),
          drop(T('Şehir'), irCity, irNames(prov), (v) => setState(() => irCity = v)),
          FilledButton(onPressed: () => done('İran', irCity), child: const Tx('Kaydet')),
          TextButton(onPressed: () => tc.animateTo(2), child: const Tx('Şehrim listede yok')),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          drop(T('Ülke'), country, countries, (v) => setState(() {
                country = v;
                foCity = foNames(v).first;
              })),
          drop(T('Şehir'), foCity, foNames(country), (v) => setState(() => foCity = v)),
          FilledButton(onPressed: () => done(country, foCity), child: const Tx('Kaydet')),
          TextButton(onPressed: () => tc.animateTo(2), child: const Tx('Şehrim listede yok')),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: nameC, decoration: InputDecoration(labelText: T('Şehir adı'), border: OutlineInputBorder()))),
          Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: latC, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: InputDecoration(labelText: T('Enlem (ör. 36.5)'), border: OutlineInputBorder()))),
          Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: lngC, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: InputDecoration(labelText: T('Boylam (ör. 46.15)'), border: OutlineInputBorder()))),
          FilledButton(onPressed: saveCustom, child: const Tx('Kaydet')),
        ]),
      ]),
    );
  }
}

class PrayerSettingsPage extends StatefulWidget {
  const PrayerSettingsPage({super.key});
  @override
  State<PrayerSettingsPage> createState() => _PrayerSettingsState();
}

class _PrayerSettingsState extends State<PrayerSettingsPage> {
  static const five = [0, 2, 3, 5, 6];

  void upd(VoidCallback f) {
    setState(f);
    saveAdhanPrefs();
  }

  Future<void> pickMuezzin(int i) async {
    final r = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(title: Text(names[i]), children: [
              for (final e in muez) SimpleDialogOption(onPressed: () => Navigator.pop(c, e[0]), child: Text(e[1])),
            ]));
    if (r != null) upd(() => snd[i] = r);
  }

  Future<void> testPrayer(int i) async {
    try {
      await sched(9990 + i, names[i], T('10 saniye sonra ezan çalmalı'), tz.TZDateTime.now(tz.local).add(const Duration(seconds: 10)), adhanDetails(resFor(i)));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(T('10 saniye sonra ezan çalmalı'))));
    } catch (_) {}
  }

  String label(int i) {
    final r = snd[i] ?? defSound();
    return muez.firstWhere((e) => e[0] == r, orElse: () => [r, r])[1];
  }

  Widget sw(int i, List<int> list) => SwitchListTile(
      title: Text(names[i]),
      value: list.contains(i),
      onChanged: (v) => upd(() {
            if (v) {
              if (!list.contains(i)) list.add(i);
            } else {
              list.remove(i);
            }
            list.sort();
          }));

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
            title: const Tx('Vakit ayarları'), bottom: const TabBar(tabs: [Tab(child: Tx('Ezan')), Tab(child: Tx('Ezan öncesi uyarı'))])),
        body: TabBarView(children: [
          ListView(padding: const EdgeInsets.all(8), children: [
            Padding(
                padding: const EdgeInsets.all(8),
                child: DropdownButtonFormField<int>(
                  value: methodIdx,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: T('Hesaplama yöntemi'), border: OutlineInputBorder()),
                  items: [for (var i = 0; i < methods.length; i++) DropdownMenuItem(value: i, child: Text(methods[i].name))],
                  onChanged: (v) => upd(() => methodIdx = v!),
                )),
            const ListTile(title: Tx('Ezan otomatik çalsın')),
            for (final i in five) sw(i, adhanIdx),
            const Divider(),
            const ListTile(title: Tx('Müezzin')),
            for (final i in five)
              ListTile(title: Text(names[i]), trailing: FilledButton.tonal(onPressed: () => pickMuezzin(i), child: Text(label(i)))),
            const Divider(),
            const ListTile(title: Tx('Ezan ses seviyesi'), subtitle: Tx('Ses seviyesi telefonun alarm sesiyle birlikte çalışır')),
            for (final i in five)
              ListTile(
                title: Text(names[i]),
                subtitle: Slider(
                    value: volLevels.indexOf(vol[i] ?? 100).toDouble(),
                    min: 0,
                    max: 4,
                    divisions: 4,
                    label: '${vol[i] ?? 100}%',
                    onChanged: (v) => upd(() => vol[i] = volLevels[v.round()])),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${vol[i] ?? 100}%'),
                  IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => testPrayer(i)),
                ]),
              ),
            const Divider(),
            ListTile(
              title: const Tx('Hicri Kameri düzeltme (İran)'),
              subtitle: const Tx('Dini günler hesapla bulunur, resmi ilandan 1 gün farklı olabilir'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.remove), onPressed: () => upd(() => lunarAdj = (lunarAdj - 1).clamp(-2, 2).toInt())),
                Text('$lunarAdj'),
                IconButton(icon: const Icon(Icons.add), onPressed: () => upd(() => lunarAdj = (lunarAdj + 1).clamp(-2, 2).toInt())),
              ]),
            ),
          ]),
          ListView(children: [
            const ListTile(title: Tx('Ezandan önce uyarı ver')),
            for (final i in five) sw(i, remindIdx),
            ListTile(
              title: const Tx('Kaç dakika önce'),
              trailing: DropdownButton<int>(
                value: remindMin,
                items: [for (final x in [5, 10, 15, 20, 30]) DropdownMenuItem(value: x, child: Text('$x ${T('dk')}'))],
                onChanged: (v) => upd(() => remindMin = v!),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key});
  @override
  State<LanguagePage> createState() => _LangState();
}

class _LangState extends State<LanguagePage> {
  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('lang', langIdx);
      await p.setInt('nlang', nameIdx);
    } catch (_) {}
  }

  void setUi(int i) {
    langIdx = i;
    langRev.value++;
    save();
    setState(() {});
  }

  void setNames(int i) {
    nameIdx = i;
    applyNames();
    langRev.value++;
    save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Tx('Dil')),
      body: ListView(children: [
        const ListTile(title: Tx('Uygulama dili')),
        for (var i = 0; i < langNames.length; i++)
          RadioListTile<int>(title: Text(langNames[i]), value: i, groupValue: langIdx, onChanged: (v) => setUi(v!)),
        const Divider(),
        const ListTile(title: Tx('Ay, gün ve vakit adlarının dili')),
        for (var i = 0; i < langNames.length; i++)
          RadioListTile<int>(title: Text(langNames[i]), value: i, groupValue: nameIdx, onChanged: (v) => setNames(v!)),
      ]),
    );
  }
}

class ClockPainter extends CustomPainter {
  final DateTime t;
  final Color c, accent;
  ClockPainter(this.t, this.c, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final ctr = size.center(Offset.zero);
    final r = size.width / 2 - 6;
    canvas.drawCircle(ctr, r, Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = 4);
    final tick = Paint()..color = c..strokeWidth = 3;
    for (var i = 0; i < 12; i++) {
      final a = i * m.pi / 6;
      final d = Offset(m.sin(a), -m.cos(a));
      canvas.drawLine(ctr + d * (r - 14), ctr + d * (r - 4), tick);
    }
    void hand(double ang, double len, double w, Color col) {
      canvas.drawLine(ctr, ctr + Offset(m.sin(ang), -m.cos(ang)) * len, Paint()..color = col..strokeWidth = w..strokeCap = StrokeCap.round);
    }

    hand((t.hour % 12 + t.minute / 60) * m.pi / 6, r * .5, 6, c);
    hand((t.minute + t.second / 60) * m.pi / 30, r * .75, 4, c);
    hand(t.second * m.pi / 30, r * .85, 2, accent);
    canvas.drawCircle(ctr, 6, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(ClockPainter o) => true;
}

class ClockPage extends StatefulWidget {
  const ClockPage({super.key});
  @override
  State<ClockPage> createState() => _ClockState();
}

class _ClockState extends State<ClockPage> {
  Timer? tick;
  DateTime now = DateTime.now();

  @override
  void initState() {
    super.initState();
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => now = DateTime.now());
    });
  }

  @override
  void dispose() {
    tick?.cancel();
    super.dispose();
  }

  String two(int v) => v.toString().padLeft(2, '0');

  Future<void> changed() async {
    await persistAlarms();
    try {
      await scheduleAlarms();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> addAlarm() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (t == null) return;
    alarms.add(Alarm(t.hour, t.minute, true));
    await changed();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Tx('Çalar saat')),
      floatingActionButton: FloatingActionButton(onPressed: addAlarm, child: const Icon(Icons.add_alarm)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Tx('Analog')),
            ButtonSegment(value: 1, label: Tx('Dijital')),
            ButtonSegment(value: 2, label: Tx('İkisi birden')),
          ],
          selected: {clockMode},
          onSelectionChanged: (s) async {
            clockMode = s.first;
            setState(() {});
            try {
              final p = await SharedPreferences.getInstance();
              await p.setInt('clockMode', clockMode);
            } catch (_) {}
          },
        ),
        const SizedBox(height: 16),
        if (clockMode != 1) Center(child: SizedBox(width: 260, height: 260, child: CustomPaint(painter: ClockPainter(now, cs.onSurface, cs.primary)))),
        if (clockMode != 0)
          Center(child: Text('${two(now.hour)}:${two(now.minute)}:${two(now.second)}', style: Theme.of(context).textTheme.displayMedium)),
        const SizedBox(height: 8),
        Center(child: Text('${wdn[now.weekday - 1]} - ${dateText0(now)}', textAlign: TextAlign.center)),
        const Divider(height: 32),
        if (alarms.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Center(child: Tx('Henüz alarm yok'))),
        for (var i = 0; i < alarms.length; i++)
          ListTile(
            title: Text('${two(alarms[i].h)}:${two(alarms[i].m)}', style: const TextStyle(fontSize: 28)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(
                  value: alarms[i].on,
                  onChanged: (v) {
                    alarms[i].on = v;
                    changed();
                  }),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    alarms.removeAt(i);
                    changed();
                  }),
            ]),
          ),
        const SizedBox(height: 72),
      ]),
    );
  }
}

class QiblaPainter extends CustomPainter {
  final double heading, qibla;
  final Color c, accent;
  final bool aligned;
  QiblaPainter(this.heading, this.qibla, this.c, this.accent, this.aligned);

  void letter(Canvas canvas, String t, double r, Color col) {
    final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(color: col, fontSize: 20, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(-tp.width / 2, -r - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - 24;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-heading * m.pi / 180);
    canvas.drawCircle(Offset.zero, r, Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = 4);
    for (var i = 0; i < 36; i++) {
      canvas.save();
      canvas.rotate(i * m.pi / 18);
      final len = i % 9 == 0 ? 16.0 : (i % 3 == 0 ? 11.0 : 6.0);
      canvas.drawLine(Offset(0, -r), Offset(0, -r + len), Paint()..color = c..strokeWidth = 2);
      canvas.restore();
    }
    letter(canvas, 'N', r + 14, Colors.red);
    canvas.save();
    canvas.rotate(m.pi / 2);
    letter(canvas, 'E', r + 14, c);
    canvas.restore();
    canvas.save();
    canvas.rotate(m.pi);
    letter(canvas, 'S', r + 14, c);
    canvas.restore();
    canvas.save();
    canvas.rotate(-m.pi / 2);
    letter(canvas, 'W', r + 14, c);
    canvas.restore();
    // Kıble oku
    canvas.rotate(qibla * m.pi / 180);
    final col = aligned ? Colors.green : accent;
    canvas.drawLine(Offset.zero, Offset(0, -r + 30), Paint()..color = col..strokeWidth = 6..strokeCap = StrokeCap.round);
    final path = Path()
      ..moveTo(0, -r + 6)
      ..lineTo(-16, -r + 40)
      ..lineTo(16, -r + 40)
      ..close();
    canvas.drawPath(path, Paint()..color = col);
    canvas.drawRect(Rect.fromCenter(center: Offset(0, -r - 26), width: 26, height: 26), Paint()..color = Colors.black87);
    canvas.drawRect(Rect.fromCenter(center: Offset(0, -r - 31), width: 26, height: 5), Paint()..color = const Color(0xFFD6A038));
    canvas.restore();
    // telefonun baktığı yön (sabit işaret)
    final p = Path()
      ..moveTo(size.width / 2, 4)
      ..lineTo(size.width / 2 - 10, 24)
      ..lineTo(size.width / 2 + 10, 24)
      ..close();
    canvas.drawPath(p, Paint()..color = col);
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 6, Paint()..color = col);
  }

  @override
  bool shouldRepaint(QiblaPainter o) => true;
}

class QiblaPage extends StatefulWidget {
  final double lat, lng;
  final String name;
  const QiblaPage({super.key, required this.lat, required this.lng, required this.name});
  @override
  State<QiblaPage> createState() => _QiblaState();
}

class _QiblaState extends State<QiblaPage> {
  bool wasAligned = false;

  @override
  Widget build(BuildContext context) {
    final q = qiblaBearing(widget.lat, widget.lng);
    final km = kaabaKm(widget.lat, widget.lng).round();
    final cs = Theme.of(context).colorScheme;
    final stream = FlutterCompass.events;
    return Scaffold(
      appBar: AppBar(title: const Tx('Kıble')),
      body: stream == null
          ? ListView(padding: const EdgeInsets.all(24), children: [
              const SizedBox(height: 40),
              Center(child: Text('${q.toStringAsFixed(1)}°', style: Theme.of(context).textTheme.displayMedium)),
              const SizedBox(height: 16),
              const Center(child: Tx('Pusula sensörü bulunamadı')),
            ])
          : StreamBuilder<CompassEvent>(
              stream: stream,
              builder: (context, snap) {
                final raw = snap.data?.heading;
                final h = raw == null ? 0.0 : (raw + 360) % 360;
                var diff = (q - h).abs() % 360;
                if (diff > 180) diff = 360 - diff;
                final aligned = raw != null && diff < 4;
                if (aligned && !wasAligned) HapticFeedback.mediumImpact();
                wasAligned = aligned;
                return ListView(padding: const EdgeInsets.all(16), children: [
                  Center(child: Text(widget.name, style: Theme.of(context).textTheme.titleMedium)),
                  const SizedBox(height: 8),
                  Center(child: SizedBox(width: 320, height: 320, child: CustomPaint(painter: QiblaPainter(h, q, cs.onSurface, cs.primary, aligned)))),
                  const SizedBox(height: 8),
                  Center(child: Text('${q.toStringAsFixed(1)}°', style: Theme.of(context).textTheme.displaySmall)),
                  Center(child: Text('${T('Kâbe\'ye uzaklık')}: $km km')),
                  const SizedBox(height: 12),
                  Center(
                      child: aligned
                          ? Text(T('Kıble yönündesiniz'), style: const TextStyle(color: Colors.green, fontSize: 18, fontWeight: FontWeight.bold))
                          : Text(T('Pusulayı kalibre etmek için telefonu 8 şeklinde hareket ettirin'), textAlign: TextAlign.center)),
                ]);
              },
            ),
    );
  }
}

class TextSizePage extends StatefulWidget {
  const TextSizePage({super.key});
  @override
  State<TextSizePage> createState() => _TextSizeState();
}

class _TextSizeState extends State<TextSizePage> {
  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('tscale', textScale.value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Tx('Yazı boyutu')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          const Text('A', style: TextStyle(fontSize: 14)),
          Expanded(
              child: Slider(
                  value: textScale.value,
                  min: 0.8,
                  max: 1.8,
                  divisions: 10,
                  label: '${(textScale.value * 100).round()}%',
                  onChanged: (v) {
                    textScale.value = v;
                    setState(() {});
                  },
                  onChangeEnd: (_) => save())),
          const Text('A', style: TextStyle(fontSize: 26)),
        ]),
        Center(child: Text('${(textScale.value * 100).round()}%')),
        const SizedBox(height: 16),
        const Card(child: Padding(padding: EdgeInsets.all(16), child: Tx('Örnek metin: Ezan vakitleri ve takvim'))),
        TextButton(
            onPressed: () {
              textScale.value = 1.0;
              setState(() {});
              save();
            },
            child: const Tx('Sıfırla')),
      ]),
    );
  }
}

class TroublePage extends StatelessWidget {
  final Future<void> Function() onReset;
  const TroublePage({super.key, required this.onReset});

  Widget step(String text, String action, {String? data, Map<String, dynamic>? args}) => Card(
        child: ListTile(
          title: Text(T(text)),
          trailing: FilledButton.tonal(onPressed: () => openSys(action, data: data, args: args), child: const Tx('Aç')),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Tx('Ezan ve tarih bildirimi sorunları')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        step('Bildirim iznini açın', 'android.settings.APP_NOTIFICATION_SETTINGS', args: {'android.provider.extra.APP_PACKAGE': appPkg}),
        step('Alarm ve hatırlatıcı iznini açın', 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM', data: 'package:$appPkg'),
        step('Pil kullanımını "Kısıtlama yok" yapın', 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS'),
        step('Alarm sesinin kapalı olmadığından emin olun', 'android.settings.SOUND_SETTINGS'),
        step('Uygulamanın arka planda çalışmasına izin verin (Xiaomi, Huawei, Samsung)', 'android.settings.APPLICATION_DETAILS_SETTINGS', data: 'package:$appPkg'),
        const SizedBox(height: 12),
        FilledButton(
            onPressed: () async {
              await onReset();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(T('Ezan 14 gün için kuruldu'))));
            },
            child: const Tx('Bildirimleri yeniden kur')),
      ]),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Tx('Hakkında')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          const SizedBox(height: 24),
          const Text('تورک تقویمی و اذانی', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('${T('Sürüm')} 1.0'),
          const SizedBox(height: 16),
          const Tx('Takvim, ezan vakitleri, kıble ve çalar saat', style: TextStyle(fontSize: 16)),
        ]),
      ),
    );
  }
}

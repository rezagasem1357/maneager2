import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:arabic_reshaper/arabic_reshaper.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'network/network_connection_screen.dart';
import 'network/network_service.dart';
import 'dart:async';

final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

// ==================== ابزارهای تاریخ و خوش‌آمدگویی ====================

List<int> _gregorianToJalali(int gy, int gm, int gd) {
  const gDaysInMonth = <int>[
    0,
    31,
    59,
    90,
    120,
    151,
    181,
    212,
    243,
    273,
    304,
    334
  ];

  int jy;
  int gy2;
  if (gy > 1600) {
    jy = 979;
    gy2 = gy - 1600;
  } else {
    jy = 0;
    gy2 = gy - 621;
  }

  var days = 365 * gy2 +
      ((gy2 + 3) ~/ 4) -
      ((gy2 + 99) ~/ 100) +
      ((gy2 + 399) ~/ 400) -
      80 +
      gd +
      gDaysInMonth[gm - 1];

  final isLeapGregorian = (gy % 4 == 0 && gy % 100 != 0) || (gy % 400 == 0);
  if (gm > 2 && isLeapGregorian) days++;

  jy += 33 * (days ~/ 12053);
  days %= 12053;

  jy += 4 * (days ~/ 1461);
  days %= 1461;

  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }

  final jm = days < 186 ? 1 + (days ~/ 31) : 7 + ((days - 186) ~/ 30);
  final jd = 1 + (days < 186 ? days % 31 : (days - 186) % 30);

  return [jy, jm, jd];
}

String _toPersianDigits(String value) {
  const latin = '0123456789';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  var result = value;
  for (var i = 0; i < latin.length; i++) {
    result = result.replaceAll(latin[i], persian[i]);
  }
  return result;
}

String _todayJalali() {
  final now = DateTime.now();
  final j = _gregorianToJalali(now.year, now.month, now.day);
  return '${_toPersianDigits(j[0].toString())}/${_toPersianDigits(j[1].toString().padLeft(2, '0'))}/${_toPersianDigits(j[2].toString().padLeft(2, '0'))}';
}

String _todayJalaliLong() {
  final now = DateTime.now();
  final j = _gregorianToJalali(now.year, now.month, now.day);
  const weekdays = [
    '',
    'دوشنبه',
    'سه‌شنبه',
    'چهارشنبه',
    'پنجشنبه',
    'جمعه',
    'شنبه',
    'یکشنبه',
  ];
  const months = [
    '',
    'فروردین',
    'اردیبهشت',
    'خرداد',
    'تیر',
    'مرداد',
    'شهریور',
    'مهر',
    'آبان',
    'آذر',
    'دی',
    'بهمن',
    'اسفند',
  ];

  final weekday = weekdays[now.weekday];
  return '$weekday ${_toPersianDigits(j[2].toString())} ${months[j[1]]} ${_toPersianDigits(j[0].toString())}';
}

String _greetingByHour(int hour) {
  if (hour >= 5 && hour < 12) return 'صبح بخیر';
  if (hour >= 12 && hour < 18) return 'ظهر بخیر';
  return 'شب بخیر';
}

String _jalaliLongForDate(DateTime date) {
  final j = _gregorianToJalali(date.year, date.month, date.day);
  const weekdays = [
    '',
    'دوشنبه',
    'سه‌شنبه',
    'چهارشنبه',
    'پنجشنبه',
    'جمعه',
    'شنبه',
    'یکشنبه',
  ];
  const months = [
    '',
    'فروردین',
    'اردیبهشت',
    'خرداد',
    'تیر',
    'مرداد',
    'شهریور',
    'مهر',
    'آبان',
    'آذر',
    'دی',
    'بهمن',
    'اسفند',
  ];
  return '${weekdays[date.weekday]} ${_toPersianDigits(j[2].toString())} ${months[j[1]]} ${_toPersianDigits(j[0].toString())}';
}

int _daysRemainingForRecurringEvent({
  required DateTime lastDate,
  required int intervalDays,
  required DateTime date,
}) {
  final today = DateTime(date.year, date.month, date.day);
  var next = DateTime(lastDate.year, lastDate.month, lastDate.day)
      .add(Duration(days: intervalDays));

  // اگر تاریخ دوره قبلی گذشته باشد، چرخه را تا اولین دوره آینده جلو می‌بریم.
  while (next.isBefore(today)) {
    next = next.add(Duration(days: intervalDays));
  }

  return next.difference(today).inDays;
}

// انبارگردانی هر ۴۰ روز یک‌بار است. در اولین اجرای این نسخه،
// تاریخ پایه طوری تنظیم می‌شود که ۲۱ روز تا دوره بعد باقی بماند.
int _inventoryDaysRemainingForDate(DateTime date, {DateTime? lastDate}) {
  final base = lastDate ?? date.subtract(const Duration(days: 19));
  return _daysRemainingForRecurringEvent(
    lastDate: base,
    intervalDays: 40,
    date: date,
  );
}

// نظافت هر ۳۰ روز یک‌بار است. در اولین اجرای این نسخه،
// دوره بعدی ۳۰ روز دیگر خواهد بود.
int _cleaningDaysRemainingForDate(DateTime date, {DateTime? lastDate}) {
  final base = lastDate ?? date;
  return _daysRemainingForRecurringEvent(
    lastDate: base,
    intervalDays: 30,
    date: date,
  );
}

// ==================== ابزارهای فرمت قیمت ====================

String _formatPrice(int price) {
  return price.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (match) => '${match[1]},',
      );
}

String _displayPrice(int price) {
  return '${_formatPrice(price)} ریال';
}

String _normalizeSearchText(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll('ك', 'ک')
      .replaceAll('ي', 'ی')
      .replaceAll('ى', 'ی')
      .replaceAll('ۀ', 'ه')
      .replaceAll('ة', 'ه')
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ی')
      .replaceAll(RegExp(r'[\u200c\u200f\u200e\u0640\u064B-\u065F\u0670]'), '')
      .replaceAll(RegExp(r'\s+'), '');
}

// ==================== تابع بارگذاری فونت برای PDF ====================

Future<pw.Font> _loadFont() async {
  try {
    final fontData = await rootBundle.load('assets/fonts/Vazir.ttf');
    return pw.Font.ttf(fontData.buffer.asByteData());
  } catch (e) {
    return pw.Font.helvetica();
  }
}

String _pdfText(String value) {
  final cleaned =
      value.replaceAll(RegExp(r'[📦📅📋💰🛒📊💳📌🚚🧾👤🛍️📄]'), '').trim();
  return ArabicReshaper.instance.reshape(cleaned);
}

pw.Widget _pdfTextWidget(
  String value,
  pw.Font font, {
  double? fontSize,
  pw.FontWeight? fontWeight,
  PdfColor? color,
  pw.TextAlign? textAlign,
}) {
  return pw.Text(
    _pdfText(value),
    textDirection: pw.TextDirection.rtl,
    textAlign: textAlign,
    style: pw.TextStyle(
      font: font,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
    ),
  );
}

pw.Widget _pdfCell(String text, pw.Font font,
        {bool bold = false, pw.TextAlign align = pw.TextAlign.center}) =>
    pw.Padding(
        padding: const pw.EdgeInsets.all(7),
        child: _pdfTextWidget(text, font,
            fontSize: 9,
            fontWeight: bold ? pw.FontWeight.bold : null,
            textAlign: align));

// متن مخصوص گزارش‌های قابل اشتراک: بدون reshape دوباره، چون pdf با
// textDirection: rtl ترتیب و شکل‌دهی حروف فارسی را خودش مدیریت می‌کند.
pw.Widget _pdfShareTextWidget(
  String value,
  pw.Font font, {
  double? fontSize,
  pw.FontWeight? fontWeight,
  PdfColor? color,
  pw.TextAlign? textAlign,
}) {
  final cleaned =
      value.replaceAll(RegExp(r'[📦📅📋💰🛒📊💳📌🚚🧾👤🛍️📄]'), '').trim();
  return pw.Text(
    cleaned,
    textDirection: pw.TextDirection.rtl,
    textAlign: textAlign,
    style: pw.TextStyle(
      font: font,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
    ),
  );
}

pw.Widget _pdfShareCell(
  String text,
  pw.Font font, {
  bool bold = false,
  double fontSize = 9,
  pw.TextAlign align = pw.TextAlign.center,
}) =>
    pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: _pdfShareTextWidget(
        text,
        font,
        fontSize: fontSize,
        fontWeight: bold ? pw.FontWeight.bold : null,
        textAlign: align,
      ),
    );

// ==================== سرویس اعلان‌ها ====================

class StoreNotificationService {
  StoreNotificationService._();
  static final StoreNotificationService instance = StoreNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static const String _logoAsset = 'assets/images/Logopit_1787568628075.png';
  static const String _enabledKey = 'notifications_enabled';
  static const String _limitedKey = 'limited_notifications_enabled';
  static const String _channelId = 'store_assistant_notifications';
  String? _logoPath;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/launcher_icon');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: darwin),
    );
    _initialized = true;
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_enabledKey) != true) return false;
    return _platformPermissionGranted();
  }

  Future<bool> _isLimitedMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_limitedKey) ?? false;
  }

  Future<bool> _platformPermissionGranted() async {
    await initialize();

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.areNotificationsEnabled() ?? false;
    }

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final details = await ios.checkPermissions();
      return details?.isEnabled ?? false;
    }

    return false;
  }

  Future<bool> enableNotifications() async {
    await initialize();

    var granted = true;

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final enabled = await android.areNotificationsEnabled();
      if (enabled != true) {
        granted = await android.requestNotificationsPermission() ?? false;
      }
    }

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final current = await ios.checkPermissions();
      if (current?.isEnabled != true) {
        granted = await ios.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
    }

    if (granted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, true);
    }

    return granted;
  }

  Future<void> disableNotifications() async {
    await initialize();
    await _plugin.cancel(2030);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
  }

  Future<String> _ensureLogoFile() async {
    if (_logoPath != null && await File(_logoPath!).exists()) {
      return _logoPath!;
    }
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/store_notification_logo.png');
    if (!await file.exists()) {
      final data = await rootBundle.load(_logoAsset);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    _logoPath = file.path;
    return file.path;
  }

  NotificationDetails _details({String? imagePath}) {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      'اعلان‌های فروشگاه',
      channelDescription: 'اعلان فعال‌سازی و ثبت فاکتور فروش',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      styleInformation: imagePath == null
          ? const BigTextStyleInformation('')
          : BigPictureStyleInformation(
              FilePathAndroidBitmap(imagePath),
              hideExpandedLargeIcon: false,
            ),
      largeIcon: imagePath == null ? null : FilePathAndroidBitmap(imagePath),
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      attachments: imagePath == null
          ? null
          : <DarwinNotificationAttachment>[
              DarwinNotificationAttachment(imagePath),
            ],
    );
    return NotificationDetails(android: androidDetails, iOS: iosDetails);
  }

  String _jalaliNumericForDate(DateTime date) {
    final j = _gregorianToJalali(date.year, date.month, date.day);
    return '${_toPersianDigits(j[0].toString())}/${_toPersianDigits(j[1].toString().padLeft(2, '0'))}/${_toPersianDigits(j[2].toString().padLeft(2, '0'))}';
  }

  String _weekdayForDate(DateTime date) {
    const weekdays = [
      '',
      'دوشنبه',
      'سه‌شنبه',
      'چهارشنبه',
      'پنجشنبه',
      'جمعه',
      'شنبه',
      'یکشنبه',
    ];
    return weekdays[date.weekday];
  }

  String _welcomeBody({
    required String userName,
    required String gender,
    required DateTime date,
  }) {
    final prefix = gender == 'female' ? 'خانم' : 'آقای';
    final greeting = _greetingByHour(date.hour);
    final remaining = _inventoryDaysRemainingForDate(date);
    final countdown = remaining == 0
        ? 'امروز زمان انبارگردانی است.'
        : '${_toPersianDigits(remaining.toString())} روز مانده تا انبارگردانی.';

    return 'سلام $prefix $userName، خوش آمدید 🌷\n'
        '$greeting\n'
        'امروز ${_weekdayForDate(date)} ${_jalaliNumericForDate(date)} است.\n'
        '⏳ $countdown';
  }

  Future<void> scheduleMorningNotifications({
    required String userName,
    required String gender,
    List<CustomEvent> customEvents = const [],
  }) async {
    await initialize();
    try {
      tz_data.initializeTimeZones();
      try {
        final timezoneInfo = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(timezoneInfo.toString()));
      } catch (_) {
        tz.setLocalLocation(tz.getLocation('Asia/Tehran'));
      }

      // جلوگیری از زمان‌بندی‌های تکراری
      for (var i = 0; i < 90; i++) {
        await _plugin.cancel(3000 + i);
      }

      final prefix = gender == 'female' ? 'خانم' : 'آقای';
      final now = tz.TZDateTime.now(tz.local);
      final details = _details();

      // ۹۰ روز آینده زمان‌بندی می‌شود؛ با ورود مجدد به برنامه دوباره تازه‌سازی خواهد شد.
      for (var i = 0; i < 90; i++) {
        final day = now.add(Duration(days: i));
        final scheduled = tz.TZDateTime(
          tz.local,
          day.year,
          day.month,
          day.day,
          8,
          30,
        );
        if (!scheduled.isAfter(now)) continue;

        final date = scheduled.toLocal();
        final remaining = _inventoryDaysRemainingForDate(date);
        final inventoryText = remaining == 0
            ? 'امروز زمان انبارگردانی است.'
            : '${_toPersianDigits(remaining.toString())} روز مانده تا انبارگردانی.';

        final eventReminders = <String>[];
        for (final event in customEvents) {
          final target = DateTime.tryParse(event.isoDate);
          if (target == null) continue;
          final targetDay = DateTime(target.year, target.month, target.day);
          final currentDay = DateTime(date.year, date.month, date.day);
          final days = targetDay.difference(currentDay).inDays;
          if (days >= 0 && days <= 90) {
            eventReminders.add(days == 0
                ? '📌 امروز ${event.name} است.'
                : '📌 ${event.name}: ${_toPersianDigits(days.toString())} روز مانده.');
          }
        }

        final body = 'صبح بخیر $prefix $userName 🌞\n'
            'امروز ${_weekdayForDate(date)} ${_jalaliNumericForDate(date)} است.\n'
            'امروز حالتان چطور است؟ 😊\n'
            '⏳ $inventoryText'
            '${eventReminders.isEmpty ? '' : '\n${eventReminders.take(3).join('\n')}'}';

        await _plugin.zonedSchedule(
          3000 + i,
          'فروشگاه فرهنگی مذهبی کریم اهل بیت (ع)',
          body,
          scheduled,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    } catch (_) {
      // خطای زمان‌بندی نباید اجرای برنامه را متوقف کند.
    }
  }

  Future<void> cancelMorningNotifications() async {
    await initialize();
    for (var i = 0; i < 90; i++) {
      await _plugin.cancel(3000 + i);
    }
  }

  Future<void> showActivationNotification() async {
    await initialize();
    await _plugin.show(
      1998,
      'فروشگاه فرهنگی مذهبی کریم اهل بیت (ع)',
      'سیستم اعلان فعال شد.',
      _details(),
    );
  }

  Future<void> showWelcomeNotification({
    required String userName,
    required String gender,
    DateTime? date,
  }) async {
    if (!await isEnabled()) return;
    final limited = await _isLimitedMode();
    final prefs = await SharedPreferences.getInstance();
    final todayKey = _toPersianDigits(_todayJalali());
    if (limited &&
        prefs.getString('welcome_notification_last_date') == todayKey) {
      return;
    }
    await initialize();
    final logoPath = await _ensureLogoFile();
    final now = date ?? DateTime.now();

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000000),
      'فروشگاه فرهنگی مذهبی کریم اهل بیت (ع)',
      _welcomeBody(
        userName: userName,
        gender: gender,
        date: now,
      ),
      _details(imagePath: logoPath),
    );
    if (limited) {
      await prefs.setString('welcome_notification_last_date', todayKey);
    }
  }

  Future<void> showDatabaseUpdateAvailable({required String storeName}) async {
    if (!await isEnabled()) return;
    await initialize();
    final logoPath = await _ensureLogoFile();
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000000),
      storeName.trim().isEmpty ? 'فروشگاه' : storeName.trim(),
      'بروزرسانی بانک اطلاعاتی موجود است',
      _details(imagePath: logoPath),
      payload: 'database_update_available',
    );
  }

  Future<void> showInvoiceRegistered({
    required String invoiceNumber,
    required int total,
    String? invoiceImagePath,
  }) async {
    if (!await isEnabled()) return;
    final limited = await _isLimitedMode();
    final prefs = await SharedPreferences.getInstance();
    final todayKey = _toPersianDigits(_todayJalali());
    if (limited &&
        prefs.getString('invoice_notification_last_date') == todayKey) {
      return;
    }
    await initialize();
    final imagePath = invoiceImagePath ?? await _ensureLogoFile();
    final body =
        'فاکتور فروش شماره ${_toPersianDigits(invoiceNumber)} ایجاد شد.';
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000000),
      'فروشگاه فرهنگی مذهبی کریم اهل بیت (ع)',
      body,
      _details(imagePath: imagePath),
      payload: 'invoice_registered:$invoiceNumber',
    );
    if (limited) {
      await prefs.setString('invoice_notification_last_date', todayKey);
    }
  }
}

// ==================== شروع برنامه ====================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const DeliveryApp());
}

class DeliveryApp extends StatefulWidget {
  const DeliveryApp({super.key});

  @override
  State<DeliveryApp> createState() => _DeliveryAppState();
}

class _DeliveryAppState extends State<DeliveryApp> with WidgetsBindingObserver {
  bool _isDarkMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDarkMode = prefs.getBool('dark_mode') ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [appRouteObserver],
      title: 'Karim Ahle Beit',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Vazir',
        scaffoldBackgroundColor: const Color(0xFFF8F7F2),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF185C3A),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF185C3A),
          onPrimary: Colors.white,
          secondary: const Color(0xFFC59A2E),
          onSecondary: Colors.white,
          surface: const Color(0xFFFFFEFA),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontFamily: 'Vazir', height: 1.55),
          bodyMedium: TextStyle(fontFamily: 'Vazir', height: 1.5),
          titleLarge:
              TextStyle(fontFamily: 'Vazir', fontWeight: FontWeight.w700),
          titleMedium:
              TextStyle(fontFamily: 'Vazir', fontWeight: FontWeight.w600),
          labelLarge:
              TextStyle(fontFamily: 'Vazir', fontWeight: FontWeight.w600),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 2,
          centerTitle: true,
          backgroundColor: Color(0xFF185C3A),
          foregroundColor: Colors.white,
          iconTheme: IconThemeData(color: Colors.white),
          titleTextStyle: TextStyle(
            fontFamily: 'Vazir',
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 1.5,
          margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 0),
          color: Colors.white,
          surfaceTintColor: Color(0xFFF5F0DE),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Color(0xFFE8E2D2)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE1DDCF)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE1DDCF)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF185C3A), width: 1.6),
          ),
          labelStyle: const TextStyle(fontFamily: 'Vazir'),
          hintStyle: TextStyle(fontFamily: 'Vazir', color: Colors.black54),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(0, 48),
            elevation: 0,
            backgroundColor: const Color(0xFF185C3A),
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(
                fontFamily: 'Vazir', fontWeight: FontWeight.w700),
          ),
        ),
        chipTheme: ChipThemeData(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: const BorderSide(color: Color(0xFFE2D9BD)),
          labelStyle: const TextStyle(fontFamily: 'Vazir'),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE8E2D2),
          thickness: 0.8,
          space: 1,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Vazir',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D7B54),
          brightness: Brightness.dark,
        ).copyWith(
          secondary: const Color(0xFFD6B65A),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontFamily: 'Vazir', height: 1.55),
          bodyMedium: TextStyle(fontFamily: 'Vazir', height: 1.5),
          titleLarge:
              TextStyle(fontFamily: 'Vazir', fontWeight: FontWeight.w700),
          titleMedium:
              TextStyle(fontFamily: 'Vazir', fontWeight: FontWeight.w600),
          labelLarge:
              TextStyle(fontFamily: 'Vazir', fontWeight: FontWeight.w600),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 2,
          centerTitle: true,
          backgroundColor: Color(0xFF12462D),
          foregroundColor: Colors.white,
          iconTheme: IconThemeData(color: Colors.white),
          titleTextStyle: TextStyle(
              fontFamily: 'Vazir',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white),
        ),
        cardTheme: CardThemeData(
          elevation: 1.5,
          color: const Color(0xFF193127),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1B3027),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          enabledBorder:
              OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Color(0xFFD6B65A), width: 1.5)),
          labelStyle: const TextStyle(fontFamily: 'Vazir'),
        ),
      ),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('fa'),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: SplashScreen(),
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

class StoreBrandMark extends StatelessWidget {
  final double size;
  final bool framed;

  const StoreBrandMark({super.key, this.size = 42, this.framed = true});

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      'assets/images/Logopit_1787568628075.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
    if (!framed) return image;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .07),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * .24),
        border: Border.all(color: const Color(0xFFD8B75A), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.10),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: image,
    );
  }
}

// ==================== Splash Screen ====================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkUserStatus();
  }

  Future<void> _checkUserStatus() async {
    await Future.delayed(const Duration(seconds: 2));

    final prefs = await SharedPreferences.getInstance();
    final profileCompleted = prefs.getBool('profile_completed') ?? false;
    final licenseVerified = prefs.getBool('license_verified') ?? false;
    final userName = prefs.getString('user_name') ?? '';

    if (mounted) {
      if (profileCompleted && licenseVerified && userName.isNotEmpty) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const DeliveryScreen(),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const LoginScreen(),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12462D),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.3),
                    blurRadius: 50,
                    spreadRadius: 10,
                  ),
                ],
                image: const DecorationImage(
                  image: AssetImage('assets/images/Logopit_1787568628075.png'),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'بِسْمِ اللَّهِ الرَّحْمَنِ الرَّحِيمِ',
              style: TextStyle(
                color: Color(0xFFE7D49A),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'بوستان فرهنگی مذهبی',
              style: TextStyle(
                color: Color(0xFFD6B65A),
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'لطفاً صبر کنید...',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== صفحه ورود ====================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // لایسنس اصلی برنامه را اینجا قرار دهید. فرمت پیشنهادی: XXXX.XXXX.XXXX
  // پس از اینکه لایسنس نهایی را به من بدهید، همین مقدار را با لایسنس شما جایگزین می‌کنم.
  static const String _validLicense = 'STORE.2026.0001';

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _licenseController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String _gender = 'male';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString('user_name') ?? '';
    final savedLicense = prefs.getString('user_license') ?? '';
    final savedGender = prefs.getString('user_gender') ?? 'male';

    if (mounted) {
      setState(() {
        _nameController.text = savedName;
        _licenseController.text = savedLicense;
        _gender = savedGender == 'female' ? 'female' : 'male';
      });
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final name = _nameController.text.trim();
    final license = _licenseController.text.trim();

    // لایسنس مانند رمز عبور است و باید دقیقاً با لایسنس تعیین‌شده مطابقت داشته باشد.
    if (license != _validLicense) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'لایسنس واردشده صحیح نیست. لطفاً لایسنس معتبر را وارد کنید.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', name);
    await prefs.setString('user_license', license);
    await prefs.setString('user_gender', _gender);
    await prefs.setBool('license_verified', true);
    await prefs.setBool('profile_completed', true);
    if (mounted) {
      setState(() => _isLoading = false);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const DeliveryScreen(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _licenseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7F2),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.green.shade300.withOpacity(0.5),
                          blurRadius: 40,
                          spreadRadius: 10,
                        ),
                      ],
                      image: const DecorationImage(
                        image: AssetImage(
                            'assets/images/Logopit_1787568628075.png'),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'بِسْمِ اللَّهِ الرَّحْمَنِ الرَّحِيمِ',
                    style: TextStyle(
                      color: Color(0xFFC59A2E),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '🛍️ بوستان فرهنگی مذهبی',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF185C3A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'مدیریت بارنامه و فروش',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'نام و نام خانوادگی',
                      hintText: 'مثلاً رضا قاسمی',
                      prefixIcon:
                          const Icon(Icons.person_outline, color: Colors.green),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'وارد کردن نام الزامی است';
                      }
                      if (value.trim().split(RegExp(r'\s+')).length < 2) {
                        return 'لطفاً نام و نام خانوادگی را وارد کنید';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'جنسیت',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.green.shade100),
                    ),
                    child: Column(
                      children: [
                        RadioListTile<String>(
                          value: 'male',
                          groupValue: _gender,
                          onChanged: (value) {
                            if (value != null) setState(() => _gender = value);
                          },
                          title: const Text('مرد'),
                          secondary: const Icon(Icons.man_outlined),
                        ),
                        RadioListTile<String>(
                          value: 'female',
                          groupValue: _gender,
                          onChanged: (value) {
                            if (value != null) setState(() => _gender = value);
                          },
                          title: const Text('زن'),
                          secondary: const Icon(Icons.woman_outlined),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _licenseController,
                    obscureText: true,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: 'لایسنس برنامه (الزامی)',
                      hintText: 'مثلاً ABCD.2026.XYZ1',
                      prefixIcon: const Icon(Icons.vpn_key_outlined,
                          color: Colors.green),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    validator: (value) {
                      final license = value?.trim() ?? '';
                      if (license.isEmpty) {
                        return 'وارد کردن لایسنس الزامی است';
                      }
                      if (!RegExp(r'^[A-Za-z0-9]+(?:\.[A-Za-z0-9]+){2,}$')
                          .hasMatch(license)) {
                        return 'فرمت لایسنس باید مانند ABCD.2026.XYZ1 باشد';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                      ),
                      onPressed: _isLoading ? null : _login,
                      child: _isLoading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'ورود به برنامه',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Icon(Icons.arrow_forward),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.green.shade200.withOpacity(0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Colors.grey.shade600,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'نسخه 2.2.0 | توسعه‌دهنده: رضا قاسمی',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== صفحه اصلی برنامه ====================

class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen({super.key});

  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen>
    with WidgetsBindingObserver, RouteAware {
  String _normalizeDigits(String value) {
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    const ar = '٠١٢٣٤٥٦٧٨٩';
    for (var i = 0; i < 10; i++) {
      value = value.replaceAll(fa[i], '$i').replaceAll(ar[i], '$i');
    }
    return value;
  }

  List<DeliveryItem> _currentItems = [];
  List<DeliveryItem> _filteredItems = [];
  List<Map<String, dynamic>> _manifestSearchResults = [];
  List<DeliveryManifest> _savedManifests = [];
  List<String> _smartLogs = [];
  List<ProductDatabaseItem> _productDatabase = [];
  List<SalesInvoice> _salesInvoices = [];
  List<TrashItem> _trashItems = [];
  List<InventoryCountEntry> _inventoryCounts = [];
  List<DailyExpense> _dailyExpenses = [];
  List<CustomEvent> _customEvents = [];

  // رویدادهای ثابت و دوره‌ای
  DateTime? _lastInventoryDate;
  DateTime? _lastCleaningDate;

  final PageController _toolsPageController = PageController();
  int _toolsPage = 0;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _purchasePriceController =
      TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _packageSizeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // ==================== FocusNode برای مدیریت کیبورد ====================
  final FocusNode _searchFocusNode = FocusNode();

  bool _isSearching = false;
  String _selectedUnit = 'عدد';
  bool _isLoading = false;
  bool _isPackageUnit = false;
  bool _isViewingManifest = false;
  bool _hasNewManagerMessage = false;
  DeliveryManifest? _viewingManifest;

  String _userName = '';
  String _userGender = 'male';
  String _storeName = 'فروشگاه فرهنگی مذهبی کریم اهل بیت (ع)';
  Timer? _snapshotCheckTimer;
  bool _checkingSnapshot = false;

  @override
  void initState() {
    super.initState();
    _loadSavedManifests();
    _loadSmartLogs();
    _loadProductDatabase();
    _loadSalesInvoices();
    _loadTrashAndCleanup();
    _loadInventoryCounts();
    _loadDailyExpenses();
    _loadCustomEvents();
    _loadFixedEventDates();
    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      await _showOpenWelcomeNotification();
      if (!mounted) return;
      await _showWelcomeDialogIfNeeded();
      if (mounted) _scheduleMorningNotificationsIfEnabled();
      if (mounted) {
        await _checkForDatabaseUpdate();
        _snapshotCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
          _checkForDatabaseUpdate();
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    _closeKeyboard();
    if (mounted) {
      _refreshFixedEventDatesFromPrefs();
    }
  }

  @override
  void didPush() {}

  @override
  void didPushNext() {
    _closeKeyboard();
  }

  @override
  void didPop() {}

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _closeKeyboard();
      _refreshFixedEventDatesFromPrefs();
      _checkForDatabaseUpdate();
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _snapshotCheckTimer?.cancel();
    _nameController.dispose();
    _quantityController.dispose();
    _purchasePriceController.dispose();
    _searchController.dispose();
    _barcodeController.dispose();
    _packageSizeController.dispose();
    _searchFocusNode.dispose();
    _toolsPageController.dispose();
    super.dispose();
  }

  // ==================== تابع بستن کیبورد ====================
  void _closeKeyboard() {
    FocusScope.of(context).unfocus();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _userName = prefs.getString('user_name') ?? '';
      _userGender =
          prefs.getString('user_gender') == 'female' ? 'female' : 'male';
      _storeName = prefs.getString('store_name')?.trim().isNotEmpty == true
          ? prefs.getString('store_name')!.trim()
          : 'فروشگاه فرهنگی مذهبی کریم اهل بیت (ع)';
    });
    await _loadManagerMessage();
  }

  Future<void> _checkForDatabaseUpdate() async {
    if (_checkingSnapshot || !mounted) return;
    _checkingSnapshot = true;
    try {
      final network = NetworkService();
      final info = await network.fetchSnapshotInfo();
      await _syncNetworkMessages();
      if (info == null || !mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getString('database_update_seen_at') ?? '';
      final notified = prefs.getString('database_update_notified_at') ?? '';
      final deletedIds =
          (prefs.getStringList('deleted_app_message_ids') ?? const <String>[])
              .toSet();
      final messageId = 'database_update:${info.updatedAt}';
      await _upsertAppMessage(
        id: messageId,
        title: 'بروزرسانی بانک اطلاعاتی',
        body: 'بروزرسانی بانک اطلاعاتی موجود است',
      );
      if (notified != info.updatedAt) {
        await StoreNotificationService.instance.showDatabaseUpdateAvailable(
          storeName: _storeName,
        );
        await prefs.setString('database_update_notified_at', info.updatedAt);
      }
      if (deletedIds.contains(messageId) || seen == info.updatedAt) {
        if (mounted) setState(() => _hasNewManagerMessage = false);
      } else if (mounted) {
        setState(() => _hasNewManagerMessage = true);
      }
    } catch (_) {
      // بررسی دوره‌ای نباید مانع اجرای برنامه شود.
    } finally {
      _checkingSnapshot = false;
    }
  }

  Future<List<AppMessage>> _loadAppMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_messages') ?? '[]';
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => AppMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAppMessages(List<AppMessage> messages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'app_messages', jsonEncode(messages.map((e) => e.toJson()).toList()));
  }

  Future<void> _upsertAppMessage({
    required String id,
    required String title,
    required String body,
    DateTime? createdAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final deleted =
        (prefs.getStringList('deleted_app_message_ids') ?? const <String>[])
            .toSet();
    if (deleted.contains(id)) return;
    final messages = await _loadAppMessages();
    final index = messages.indexWhere((m) => m.id == id);
    final item = AppMessage(
      id: id,
      title: title,
      body: body,
      createdAt: createdAt ?? DateTime.now(),
      isRead: index >= 0 ? messages[index].isRead : false,
    );
    if (index >= 0) {
      messages[index] = item;
    } else {
      messages.insert(0, item);
    }
    await _saveAppMessages(messages);
    if (mounted) {
      setState(() => _hasNewManagerMessage = messages.any((m) => !m.isRead));
    }
  }

  Future<void> _syncNetworkMessages() async {
    try {
      final events = await NetworkService().fetchRecentEvents();
      for (final event in events) {
        final type = event['type']?.toString() ?? '';
        if (type != 'invoice_created') continue;
        final payload = Map<String, dynamic>.from(event['payload'] ?? {});
        final number = payload['invoiceNumber']?.toString() ?? '';
        final total = payload['total']?.toString() ?? '0';
        final eventId = event['id']?.toString() ?? '';
        if (eventId.isEmpty || number.isEmpty) continue;
        await _upsertAppMessage(
          id: 'network:$eventId',
          title: 'ثبت فاکتور فروش',
          body:
              'فاکتور شماره ${_toPersianDigits(number)} با مبلغ ${_formatPrice(int.tryParse(total) ?? 0)} ریال ثبت شد.',
          createdAt: DateTime.tryParse(event['created_at']?.toString() ?? ''),
        );
      }
    } catch (_) {}
  }

  Future<void> _loadManagerMessage() async {
    // سازگاری با نسخه‌های قدیمی که فقط یک پیام ذخیره می‌کردند.
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString('manager_message') ?? '';
    final legacyId = prefs.getString('manager_message_id') ?? '';
    if (legacy.trim().isNotEmpty && legacyId.isNotEmpty) {
      await _upsertAppMessage(
        id: legacyId,
        title: 'پیام مدیر',
        body: legacy,
      );
    }
    await _syncNetworkMessages();
    final messages = await _loadAppMessages();
    if (!mounted) return;
    setState(() => _hasNewManagerMessage = messages.any((m) => !m.isRead));
  }

  Future<void> _openManagerMessage() async {
    var messages = await _loadAppMessages();
    if (messages.isEmpty) {
      if (mounted) _showSuccessMessage('پیامی ثبت نشده است');
      return;
    }
    messages = messages.map((m) => m.copyWith(isRead: true)).toList();
    await _saveAppMessages(messages);
    if (mounted) setState(() => _hasNewManagerMessage = false);
    if (!mounted) return;
    await Navigator.push(
      context,
      _slideRoute(ManagerMessagesScreen(
        messages: messages,
        onMessagesChanged: (updated) async {
          await _saveAppMessages(updated);
          if (mounted)
            setState(
                () => _hasNewManagerMessage = updated.any((m) => !m.isRead));
        },
      )),
    );
  }

  Future<void> _refreshFixedEventDatesFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final inventoryRaw = prefs.getString('fixed_inventory_last_date_v2');
    final cleaningRaw = prefs.getString('fixed_cleaning_last_date_v1');
    if (!mounted) return;
    setState(() {
      if (inventoryRaw != null)
        _lastInventoryDate = DateTime.tryParse(inventoryRaw);
      if (cleaningRaw != null)
        _lastCleaningDate = DateTime.tryParse(cleaningRaw);
    });
  }

  Future<void> _loadCustomEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('custom_events');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List;
      if (!mounted) return;
      setState(() {
        _customEvents = decoded
            .map((e) => CustomEvent.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _syncManagerSharedSnapshot() async {
    try {
      final network = NetworkService();
      final config = await network.loadConfig();
      if (config.role != 'manager' || !config.isConfigured) return;
      final prefs = await SharedPreferences.getInstance();
      List<dynamic> products = [];
      List<dynamic> expenses = [];
      List<dynamic> events = [];
      try {
        products = jsonDecode(prefs.getString('product_database') ?? '[]')
            as List<dynamic>;
      } catch (_) {}
      try {
        expenses = jsonDecode(prefs.getString('daily_expenses') ?? '[]')
            as List<dynamic>;
      } catch (_) {}
      try {
        events = jsonDecode(prefs.getString('custom_events') ?? '[]')
            as List<dynamic>;
      } catch (_) {}
      await network.uploadSnapshot({
        'product_database': products,
        'daily_expenses': expenses,
        'custom_events': events,
        'fixed_inventory_last_date_v2':
            prefs.getString('fixed_inventory_last_date_v2'),
        'fixed_cleaning_last_date_v1':
            prefs.getString('fixed_cleaning_last_date_v1'),
      }, actorName: _storeName);
    } catch (_) {}
  }

  Future<void> _saveCustomEvents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_events',
      jsonEncode(_customEvents.map((e) => e.toJson()).toList()),
    );
    await _syncManagerSharedSnapshot();
  }

  Future<void> _loadFixedEventDates() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final inventoryRaw = prefs.getString('fixed_inventory_last_date_v2');
    final cleaningRaw = prefs.getString('fixed_cleaning_last_date_v1');

    DateTime inventoryDate;
    DateTime cleaningDate;

    if (inventoryRaw != null) {
      inventoryDate = DateTime.tryParse(inventoryRaw) ??
          today.subtract(const Duration(days: 19));
    } else {
      // مقدار اولیه مطابق درخواست: ۲۱ روز مانده تا انبارگردانی.
      inventoryDate = today.subtract(const Duration(days: 19));
      await prefs.setString(
          'fixed_inventory_last_date_v2', inventoryDate.toIso8601String());
    }

    if (cleaningRaw != null) {
      cleaningDate = DateTime.tryParse(cleaningRaw) ?? today;
    } else {
      // مقدار اولیه مطابق درخواست: ۳۰ روز مانده تا نظافت.
      cleaningDate = today;
      await prefs.setString(
          'fixed_cleaning_last_date_v1', cleaningDate.toIso8601String());
    }

    if (!mounted) return;
    setState(() {
      _lastInventoryDate = inventoryDate;
      _lastCleaningDate = cleaningDate;
    });
  }

  Future<void> _showOpenWelcomeNotification() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notifications_enabled') != true) return;
      final name = prefs.getString('user_name') ?? '';
      if (name.isEmpty) return;
      if (!await StoreNotificationService.instance.isEnabled()) return;
      final gender =
          prefs.getString('user_gender') == 'female' ? 'female' : 'male';
      await StoreNotificationService.instance.showWelcomeNotification(
        userName: name,
        gender: gender,
      );
    } catch (_) {
      // اعلان خوش‌آمدگویی نباید مانع اجرای برنامه شود.
    }
  }

  Future<void> _showWelcomeDialogIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayJalali();
    if (prefs.getString('welcome_dialog_hidden_date') == today || !mounted)
      return;

    final now = DateTime.now();
    final name = prefs.getString('user_name') ?? _userName;
    final gender = prefs.getString('user_gender') == 'female' ? 'خانم' : 'آقای';

    final inventoryRemaining = _inventoryDaysRemainingForDate(
      now,
      lastDate: _lastInventoryDate,
    );
    final cleaningRemaining = _cleaningDaysRemainingForDate(
      now,
      lastDate: _lastCleaningDate,
    );

    final futureEvents = <Map<String, dynamic>>[];
    for (final event in _customEvents) {
      final target = DateTime.tryParse(event.isoDate);
      if (target == null) continue;
      final days = DateTime(target.year, target.month, target.day)
          .difference(DateTime(now.year, now.month, now.day))
          .inDays;
      if (days >= 0) futureEvents.add({'event': event, 'days': days});
    }
    futureEvents.sort((a, b) => (a['days'] as int).compareTo(b['days'] as int));

    if (!mounted) return;
    bool hideToday = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              title: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.waving_hand_outlined,
                        color: Colors.green, size: 26),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                      child: Text('خوش آمدید',
                          style: TextStyle(fontWeight: FontWeight.bold))),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'سلام $gender ${name.isEmpty ? 'کاربر عزیز' : name}، خوش آمدید 🌷',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87),
                    ),
                    const SizedBox(height: 10),
                    Text('امروز ${_todayJalaliLong()}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black87)),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.bottomRight,
                          end: Alignment.topLeft,
                          colors: [
                            Color(0xFF4CAF50),
                            Color(0xFFA5D6A7),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Color(0xFF81C784)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('📅 روزشمار رویدادهای مهم',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 10),
                          _eventCountdownRow('انبارگردانی', inventoryRemaining),
                          _eventCountdownRow('نظافت', cleaningRemaining),
                          ...futureEvents.take(5).map((item) =>
                              _eventCountdownRow(
                                  (item['event'] as CustomEvent).name,
                                  item['days'] as int)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                            child: _welcomeStatCard(
                                'فروش امروز',
                                '${_formatPrice(_getTodaySalesTotal())} ریال',
                                Icons.point_of_sale_outlined)),
                        const SizedBox(width: 6),
                        Expanded(
                            child: _welcomeStatCard(
                                'کل موجودی',
                                _toPersianDigits(
                                    _getTotalProductStock().toString()),
                                Icons.warehouse_outlined)),
                        const SizedBox(width: 6),
                        Expanded(
                            child: _welcomeStatCard(
                                'تعداد اقلام',
                                _toPersianDigits(
                                    _productDatabase.length.toString()),
                                Icons.inventory_2_outlined)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: hideToday,
                      onChanged: (value) =>
                          setDialogState(() => hideToday = value ?? false),
                      title: const Text('امروز دیگر نمایش نده'),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ],
                ),
              ),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (hideToday)
                        await prefs.setString(
                            'welcome_dialog_hidden_date', today);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('باشه'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _eventCountdownRow(String name, int days) {
    final text = days == 0 ? 'امروز' : '$days روز مانده';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const Icon(Icons.event_available_outlined,
              size: 20, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
              child: Text(name,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(_toPersianDigits(text),
              style: TextStyle(
                  color: Colors.green.shade800, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _welcomeStatCard(String title, String value, IconData icon) {
    return Container(
      constraints: const BoxConstraints(minHeight: 88),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.green.shade700, size: 21),
          const SizedBox(height: 5),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  String _morningNotificationBody(DateTime now) {
    final remaining = _inventoryDaysRemainingForDate(
      now,
      lastDate: _lastInventoryDate,
    );
    final cleaningRemaining = _cleaningDaysRemainingForDate(
      now,
      lastDate: _lastCleaningDate,
    );
    final inventoryText = remaining == 0
        ? 'امروز زمان انبارگردانی است.'
        : '${_toPersianDigits(remaining.toString())} روز مانده تا انبارگردانی.';
    final cleaningText = cleaningRemaining == 0
        ? 'نظافت: امروز'
        : 'نظافت: ${_toPersianDigits(cleaningRemaining.toString())} روز مانده';
    final events = <String>[cleaningText];
    for (final event in _customEvents) {
      final target = DateTime.tryParse(event.isoDate);
      if (target == null) continue;
      final days = DateTime(target.year, target.month, target.day)
          .difference(DateTime(now.year, now.month, now.day))
          .inDays;
      if (days >= 0) {
        events.add(days == 0
            ? '${event.name}: امروز'
            : '${event.name}: ${_toPersianDigits(days.toString())} روز مانده');
      }
    }
    events.sort();
    final eventText = events.isEmpty ? '' : '\n' + events.take(3).join(' • ');
    return 'صبح بخیر 🌷\n$inventoryText$eventText';
  }

  Future<void> _scheduleMorningNotificationsIfEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notifications_enabled') != true) return;

      final name = prefs.getString('user_name') ?? '';
      if (name.isEmpty) return;
      if (!await StoreNotificationService.instance.isEnabled()) return;

      final gender =
          prefs.getString('user_gender') == 'female' ? 'female' : 'male';
      await StoreNotificationService.instance.scheduleMorningNotifications(
        userName: name,
        gender: gender,
        customEvents: List<CustomEvent>.from(_customEvents),
      );
    } catch (_) {
      // اعلان نباید مانع اجرای برنامه شود.
    }
  }

  String _formatNumber(String value) {
    if (value.isEmpty) return '';
    final number = int.tryParse(value.replaceAll(',', ''));
    if (number == null) return value;
    return number.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (match) => '${match[1]},',
        );
  }

  int _getTotalProductStock() {
    return _productDatabase.fold<int>(0, (sum, product) => sum + product.stock);
  }

  int _getTodaySalesTotal() {
    final today = _todayJalali();
    return _salesInvoices
        .where((invoice) => invoice.date == today)
        .fold<int>(0, (sum, invoice) => sum + invoice.totalPrice);
  }

  Widget _buildLiveStats() {
    final itemCount = _productDatabase.length;
    final totalStock = _getTotalProductStock();
    final todaySales = _getTodaySalesTotal();

    Widget stat({required String title, required String value}) {
      return Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.90),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                value,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.16),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          stat(
              title: 'تعداد اقلام',
              value: _toPersianDigits(itemCount.toString())),
          stat(
              title: 'کل موجودی کالا',
              value: _toPersianDigits(totalStock.toString())),
          stat(
            title: 'فروش امروز',
            value: '${_formatPrice(todaySales)} ریال',
          ),
        ],
      ),
    );
  }

  Future<void> _contactSupport() async {
    _closeKeyboard();
    final subject =
        Uri.encodeComponent('ارتباط با پشتیبانی دستیار هوشمند فروشگاه');
    final body = Uri.encodeComponent(
      'سلام،\n\nپیام من درباره برنامه دستیار هوشمند فروشگاه:\n\n',
    );

    final gmailUri = Uri.parse(
      'googlegmail://co?to=rezagasem.82@gmail.com&subject=$subject&body=$body',
    );
    final mailtoUri = Uri(
      scheme: 'mailto',
      path: 'rezagasem.82@gmail.com',
      queryParameters: {
        'subject': 'ارتباط با پشتیبانی دستیار هوشمند فروشگاه',
        'body': 'سلام،\n\nپیام من درباره برنامه دستیار هوشمند فروشگاه:\n\n',
      },
    );

    try {
      if (await canLaunchUrl(gmailUri)) {
        await launchUrl(gmailUri, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(mailtoUri)) {
        await launchUrl(mailtoUri, mode: LaunchMode.externalApplication);
      } else {
        _showSuccessMessage('برنامه ایمیل روی دستگاه پیدا نشد');
      }
    } catch (_) {
      try {
        await launchUrl(mailtoUri, mode: LaunchMode.externalApplication);
      } catch (_) {
        _showSuccessMessage('❌ خطا در باز کردن Gmail');
      }
    }
  }

  void _openNetworkConnectionScreen() {
    _closeKeyboard();
    Navigator.push(
      context,
      _slideRoute(const NetworkConnectionScreen()),
    );
  }

  int _getNextManifestNumber() {
    if (_savedManifests.isEmpty) return 1;
    return _savedManifests
            .map((e) => e.number)
            .reduce((a, b) => a > b ? a : b) +
        1;
  }

  int _getNextInvoiceNumber() {
    if (_salesInvoices.isEmpty) return 1;
    return _salesInvoices.map((e) => e.number).reduce((a, b) => a > b ? a : b) +
        1;
  }

  Future<void> _scanBarcode({bool forSearchOnly = false}) async {
    try {
      _closeKeyboard();
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (context) => const BarcodeScannerScreen(),
        ),
      );

      if (!mounted) return;

      if (result != null && result.isNotEmpty) {
        if (forSearchOnly) {
          _searchController.text = result;
          _searchItems(result);
          _showBarcodeSearchResultDialog(result);
        } else {
          setState(() {
            _barcodeController.text = result;
          });

          final foundProduct = _productDatabase.firstWhere(
            (p) => p.barcode == result,
            orElse: () => ProductDatabaseItem(
                barcode: '', name: '', stock: 0, buyPrice: 0, sellPrice: 0),
          );

          if (foundProduct.barcode.isNotEmpty) {
            _nameController.text = foundProduct.name;
            _purchasePriceController.text = _formatPrice(foundProduct.buyPrice);
            _showSuccessMessage('کالا از بانک اطلاعاتی پیدا شد 🔍');
          } else {
            _showSuccessMessage('بارکد اسکن شد ✅');
          }
        }
      }
    } catch (e) {
      _showSuccessMessage('❌ خطا در اسکن بارکد');
    }
  }

  void _showBarcodeSearchResultDialog(String barcode) {
    _closeKeyboard();
    final matches =
        _productDatabase.where((p) => p.barcode == barcode).toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.qr_code_scanner, color: Colors.blue),
            SizedBox(width: 8),
            Text('نتیجه اسکن بارکد', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: matches.isEmpty
            ? Text('کالایی با بارکد $barcode در بانک اطلاعات پیدا نشد.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: matches.map((item) {
                  return Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('📦 نام کالا: ${item.name}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 6),
                        Text('📊 موجودی: ${item.stock}',
                            style: const TextStyle(fontSize: 14)),
                        const SizedBox(height: 4),
                        Text('🏷️ قیمت فروش: ${_displayPrice(item.sellPrice)}',
                            style: const TextStyle(
                                fontSize: 14,
                                color: Colors.green,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.shopping_cart),
                          label: const Text('فروش این کالا'),
                          onPressed: () {
                            Navigator.pop(context);
                            _openSalesInvoicesScreen();
                            _showSalesDialog(
                              productName: item.name,
                              productBarcode: item.barcode,
                              sellPrice: item.sellPrice,
                            );
                          },
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
        actions: [
          ElevatedButton(
            onPressed: () {
              _closeKeyboard();
              Navigator.pop(context);
            },
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadProductDatabase() async {
    final prefs = await SharedPreferences.getInstance();
    final dataStr = prefs.getString('product_database');
    if (dataStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(dataStr);
        setState(() {
          _productDatabase = decoded
              .map((item) => ProductDatabaseItem.fromJson(item))
              .toList();
        });
      } catch (e) {}
    }
  }

  Future<void> _saveProductDatabase() async {
    final prefs = await SharedPreferences.getInstance();
    final dataJson = _productDatabase.map((p) => p.toJson()).toList();
    await prefs.setString('product_database', jsonEncode(dataJson));
  }

  PageRouteBuilder<T> _slideRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(
            opacity: curved,
            child: child,
          ),
        );
      },
    );
  }

  int get _toolPageCount => (9 / 4).ceil();

  void _openManifestScreen() {
    _closeKeyboard();
    Navigator.push(
      context,
      _slideRoute(
        ManifestScreen(
          manifests: _savedManifests,
          onDelete: _deleteManifest,
          onEdit: _startEditingManifest,
          onViewDetails: _viewManifestDetails,
          onShareReport: _shareManifestReport,
          onManifestSaved: _saveManifest,
        ),
      ),
    );
  }

  void _viewManifestDetails(DeliveryManifest manifest) {
    _closeKeyboard();
    Navigator.push(
      context,
      _slideRoute(ManifestDetailsScreen(manifest: manifest)),
    );
  }

  // ==================== انتخاب نوع گزارش برای اشتراک‌گذاری ====================

  void _openShareReportChooser() {
    _closeKeyboard();
    final hasSales = _salesInvoices.isNotEmpty;
    final hasManifests = _savedManifests.isNotEmpty;
    final hasChangedPrices = _productDatabase.any((p) => p.isPriceModified);
    final hasInventory = _inventoryCounts.isNotEmpty;

    if (!hasSales && !hasManifests && !hasChangedPrices && !hasInventory) {
      _showSuccessMessage('⚠️ هنوز گزارشی برای اشتراک وجود ندارد');
      return;
    }

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'اشتراک‌گذاری گزارش',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text('نوع گزارشی را که می‌خواهید ارسال شود انتخاب کنید.'),
              const SizedBox(height: 14),
              if (hasSales)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE8F5E9),
                    child:
                        Icon(Icons.receipt_long_outlined, color: Colors.green),
                  ),
                  title: const Text('گزارش فروش'),
                  subtitle: Text('تعداد فاکتورها: ${_salesInvoices.length}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareSalesReport();
                  },
                ),
              if (hasChangedPrices)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFFFF3CD),
                    child:
                        Icon(Icons.price_change_outlined, color: Colors.orange),
                  ),
                  title: const Text('گزارش قیمت‌های تغییر یافته'),
                  subtitle: Text(
                      'تعداد کالاها: ${_productDatabase.where((p) => p.isPriceModified).length}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareChangedPriceReport();
                  },
                ),
              if (hasInventory)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE0F2F1),
                    child: Icon(Icons.fact_check_outlined, color: Colors.teal),
                  ),
                  title: const Text('گزارش انبارگردانی'),
                  subtitle: Text('تعداد اقلام: ${_inventoryCounts.length}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareInventoryCountReport();
                  },
                ),
              if (hasManifests)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE3F2FD),
                    child:
                        Icon(Icons.local_shipping_outlined, color: Colors.blue),
                  ),
                  title: const Text('گزارش بارنامه‌ها'),
                  subtitle: Text('تعداد بارنامه‌ها: ${_savedManifests.length}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareAllManifests();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareInventoryCountReport() async {
    try {
      final font = await _loadFont();
      final pdf = pw.Document();
      final entries = _inventoryCounts;
      final mismatches = entries.where((e) => e.difference != 0).toList();
      final shortage = mismatches
          .where((e) => e.difference < 0)
          .fold<int>(0, (s, e) => s + e.difference.abs());
      final surplus = mismatches
          .where((e) => e.difference > 0)
          .fold<int>(0, (s, e) => s + e.difference);
      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        build: (_) => [
          _pdfShareTextWidget('گزارش انبارگردانی', font,
              fontSize: 22,
              fontWeight: pw.FontWeight.bold,
              textAlign: pw.TextAlign.center),
          pw.SizedBox(height: 12),
          _pdfShareTextWidget('تاریخ تهیه گزارش: ${_todayJalali()}', font,
              fontSize: 9),
          pw.SizedBox(height: 12),
          _pdfShareTextWidget(
              'کل اقلام: ${entries.length} | مغایرت: ${mismatches.length} | کسری: $shortage | اضافی: $surplus',
              font,
              fontWeight: pw.FontWeight.bold),
          pw.SizedBox(height: 14),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey500),
            children: [
              pw.TableRow(children: [
                _pdfShareCell('ردیف', font, bold: true),
                _pdfShareCell('نام کالا', font, bold: true),
                _pdfShareCell('موجودی سیستمی', font, bold: true),
                _pdfShareCell('موجودی واقعی', font, bold: true),
                _pdfShareCell('مغایرت', font, bold: true),
              ]),
              ...entries.asMap().entries.map((e) => pw.TableRow(children: [
                    _pdfShareCell('${e.key + 1}', font),
                    _pdfShareCell(e.value.name, font,
                        align: pw.TextAlign.right),
                    _pdfShareCell('${e.value.systemStock}', font),
                    _pdfShareCell('${e.value.actualStock}', font),
                    _pdfShareCell('${e.value.difference}', font),
                  ])),
            ],
          ),
        ],
      ));
      final bytes = await pdf.save();
      final file =
          File('${Directory.systemTemp.path}/inventory_report_share.pdf');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path)], text: 'گزارش انبارگردانی');
      _showSuccessMessage('گزارش انبارگردانی ارسال شد');
    } catch (e) {
      _showSuccessMessage('خطا در تهیه گزارش انبارگردانی: $e');
    }
  }

  Future<void> _shareAllManifests() async {
    try {
      _closeKeyboard();
      final font = await _loadFont();
      final pdf = pw.Document();
      final totalManifests = _savedManifests.length;
      final totalItems =
          _savedManifests.fold<int>(0, (sum, m) => sum + m.items.length);

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 30, 28, 30),
          textDirection: pw.TextDirection.rtl,
          maxPages: 500,
          build: (context) => [
            pw.Center(
              child: _pdfShareTextWidget(
                'گزارش جامع بارنامه‌ها',
                font,
                fontSize: 24,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blue,
                textAlign: pw.TextAlign.center,
              ),
            ),
            pw.SizedBox(height: 16),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  _pdfShareTextWidget(
                    'تعداد بارنامه‌ها: ${_toPersianDigits(totalManifests.toString())}',
                    font,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  pw.SizedBox(height: 6),
                  _pdfShareTextWidget(
                    'تعداد کل کالاها: ${_toPersianDigits(totalItems.toString())}',
                    font,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  pw.SizedBox(height: 6),
                  _pdfShareTextWidget(
                    'مجموع هزینه باربری: ${_formatPrice(_savedManifests.fold<int>(0, (sum, m) => sum + m.freightCost))} ریال',
                    font,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 14),
            ..._savedManifests.map((m) => _pdfShareTextWidget(
                  'بارنامه شماره ${m.number} | شرکت ارسال کننده: ${m.senderCompany.isEmpty ? 'ثبت نشده' : m.senderCompany} | هزینه باربری: ${_formatPrice(m.freightCost)} ریال',
                  font,
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                )),
            pw.SizedBox(height: 18),
            _pdfShareTextWidget(
              'جزئیات بارنامه‌ها',
              font,
              fontSize: 17,
              fontWeight: pw.FontWeight.bold,
            ),
            pw.SizedBox(height: 8),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey500),
              tableWidth: pw.TableWidth.max,
              columnWidths: const {
                0: pw.FlexColumnWidth(1.1),
                1: pw.FlexColumnWidth(1.0),
                2: pw.FlexColumnWidth(2.7),
                3: pw.FlexColumnWidth(1.0),
                4: pw.FlexColumnWidth(1.5),
                5: pw.FlexColumnWidth(1.3),
                6: pw.FlexColumnWidth(1.8),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.blue100),
                  children: [
                    _pdfShareCell('بارنامه', font, bold: true),
                    _pdfShareCell('تاریخ', font, bold: true),
                    _pdfShareCell('نام کالا', font, bold: true),
                    _pdfShareCell('واحد', font, bold: true),
                    _pdfShareCell('تعداد', font, bold: true),
                    _pdfShareCell('داخل هر بسته', font, bold: true),
                    _pdfShareCell('تعداد کل', font, bold: true),
                  ],
                ),
                ..._savedManifests.expand(
                  (m) => m.items.map(
                    (item) => pw.TableRow(
                      children: [
                        _pdfShareCell(
                            _toPersianDigits(m.number.toString()), font),
                        _pdfShareCell(m.date, font),
                        _pdfShareCell(item.name, font,
                            align: pw.TextAlign.right),
                        _pdfShareCell(item.unit, font),
                        _pdfShareCell(
                            _toPersianDigits(item.quantity.toString()), font),
                        _pdfShareCell(
                          item.packageSize > 0
                              ? _toPersianDigits(item.packageSize.toString())
                              : '—',
                          font,
                        ),
                        _pdfShareCell(
                            _toPersianDigits(item.realQuantity.toString()),
                            font),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 18),
            pw.Align(
              alignment: pw.Alignment.centerLeft,
              child: _pdfShareTextWidget(
                'تاریخ تهیه گزارش: ${_todayJalali()}',
                font,
                fontSize: 9,
                color: PdfColors.grey600,
                textAlign: pw.TextAlign.left,
              ),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();
      final tempFile =
          File('${Directory.systemTemp.path}/all_manifests_report.pdf');
      await tempFile.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text:
            'گزارش جامع بارنامه‌ها\nتعداد بارنامه‌ها: ${_toPersianDigits(totalManifests.toString())}',
      );
      _showSuccessMessage('گزارش جامع بارنامه‌ها ارسال شد');
    } catch (e) {
      _showSuccessMessage('خطا در تهیه گزارش بارنامه‌ها: $e');
    }
  }

  // ==================== اشتراک‌گذاری بارنامه با PDF ====================

  Future<void> _shareManifestReport(DeliveryManifest manifest) async {
    try {
      _closeKeyboard();
      final font = await _loadFont();
      final pdf = pw.Document();
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 30, 28, 30),
          textDirection: pw.TextDirection.rtl,
          maxPages: 100,
          header: (context) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: _pdfShareTextWidget(
                'گزارش جامع بارنامه شماره ${manifest.number}', font,
                fontSize: 9, color: PdfColors.grey600),
          ),
          footer: (context) => pw.Align(
            alignment: pw.Alignment.center,
            child: _pdfShareTextWidget(
                'صفحه ${context.pageNumber} از ${context.pagesCount}', font,
                fontSize: 8, color: PdfColors.grey600),
          ),
          build: (context) => [
            pw.Center(
                child: _pdfShareTextWidget(
                    'بارنامه شماره ${manifest.number}', font,
                    fontSize: 24,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue,
                    textAlign: pw.TextAlign.center)),
            pw.SizedBox(height: 16),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(8)),
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _pdfShareTextWidget('تاریخ: ${manifest.date}', font,
                        fontWeight: pw.FontWeight.bold),
                    pw.SizedBox(height: 5),
                    _pdfShareTextWidget(
                        'تعداد کالاها: ${manifest.items.length}', font,
                        fontWeight: pw.FontWeight.bold),
                    pw.SizedBox(height: 5),
                    _pdfShareTextWidget(
                        'مجموع قیمت: ${_formatPrice(manifest.totalPrice)} ریال',
                        font,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.green),
                    if (manifest.senderCompany.isNotEmpty) ...[
                      pw.SizedBox(height: 5),
                      _pdfShareTextWidget(
                          'شرکت ارسال کننده: ${manifest.senderCompany}', font,
                          fontWeight: pw.FontWeight.bold),
                    ],
                    if (manifest.freightCost > 0) ...[
                      pw.SizedBox(height: 5),
                      _pdfShareTextWidget(
                          'هزینه باربری: ${_formatPrice(manifest.freightCost)} ریال',
                          font,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.orange),
                    ],
                  ]),
            ),
            pw.SizedBox(height: 18),
            _pdfShareTextWidget('لیست کالاها', font,
                fontSize: 17, fontWeight: pw.FontWeight.bold),
            pw.SizedBox(height: 8),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey500),
              tableWidth: pw.TableWidth.max,
              columnWidths: const {
                0: pw.FlexColumnWidth(0.8),
                1: pw.FlexColumnWidth(2.8),
                2: pw.FlexColumnWidth(1.0),
                3: pw.FlexColumnWidth(1.0),
                4: pw.FlexColumnWidth(1.5),
                5: pw.FlexColumnWidth(1.3),
                6: pw.FlexColumnWidth(1.8),
              },
              children: [
                pw.TableRow(
                  repeat: true,
                  decoration: const pw.BoxDecoration(color: PdfColors.blue100),
                  children: [
                    _pdfShareCell('ردیف', font, bold: true),
                    _pdfShareCell('نام کالا', font, bold: true),
                    _pdfShareCell('واحد', font, bold: true),
                    _pdfShareCell('تعداد', font, bold: true),
                    _pdfShareCell('داخل هر بسته', font, bold: true),
                    _pdfShareCell('تعداد کل', font, bold: true),
                    _pdfShareCell('قیمت خرید', font, bold: true),
                  ],
                ),
                ...manifest.items.asMap().entries.map(
                  (entry) {
                    final item = entry.value;
                    return pw.TableRow(
                      children: [
                        _pdfShareCell('${entry.key + 1}', font),
                        _pdfShareCell(item.name, font,
                            align: pw.TextAlign.right),
                        _pdfShareCell(item.unit, font),
                        _pdfShareCell(
                            _toPersianDigits(item.quantity.toString()), font),
                        _pdfShareCell(
                          item.packageSize > 0
                              ? _toPersianDigits(item.packageSize.toString())
                              : '—',
                          font,
                        ),
                        _pdfShareCell(
                            _toPersianDigits(item.realQuantity.toString()),
                            font),
                        _pdfShareCell(
                            '${_formatPrice(item.purchasePrice)} ریال', font),
                      ],
                    );
                  },
                ),
              ],
            ),
            pw.SizedBox(height: 18),
            pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: _pdfShareTextWidget(
                    'تاریخ تهیه گزارش: ${_todayJalali()}', font,
                    fontSize: 9, color: PdfColors.grey600)),
          ],
        ),
      );
      final bytes = await pdf.save();
      final tempFile =
          File('${Directory.systemTemp.path}/manifest_${manifest.number}.pdf');
      await tempFile.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(tempFile.path)],
          text:
              'گزارش جامع بارنامه شماره ${manifest.number}\nتاریخ: ${manifest.date}');
      _showSuccessMessage('گزارش جامع بارنامه ارسال شد');
    } catch (e) {
      _showSuccessMessage('خطا در تهیه گزارش: $e');
    }
  }

  // ==================== اشتراک‌گذاری گزارش فروش با PDF ====================

  Future<void> _shareSalesReport() async {
    if (_salesInvoices.isEmpty) {
      _showSuccessMessage('⚠️ هیچ فاکتوری برای گزارش وجود ندارد');
      return;
    }

    try {
      _closeKeyboard();
      final font = await _loadFont();
      final pdf = pw.Document();
      final totalSales =
          _salesInvoices.fold<int>(0, (sum, inv) => sum + inv.totalPrice);
      final totalCredit = _salesInvoices
          .where((inv) => inv.isCredit)
          .fold<int>(0, (sum, inv) => sum + inv.totalPrice);

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 30, 28, 30),
          textDirection: pw.TextDirection.rtl,
          maxPages: 500,
          build: (context) => [
            pw.Center(
              child: _pdfShareTextWidget(
                'گزارش فروش',
                font,
                fontSize: 26,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.green,
                textAlign: pw.TextAlign.center,
              ),
            ),
            pw.SizedBox(height: 18),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  _pdfShareTextWidget(
                    'تعداد فاکتورها: ${_toPersianDigits(_salesInvoices.length.toString())}',
                    font,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  pw.SizedBox(height: 8),
                  _pdfShareTextWidget(
                    'مجموع فروش: ${_formatPrice(totalSales)} ریال',
                    font,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.green,
                  ),
                  pw.SizedBox(height: 8),
                  _pdfShareTextWidget(
                    'مجموع نسیه: ${_formatPrice(totalCredit)} ریال',
                    font,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.orange,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
            _pdfShareTextWidget(
              'لیست فاکتورها:',
              font,
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
            ),
            pw.SizedBox(height: 10),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.black, width: 0.8),
              tableWidth: pw.TableWidth.max,
              columnWidths: const {
                0: pw.FlexColumnWidth(0.65),
                1: pw.FlexColumnWidth(0.8),
                2: pw.FlexColumnWidth(2.2),
                3: pw.FlexColumnWidth(0.8),
                4: pw.FlexColumnWidth(1.65),
                5: pw.FlexColumnWidth(1.55),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.green100),
                  children: [
                    _pdfShareCell('ردیف', font, bold: true),
                    _pdfShareCell('شماره', font, bold: true),
                    _pdfShareCell('کالا', font, bold: true),
                    _pdfShareCell('تعداد', font, bold: true),
                    _pdfShareCell('قیمت', font, bold: true),
                    _pdfShareCell('مشتری', font, bold: true),
                  ],
                ),
                ..._salesInvoices.asMap().entries.map((entry) {
                  final index = entry.key + 1;
                  final inv = entry.value;
                  final customerName = inv.customerName.trim().isEmpty
                      ? 'نقدی'
                      : inv.customerName.trim();
                  return pw.TableRow(
                    children: [
                      _pdfShareCell(_toPersianDigits(index.toString()), font),
                      _pdfShareCell(
                          _toPersianDigits(inv.number.toString()), font),
                      _pdfShareCell(inv.productName, font,
                          align: pw.TextAlign.right),
                      _pdfShareCell(
                          _toPersianDigits(inv.quantity.toString()), font),
                      _pdfShareCell(
                          '${_formatPrice(inv.totalPrice)} ریال', font,
                          fontSize: 8.5),
                      _pdfShareCell(customerName, font, fontSize: 8.5),
                    ],
                  );
                }),
              ],
            ),
            pw.SizedBox(height: 24),
            pw.Align(
              alignment: pw.Alignment.centerLeft,
              child: _pdfShareTextWidget(
                'تاریخ تهیه: ${_todayJalali()}',
                font,
                fontSize: 9,
                color: PdfColors.grey600,
                textAlign: pw.TextAlign.left,
              ),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();
      final tempFile = File('${Directory.systemTemp.path}/sales_report.pdf');
      await tempFile.writeAsBytes(bytes, flush: true);

      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text:
            'گزارش فروش\nتعداد فاکتورها: ${_toPersianDigits(_salesInvoices.length.toString())}',
      );

      _showSuccessMessage('گزارش فروش ارسال شد');
    } catch (e) {
      _showSuccessMessage('خطا در ارسال گزارش فروش: $e');
    }
  }

  void _viewInvoiceDetails(SalesInvoice invoice) {
    _closeKeyboard();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: Row(
          children: [
            const Icon(Icons.receipt_long, color: Colors.green),
            const SizedBox(width: 8),
            Text(
              '🧾 فاکتور شماره ${invoice.number}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('📅 تاریخ:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Text(invoice.date),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text('🏷️ کالا:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Text(invoice.productName),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text('📊 تعداد:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Text('${invoice.quantity}'),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text('💰 قیمت واحد:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Text(_displayPrice(invoice.price)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text('💵 مجموع:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Text(
                          _displayPrice(math.max(
                              0, invoice.totalPrice - invoice.discount)),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, color: Colors.green),
                        ),
                      ],
                    ),
                    if (invoice.isCredit) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text('👤 مشتری:',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(width: 8),
                          Text(invoice.customerName),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text('📱 موبایل:',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(width: 8),
                          Text(invoice.customerPhone),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text('💳 نوع:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: invoice.isCredit
                                ? Colors.orange.shade100
                                : Colors.green.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            invoice.isCredit ? 'نسیه' : 'نقدی',
                            style: TextStyle(
                              color: invoice.isCredit
                                  ? Colors.orange.shade700
                                  : Colors.green.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _closeKeyboard();
              Navigator.pop(context);
            },
            child: const Text('بستن'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.print),
            label: const Text('چاپ'),
            onPressed: () {
              Navigator.pop(context);
              _printInvoice(invoice);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _printInvoice(SalesInvoice invoice) async {
    try {
      _closeKeyboard();
      final font = await _loadFont();
      final pdf = pw.Document();

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Center(
                  child: pw.Text(
                    '🧾 فاکتور فروش شماره ${invoice.number}',
                    style: pw.TextStyle(
                      fontSize: 28,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.green,
                      font: font,
                    ),
                  ),
                ),
                pw.SizedBox(height: 20),
                pw.Container(
                  padding: const pw.EdgeInsets.all(12),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey300),
                    borderRadius: pw.BorderRadius.circular(8),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Row(
                        children: [
                          pw.Text('📅 تاریخ:',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold, font: font)),
                          pw.SizedBox(width: 8),
                          pw.Text(invoice.date,
                              style: pw.TextStyle(font: font)),
                        ],
                      ),
                      pw.SizedBox(height: 4),
                      pw.Row(
                        children: [
                          pw.Text('🏷️ کالا:',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold, font: font)),
                          pw.SizedBox(width: 8),
                          pw.Text(invoice.productName,
                              style: pw.TextStyle(font: font)),
                        ],
                      ),
                      pw.SizedBox(height: 4),
                      pw.Row(
                        children: [
                          pw.Text('📊 تعداد:',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold, font: font)),
                          pw.SizedBox(width: 8),
                          pw.Text('${invoice.quantity}',
                              style: pw.TextStyle(font: font)),
                        ],
                      ),
                      pw.SizedBox(height: 4),
                      pw.Row(
                        children: [
                          pw.Text('💰 قیمت واحد:',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold, font: font)),
                          pw.SizedBox(width: 8),
                          pw.Text('${_formatPrice(invoice.price)} ریال',
                              style: pw.TextStyle(font: font)),
                        ],
                      ),
                      pw.SizedBox(height: 4),
                      if (invoice.discount > 0) ...[
                        pw.SizedBox(height: 4),
                        pw.Row(
                          children: [
                            pw.Text('🏷️ تخفیف:',
                                style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                    font: font)),
                            pw.SizedBox(width: 8),
                            pw.Text('${_formatPrice(invoice.discount)} ریال',
                                style: pw.TextStyle(
                                    color: PdfColors.red, font: font)),
                          ],
                        ),
                      ],
                      pw.SizedBox(height: 4),
                      pw.Row(
                        children: [
                          pw.Text('💵 مبلغ نهایی:',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold, font: font)),
                          pw.SizedBox(width: 8),
                          pw.Text(
                              '${_formatPrice(math.max(0, invoice.totalPrice - invoice.discount))} ریال',
                              style: pw.TextStyle(
                                  color: PdfColors.green,
                                  fontWeight: pw.FontWeight.bold,
                                  font: font)),
                        ],
                      ),
                      if (invoice.isCredit) ...[
                        pw.SizedBox(height: 4),
                        pw.Row(
                          children: [
                            pw.Text('👤 مشتری:',
                                style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                    font: font)),
                            pw.SizedBox(width: 8),
                            pw.Text(invoice.customerName,
                                style: pw.TextStyle(font: font)),
                          ],
                        ),
                        pw.SizedBox(height: 4),
                        pw.Row(
                          children: [
                            pw.Text('📱 موبایل:',
                                style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold,
                                    font: font)),
                            pw.SizedBox(width: 8),
                            pw.Text(invoice.customerPhone,
                                style: pw.TextStyle(font: font)),
                          ],
                        ),
                      ],
                      pw.SizedBox(height: 4),
                      pw.Row(
                        children: [
                          pw.Text('💳 نوع:',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold, font: font)),
                          pw.SizedBox(width: 8),
                          pw.Text(invoice.isCredit ? 'نسیه' : 'نقدی',
                              style: pw.TextStyle(font: font)),
                        ],
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 30),
                pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Text(
                    '📌 تاریخ چاپ: ${_todayJalali()}',
                    style: pw.TextStyle(
                      fontSize: 10,
                      color: PdfColors.grey,
                      font: font,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );

      await Printing.sharePdf(
        bytes: await pdf.save(),
        filename: 'invoice_${invoice.number}.pdf',
      );

      _showSuccessMessage('✅ فاکتور ارسال شد');
    } catch (e) {
      _showSuccessMessage('❌ خطا در چاپ فاکتور');
    }
  }

  void _openSalesInvoicesScreen() {
    _closeKeyboard();
    Navigator.push(
      context,
      _slideRoute(
        SalesInvoicesScreen(
          invoices: _salesInvoices,
          onInvoiceDeleted: (group) async {
            if (group.isEmpty) return;
            await _addToTrash(
              type: 'invoice',
              title: 'فاکتور شماره ${group.first.number}',
              data: {'invoices': group.map((e) => e.toJson()).toList()},
            );
            setState(() {
              _salesInvoices
                  .removeWhere((inv) => inv.number == group.first.number);
              for (final invoice in group) {
                final pIndex = _productDatabase
                    .indexWhere((p) => p.barcode == invoice.barcode);
                if (pIndex != -1) {
                  final p = _productDatabase[pIndex];
                  _productDatabase[pIndex] = ProductDatabaseItem(
                    barcode: p.barcode,
                    name: p.name,
                    stock: p.stock + invoice.quantity,
                    buyPrice: p.buyPrice,
                    sellPrice: p.sellPrice,
                    folder: p.folder,
                    groupName: p.groupName,
                    isPriceModified: p.isPriceModified,
                    originalSellPrice: p.originalSellPrice,
                    isNewProduct: p.isNewProduct,
                  );
                }
              }
            });
            await _saveSalesInvoices();
            await _saveProductDatabase();
            _addSmartLog('🗑️ فاکتور فروش به سطل زباله منتقل شد');
          },
          onInvoiceUpdated: (updatedInvoices) {
            setState(() {
              _salesInvoices = updatedInvoices;
            });
            _saveSalesInvoices();
          },
          onInvoiceEditRequested: (group) => _showSalesDialog(editGroup: group),
          onNewInvoice: _showSalesDialog,
          onViewDetails: _viewInvoiceDetails,
        ),
      ),
    );
  }

  Future<void> _loadSalesInvoices() async {
    final prefs = await SharedPreferences.getInstance();
    final dataStr = prefs.getString('sales_invoices');
    if (dataStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(dataStr);
        setState(() {
          _salesInvoices =
              decoded.map((item) => SalesInvoice.fromJson(item)).toList();
        });
      } catch (e) {}
    }
  }

  Future<void> _saveSalesInvoices() async {
    final prefs = await SharedPreferences.getInstance();
    final dataJson = _salesInvoices.map((p) => p.toJson()).toList();
    await prefs.setString('sales_invoices', jsonEncode(dataJson));
  }

  Future<void> _loadInventoryCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('inventory_counts');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List;
      final items = decoded
          .map(
              (e) => InventoryCountEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (mounted) setState(() => _inventoryCounts = items);
    } catch (_) {}
  }

  Future<void> _saveInventoryCounts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'inventory_counts',
      jsonEncode(_inventoryCounts.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _loadDailyExpenses() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString('daily_expenses');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List;
      final items = decoded
          .map((e) => DailyExpense.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (mounted) setState(() => _dailyExpenses = items);
    } catch (_) {}
  }

  Future<void> _saveDailyExpenses() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'daily_expenses',
      jsonEncode(_dailyExpenses.map((e) => e.toJson()).toList()),
    );
    await _syncManagerSharedSnapshot();
  }

  Future<void> _openDailyExpensesScreen() async {
    _closeKeyboard();
    await Navigator.push(
      context,
      _slideRoute(
        DailyExpensesScreen(
          expenses: List<DailyExpense>.from(_dailyExpenses),
          onChanged: (updated) async {
            setState(() => _dailyExpenses = updated);
            await _saveDailyExpenses();
          },
        ),
      ),
    );
    await _loadDailyExpenses();
  }

  Future<void> _openInventoryCountScreen() async {
    _closeKeyboard();
    await Navigator.push(
      context,
      _slideRoute(
        InventoryCountScreen(
          products: List<ProductDatabaseItem>.from(_productDatabase),
          entries: List<InventoryCountEntry>.from(_inventoryCounts),
          onChanged: (updated) async {
            setState(() => _inventoryCounts = updated);
            await _saveInventoryCounts();
          },
        ),
      ),
    );
    await _loadInventoryCounts();
  }

  Future<void> _loadTrashAndCleanup() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('trash_items');
    List<TrashItem> items = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List;
        items = decoded
            .map((e) => TrashItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {}
    }
    final cutoff =
        DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final cleaned = items.where((e) => e.deletedAt > cutoff).toList();
    if (cleaned.length != items.length) {
      await prefs.setString(
          'trash_items', jsonEncode(cleaned.map((e) => e.toJson()).toList()));
    }
    if (mounted) setState(() => _trashItems = cleaned);
  }

  Future<void> _saveTrash() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'trash_items', jsonEncode(_trashItems.map((e) => e.toJson()).toList()));
  }

  Future<void> _addToTrash({
    required String type,
    required String title,
    required Map<String, dynamic> data,
  }) async {
    final item = TrashItem(
      id: '${DateTime.now().millisecondsSinceEpoch}-${_trashItems.length}',
      type: type,
      title: title,
      deletedAt: DateTime.now().millisecondsSinceEpoch,
      data: data,
    );
    _trashItems.add(item);
    await _saveTrash();
  }

  Future<bool> _restoreTrashItem(TrashItem item) async {
    try {
      if (item.type == 'invoice') {
        final raw = item.data['invoices'];
        if (raw is! List) return false;

        final invoices = raw
            .map((e) => SalesInvoice.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        if (invoices.isEmpty) return false;

        // هر فاکتور با شناسه (id) خودش یکتا است؛ شماره فاکتور معیار تشخیص
        // «فاکتور مشابه» نیست. فقط اگر خود همان id قبلاً وجود داشته باشد
        // بازیابی متوقف می‌شود.
        final activeIds = _salesInvoices.map((x) => x.id).toSet();
        if (invoices.any((inv) => activeIds.contains(inv.id))) {
          return false;
        }

        // حذف فاکتور قبلاً موجودی را برگردانده است. هنگام بازیابی همان مقدار
        // دوباره از موجودی کم می‌شود؛ اگر موجودی در این فاصله مصرف شده باشد،
        // بازیابی فقط در صورت کافی بودن موجودی انجام می‌شود.
        final requiredByBarcode = <String, int>{};
        for (final inv in invoices) {
          requiredByBarcode[inv.barcode] =
              (requiredByBarcode[inv.barcode] ?? 0) + inv.quantity;
        }
        for (final entry in requiredByBarcode.entries) {
          final idx =
              _productDatabase.indexWhere((p) => p.barcode == entry.key);
          if (idx == -1 || _productDatabase[idx].stock < entry.value) {
            return false;
          }
        }

        final originalNumber = invoices.first.number;
        final numberConflict = _salesInvoices.any(
          (x) => x.number == originalNumber && !activeIds.contains(x.id),
        );
        final restoreNumber =
            numberConflict ? _getNextInvoiceNumber() : originalNumber;

        for (final inv in invoices) {
          final restored = inv.number == restoreNumber
              ? inv
              : inv.copyWith(number: restoreNumber);
          _salesInvoices.add(restored);
        }

        for (final entry in requiredByBarcode.entries) {
          final idx =
              _productDatabase.indexWhere((p) => p.barcode == entry.key);
          if (idx == -1) continue;
          final p = _productDatabase[idx];
          _productDatabase[idx] = ProductDatabaseItem(
            barcode: p.barcode,
            name: p.name,
            stock: (p.stock - entry.value).clamp(0, 1 << 30).toInt(),
            buyPrice: p.buyPrice,
            sellPrice: p.sellPrice,
            folder: p.folder,
          );
        }

        await _saveSalesInvoices();
        await _saveProductDatabase();
      } else if (item.type == 'product') {
        final product = ProductDatabaseItem.fromJson(item.data);
        if (_productDatabase.any((p) => p.barcode == product.barcode)) {
          return false;
        }
        _productDatabase.add(product);
        await _saveProductDatabase();
      } else if (item.type == 'manifest') {
        final manifest = DeliveryManifest.fromJson(item.data);
        if (_savedManifests.any((m) => m.id == manifest.id)) return false;
        _savedManifests.add(manifest);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'delivery_manifests',
          jsonEncode(_savedManifests.map((m) => m.toJson()).toList()),
        );
      } else if (item.type == 'manifest_item') {
        final manifestId = item.data['manifestId']?.toString();
        final manifestIndex =
            _savedManifests.indexWhere((m) => m.id == manifestId);
        if (manifestIndex == -1) return false;
        final deliveryItem = DeliveryItem.fromJson(
          Map<String, dynamic>.from(item.data['item'] ?? {}),
        );
        final manifest = _savedManifests[manifestIndex];
        if (manifest.items.any((x) =>
            x.barcode == deliveryItem.barcode &&
            x.name == deliveryItem.name &&
            x.quantity == deliveryItem.quantity)) {
          return false;
        }
        manifest.items.add(deliveryItem);
        manifest.totalPrice +=
            deliveryItem.purchasePrice * deliveryItem.realQuantity;
        await _saveManifestChanges(manifest);
      } else {
        return false;
      }
      _trashItems.removeWhere((x) => x.id == item.id);
      await _saveTrash();
      if (mounted) setState(() {});
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openTrashScreen() async {
    _closeKeyboard();
    await Navigator.push(
      context,
      _slideRoute(
        TrashScreen(
          items: _trashItems,
          onRestore: _restoreTrashItem,
          onChanged: () async {
            await _loadTrashAndCleanup();
          },
        ),
      ),
    );
    await _loadTrashAndCleanup();
  }

  Future<String?> _createInvoiceNotificationImage(
      List<SalesInvoice> invoices) async {
    if (invoices.isEmpty) return null;
    try {
      final font = await _loadFont();
      final pdf = pw.Document();
      final total = invoices.fold<int>(
        0,
        (sum, invoice) => sum + invoice.totalPrice,
      );
      final number = invoices.first.number;
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(30),
          textDirection: pw.TextDirection.rtl,
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _pdfTextWidget(
                'فاکتور فروش',
                font,
                fontSize: 24,
                fontWeight: pw.FontWeight.bold,
                textAlign: pw.TextAlign.center,
              ),
              pw.SizedBox(height: 20),
              _pdfTextWidget(
                'شماره فاکتور: ${_toPersianDigits(number.toString())}',
                font,
                fontSize: 15,
                fontWeight: pw.FontWeight.bold,
              ),
              pw.SizedBox(height: 10),
              _pdfTextWidget(
                'تعداد اقلام: ${_toPersianDigits(invoices.length.toString())}',
                font,
                fontSize: 14,
              ),
              pw.SizedBox(height: 10),
              _pdfTextWidget(
                'مبلغ کل: ${_toPersianDigits(_formatPrice(total))} ریال',
                font,
                fontSize: 17,
                fontWeight: pw.FontWeight.bold,
              ),
              pw.SizedBox(height: 18),
              _pdfTextWidget(
                'تاریخ: ${_todayJalaliLong()}',
                font,
                fontSize: 12,
              ),
            ],
          ),
        ),
      );
      final bytes = await pdf.save();
      final pages =
          await Printing.raster(bytes, pages: const [0], dpi: 120).toList();
      if (pages.isEmpty) return null;
      final png = await pages.first.toPng();
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/invoice_notification_$number.png');
      await file.writeAsBytes(png, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showSalesDialog({
    String? productName,
    String? productBarcode,
    int? sellPrice,
    List<SalesInvoice>? editGroup,
  }) async {
    _closeKeyboard();
    final customerNameCtrl = TextEditingController(
        text:
            editGroup?.isNotEmpty == true ? editGroup!.first.customerName : '');
    final customerPhoneCtrl = TextEditingController(
        text: editGroup?.isNotEmpty == true
            ? editGroup!.first.customerPhone
            : '');
    final dateCtrl = TextEditingController(
        text: editGroup?.isNotEmpty == true
            ? editGroup!.first.date
            : _getTodayDate());
    final searchCtrl = TextEditingController();
    final discountCtrl = TextEditingController(
        text: editGroup?.isNotEmpty == true && editGroup!.first.discount > 0
            ? _formatPrice(editGroup!.first.discount)
            : '');
    bool isCredit =
        editGroup?.isNotEmpty == true ? editGroup!.first.isCredit : false;
    final selected = <Map<String, dynamic>>[];

    if (editGroup != null) {
      for (final inv in editGroup) {
        final product =
            _productDatabase.cast<ProductDatabaseItem?>().firstWhere(
                  (p) => p?.barcode == inv.barcode,
                  orElse: () => null,
                );
        if (product != null) {
          selected.add({'product': product, 'quantity': inv.quantity});
        } else {
          selected.add({
            'product': ProductDatabaseItem(
              barcode: inv.barcode,
              name: inv.productName,
              stock: 0,
              buyPrice: 0,
              sellPrice: inv.price,
            ),
            'quantity': inv.quantity,
          });
        }
      }
    }

    if (productBarcode != null && productBarcode.isNotEmpty) {
      final product = _productDatabase.cast<ProductDatabaseItem?>().firstWhere(
            (p) => p?.barcode == productBarcode,
            orElse: () => null,
          );
      if (product != null) {
        selected.add({'product': product, 'quantity': 1});
      } else if (productName != null && productName.isNotEmpty) {
        selected.add({
          'product': ProductDatabaseItem(
            barcode: productBarcode,
            name: productName,
            stock: 0,
            buyPrice: 0,
            sellPrice: sellPrice ?? 0,
          ),
          'quantity': 1,
        });
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final query = _normalizeSearchText(searchCtrl.text);
            final products = _productDatabase.where((p) {
              if (query.isEmpty) return true;
              return _normalizeSearchText(p.name).contains(query) ||
                  p.barcode.contains(query);
            }).toList();

            void addProduct(ProductDatabaseItem product) {
              final index = selected.indexWhere(
                (e) =>
                    (e['product'] as ProductDatabaseItem).barcode ==
                    product.barcode,
              );
              setSheetState(() {
                if (index >= 0) {
                  selected[index]['quantity'] =
                      (selected[index]['quantity'] as int) + 1;
                } else {
                  selected.add({'product': product, 'quantity': 1});
                }
              });
            }

            final total = selected.fold<int>(0, (sum, line) {
              final p = line['product'] as ProductDatabaseItem;
              return sum + p.sellPrice * (line['quantity'] as int);
            });

            return SafeArea(
              child: DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.78,
                minChildSize: 0.55,
                maxChildSize: 0.96,
                snap: true,
                snapSizes: const [0.55, 0.78, 0.96],
                builder: (context, scrollController) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(
                      children: [
                        Text(
                            editGroup != null ? 'ویرایش فاکتور' : 'فاکتور فروش',
                            style: TextStyle(
                                fontSize: 21, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        if (editGroup != null) ...[
                          TextField(
                            controller: dateCtrl,
                            decoration: const InputDecoration(
                              labelText: 'تاریخ فاکتور',
                              prefixIcon: Icon(Icons.calendar_today_outlined),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              Row(children: [
                                const Icon(Icons.person_outline),
                                const SizedBox(width: 8),
                                const Expanded(
                                    child: Text('مشخصات مشتری',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold))),
                                Switch(
                                    value: isCredit,
                                    onChanged: (v) =>
                                        setSheetState(() => isCredit = v)),
                                const Text('نسیه'),
                              ]),
                              if (isCredit) ...[
                                const SizedBox(height: 8),
                                TextField(
                                  controller: customerNameCtrl,
                                  decoration: const InputDecoration(
                                      labelText: 'نام مشتری *',
                                      prefixIcon: Icon(Icons.person)),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: customerPhoneCtrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                      labelText: 'شماره موبایل *',
                                      prefixIcon: Icon(Icons.phone)),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: searchCtrl,
                              onChanged: (_) => setSheetState(() {}),
                              decoration: InputDecoration(
                                labelText: 'جستجوی کالا',
                                hintText: 'نام کالا یا بارکد',
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: searchCtrl.text.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () {
                                          searchCtrl.clear();
                                          setSheetState(() {});
                                        }),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            tooltip: 'اسکن بارکد با دوربین',
                            icon: const Icon(Icons.qr_code_scanner),
                            onPressed: () async {
                              _closeKeyboard();
                              final result = await Navigator.push<String>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const BarcodeScannerScreen()),
                              );
                              if (result == null || result.isEmpty) return;
                              final product = _productDatabase
                                  .cast<ProductDatabaseItem?>()
                                  .firstWhere(
                                    (p) => p?.barcode == result,
                                    orElse: () => null,
                                  );
                              if (product != null) {
                                addProduct(product);
                                searchCtrl.text = result;
                                setSheetState(() {});
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'کالایی با این بارکد در بانک اطلاعاتی پیدا نشد')));
                              }
                            },
                          ),
                        ]),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView(
                            controller: scrollController,
                            children: [
                              if (selected.isNotEmpty) ...[
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 8),
                                  child: Text('اقلام فاکتور',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16)),
                                ),
                                ...selected.map((line) {
                                  final p =
                                      line['product'] as ProductDatabaseItem;
                                  final qty = line['quantity'] as int;
                                  return Card(
                                    child: ListTile(
                                      leading:
                                          CircleAvatar(child: Text('$qty')),
                                      title: Text(p.name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold)),
                                      subtitle: Text(
                                          'قیمت فروش: ${_displayPrice(p.sellPrice)} | موجودی: ${p.stock}'),
                                      trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                                icon: const Icon(Icons
                                                    .remove_circle_outline),
                                                onPressed: () =>
                                                    setSheetState(() {
                                                      if (qty > 1)
                                                        line['quantity'] =
                                                            qty - 1;
                                                      else
                                                        selected.remove(line);
                                                    })),
                                            Text('$qty'),
                                            IconButton(
                                                icon: const Icon(
                                                    Icons.add_circle_outline,
                                                    color: Colors.green),
                                                onPressed: () => setSheetState(
                                                    () => line['quantity'] =
                                                        qty + 1)),
                                          ]),
                                    ),
                                  );
                                }),
                                const Divider(),
                              ],
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text('انتخاب کالا',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                              ),
                              ...products.map((p) => Card(
                                    child: ListTile(
                                      onTap: () => addProduct(p),
                                      leading: const Icon(
                                          Icons.inventory_2_outlined),
                                      title: Text(p.name),
                                      subtitle: Text(
                                          'موجودی: ${p.stock}  •  قیمت فروش: ${_displayPrice(p.sellPrice)}'),
                                      trailing: const Icon(
                                          Icons.add_circle_outline,
                                          color: Colors.green),
                                    ),
                                  )),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'مجموع کالاها: ${_displayPrice(total)}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 17),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 150,
                                      child: TextField(
                                        controller: discountCtrl,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter.allow(
                                              RegExp(r'[0-9۰-۹٠-٩,]'))
                                        ],
                                        onChanged: (_) => setSheetState(() {}),
                                        decoration: const InputDecoration(
                                          labelText: 'تخفیف',
                                          suffixText: 'ریال',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'مبلغ نهایی: ${_displayPrice(math.max(0, total - (int.tryParse(_normalizeDigits(discountCtrl.text).replaceAll(',', '')) ?? 0)))} ریال',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green,
                                      fontSize: 16),
                                ),
                                const SizedBox(height: 6),
                                FilledButton.icon(
                                  icon: const Icon(Icons.check),
                                  label: Text(editGroup != null
                                      ? 'ذخیره تغییرات'
                                      : 'ثبت فاکتور'),
                                  onPressed: selected.isEmpty
                                      ? null
                                      : () async {
                                          _closeKeyboard();
                                          if (isCredit &&
                                              (customerNameCtrl.text
                                                      .trim()
                                                      .isEmpty ||
                                                  customerPhoneCtrl.text
                                                      .trim()
                                                      .isEmpty)) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(const SnackBar(
                                                    content: Text(
                                                        'برای فروش نسیه، نام مشتری و شماره موبایل الزامی است')));
                                            return;
                                          }
                                          final discount = int.tryParse(
                                                _normalizeDigits(
                                                        discountCtrl.text)
                                                    .replaceAll(',', '')
                                                    .trim(),
                                              ) ??
                                              0;
                                          if (discount < 0 ||
                                              discount > total) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                  content: Text(
                                                      'مبلغ تخفیف نمی‌تواند بیشتر از مجموع فاکتور باشد.')),
                                            );
                                            return;
                                          }
                                          final now = DateTime.now()
                                              .millisecondsSinceEpoch
                                              .toString();
                                          final invoiceNumber =
                                              editGroup != null
                                                  ? editGroup!.first.number
                                                  : _getNextInvoiceNumber();
                                          final newQuantities = <String, int>{};
                                          for (final line in selected) {
                                            final p = line['product']
                                                as ProductDatabaseItem;
                                            newQuantities[p.barcode] =
                                                (newQuantities[p.barcode] ??
                                                        0) +
                                                    (line['quantity'] as int);
                                          }
                                          final oldQuantities = <String, int>{};
                                          if (editGroup != null) {
                                            for (final inv in editGroup!) {
                                              oldQuantities[inv.barcode] =
                                                  (oldQuantities[inv.barcode] ??
                                                          0) +
                                                      inv.quantity;
                                            }
                                          }
                                          for (final entry
                                              in newQuantities.entries) {
                                            final idx = _productDatabase
                                                .indexWhere((p) =>
                                                    p.barcode == entry.key);
                                            if (idx == -1) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                    content: Text(
                                                        'کالای ${entry.key} در بانک اطلاعاتی موجود نیست')),
                                              );
                                              return;
                                            }
                                            final oldQty =
                                                oldQuantities[entry.key] ?? 0;
                                            final available =
                                                _productDatabase[idx].stock +
                                                    oldQty;
                                            if (entry.value > available) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                    content: Text(
                                                        'موجودی ${_productDatabase[idx].name} کافی نیست')),
                                              );
                                              return;
                                            }
                                          }
                                          if (editGroup != null) {
                                            _salesInvoices.removeWhere((inv) =>
                                                inv.number ==
                                                editGroup!.first.number);
                                          }
                                          final allBarcodes = <String>{
                                            ...oldQuantities.keys,
                                            ...newQuantities.keys,
                                          };
                                          for (final barcode in allBarcodes) {
                                            final idx = _productDatabase
                                                .indexWhere((p) =>
                                                    p.barcode == barcode);
                                            if (idx == -1) continue;
                                            final delta =
                                                (newQuantities[barcode] ?? 0) -
                                                    (oldQuantities[barcode] ??
                                                        0);
                                            if (delta != 0) {
                                              final p = _productDatabase[idx];
                                              _productDatabase[idx] =
                                                  ProductDatabaseItem(
                                                barcode: p.barcode,
                                                name: p.name,
                                                stock: (p.stock - delta)
                                                    .clamp(0, 1 << 30)
                                                    .toInt(),
                                                buyPrice: p.buyPrice,
                                                sellPrice: p.sellPrice,
                                                folder: p.folder,
                                              );
                                            }
                                          }
                                          for (var i = 0;
                                              i < selected.length;
                                              i++) {
                                            final line = selected[i];
                                            final p = line['product']
                                                as ProductDatabaseItem;
                                            final qty = line['quantity'] as int;
                                            final old = editGroup != null &&
                                                    i < editGroup!.length
                                                ? editGroup![i]
                                                : null;
                                            _salesInvoices.add(SalesInvoice(
                                              id: old?.id ??
                                                  '$now-${p.barcode}-$i',
                                              number: invoiceNumber,
                                              productName: p.name,
                                              barcode: p.barcode,
                                              price: p.sellPrice,
                                              quantity: qty,
                                              totalPrice: p.sellPrice * qty,
                                              discount: i == 0 ? discount : 0,
                                              customerName:
                                                  customerNameCtrl.text.trim(),
                                              customerPhone:
                                                  customerPhoneCtrl.text.trim(),
                                              isCredit: isCredit,
                                              date: editGroup != null
                                                  ? dateCtrl.text.trim()
                                                  : _getTodayDate(),
                                              createdAt: old?.createdAt ?? now,
                                            ));
                                          }
                                          await _saveSalesInvoices();
                                          await _saveProductDatabase();
                                          if (editGroup == null &&
                                              selected.isNotEmpty) {
                                            final notificationInvoices =
                                                <SalesInvoice>[];
                                            for (var n = 0;
                                                n < selected.length;
                                                n++) {
                                              final line = selected[n];
                                              final p = line['product']
                                                  as ProductDatabaseItem;
                                              final qty =
                                                  line['quantity'] as int;
                                              notificationInvoices.add(
                                                SalesInvoice(
                                                  id: '$now-notification-$n',
                                                  number: invoiceNumber,
                                                  productName: p.name,
                                                  barcode: p.barcode,
                                                  price: p.sellPrice,
                                                  quantity: qty,
                                                  totalPrice: p.sellPrice * qty,
                                                  discount:
                                                      n == 0 ? discount : 0,
                                                  customerName: customerNameCtrl
                                                      .text
                                                      .trim(),
                                                  customerPhone:
                                                      customerPhoneCtrl.text
                                                          .trim(),
                                                  isCredit: isCredit,
                                                  date: _getTodayDate(),
                                                  createdAt: now,
                                                ),
                                              );
                                            }
                                            final notificationTotal = math.max(
                                              0,
                                              notificationInvoices.fold<int>(
                                                    0,
                                                    (sum, invoice) =>
                                                        sum +
                                                        invoice.totalPrice,
                                                  ) -
                                                  discount,
                                            );
                                            final imagePath =
                                                await _createInvoiceNotificationImage(
                                                    notificationInvoices);
                                            await StoreNotificationService
                                                .instance
                                                .showInvoiceRegistered(
                                              invoiceNumber:
                                                  invoiceNumber.toString(),
                                              total: notificationTotal,
                                              invoiceImagePath: imagePath,
                                            );
                                          }
                                          if (editGroup == null &&
                                              selected.isNotEmpty) {
                                            final network = NetworkService();
                                            final eventId =
                                                await network.queueEvent(
                                              type: 'invoice_created',
                                              actorName: _userName,
                                              payload: {
                                                'invoiceNumber': invoiceNumber,
                                                'total': math.max(
                                                    0,
                                                    selected.fold<int>(0,
                                                            (sum, line) {
                                                          final p = line[
                                                                  'product']
                                                              as ProductDatabaseItem;
                                                          final qty =
                                                              line['quantity']
                                                                  as int;
                                                          return sum +
                                                              p.sellPrice * qty;
                                                        }) -
                                                        discount),
                                                'itemsCount': selected.length,
                                              },
                                            );
                                            await network.syncOutbox();
                                            await _upsertAppMessage(
                                              id: 'network:$eventId',
                                              title: 'ثبت فاکتور فروش',
                                              body: 'فاکتور شماره ${_toPersianDigits(invoiceNumber.toString())} با مبلغ ${_formatPrice(math.max(0, selected.fold<int>(0, (sum, line) {
                                                    final p = line['product']
                                                        as ProductDatabaseItem;
                                                    final qty =
                                                        line['quantity'] as int;
                                                    return sum +
                                                        p.sellPrice * qty;
                                                  }) - discount))} ریال ثبت شد.',
                                            );
                                          }
                                          _addSmartLog(editGroup != null
                                              ? '✏️ فاکتور شماره $invoiceNumber ویرایش شد'
                                              : '💰 فاکتور شماره $invoiceNumber با ${selected.length} قلم ثبت شد');
                                          setState(() {});
                                          Navigator.pop(sheetContext);
                                          _showSuccessMessage(editGroup != null
                                              ? 'فاکتور شماره $invoiceNumber ویرایش شد ✅'
                                              : 'فاکتور شماره $invoiceNumber ثبت شد ✅');
                                        },
                                ),
                              ]),
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
    dateCtrl.dispose();
    customerNameCtrl.dispose();
    customerPhoneCtrl.dispose();
    searchCtrl.dispose();
    discountCtrl.dispose();
  }

  void _openProductDatabaseScreen() {
    _closeKeyboard();
    Navigator.push(
      context,
      _slideRoute(
        ProductDatabaseScreen(
          database: _productDatabase,
          onDatabaseUpdated: (updatedList) {
            setState(() {
              _productDatabase = updatedList;
            });
            _saveProductDatabase();
            _addSmartLog('🔄 بانک اطلاعاتی کالاها به‌روزرسانی شد');
          },
          onItemDeleted: (item) async {
            await _addToTrash(
              type: 'product',
              title: 'کالا: ${item.name}',
              data: item.toJson(),
            );
            setState(() {
              _productDatabase.removeWhere((p) => p.barcode == item.barcode);
            });
            await _saveProductDatabase();
            _addSmartLog('🗑️ کالا به سطل زباله منتقل شد');
          },
          onDeleteAll: (items) async {
            for (final item in items) {
              await _addToTrash(
                type: 'product',
                title: 'کالا: ${item.name}',
                data: item.toJson(),
              );
            }
            setState(() => _productDatabase.clear());
            await _saveProductDatabase();
            _addSmartLog('🗑️ کل بانک اطلاعاتی به سطل زباله منتقل شد');
          },
        ),
      ),
    );
  }

  void _openSalesProfitScreen() {
    _closeKeyboard();
    Navigator.push(
      context,
      _slideRoute(
        SalesProfitScreen(
          products: List<ProductDatabaseItem>.from(_productDatabase),
          onPriceChanged: _updateProductSellingPrice,
        ),
      ),
    );
  }

  Future<void> _updateProductSellingPrice(
      ProductDatabaseItem updatedProduct) async {
    final index =
        _productDatabase.indexWhere((p) => p.barcode == updatedProduct.barcode);
    if (index == -1) return;
    setState(() {
      _productDatabase[index] = updatedProduct;
    });
    await _saveProductDatabase();
    _addSmartLog(
        '💰 قیمت فروش «${updatedProduct.name}» به ${_formatPrice(updatedProduct.sellPrice)} ریال تغییر یافت');
  }

  Future<void> _shareChangedPriceReport() async {
    final changed = _productDatabase.where((p) => p.isPriceModified).toList();
    if (changed.isEmpty) {
      _showSuccessMessage('⚠️ هنوز قیمت کالایی تغییر نکرده است');
      return;
    }
    try {
      _closeKeyboard();
      final font = await _loadFont();
      final pdf = pw.Document();
      final grouped = <String, List<ProductDatabaseItem>>{};
      for (final p in changed) {
        grouped
            .putIfAbsent(
                p.groupName.trim().isEmpty ? 'عمومی' : p.groupName.trim(),
                () => [])
            .add(p);
      }
      final totalOld = changed.fold<int>(
          0, (sum, p) => sum + (p.originalSellPrice ?? p.sellPrice));
      final totalNew = changed.fold<int>(0, (sum, p) => sum + p.sellPrice);

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 30, 28, 30),
          textDirection: pw.TextDirection.rtl,
          maxPages: 500,
          build: (context) => [
            pw.Center(
                child: _pdfShareTextWidget('گزارش قیمت‌های تغییر یافته', font,
                    fontSize: 24,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.orange,
                    textAlign: pw.TextAlign.center)),
            pw.SizedBox(height: 16),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(8)),
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    _pdfShareTextWidget(
                        'تعداد کالاهای تغییر یافته: ${_toPersianDigits(changed.length.toString())}',
                        font,
                        fontWeight: pw.FontWeight.bold),
                    pw.SizedBox(height: 6),
                    _pdfShareTextWidget(
                        'مجموع قیمت فروش قبل: ${_formatPrice(totalOld)} ریال',
                        font),
                    pw.SizedBox(height: 6),
                    _pdfShareTextWidget(
                        'مجموع قیمت فروش جدید: ${_formatPrice(totalNew)} ریال',
                        font,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.green),
                    pw.SizedBox(height: 6),
                    _pdfShareTextWidget(
                        'تاریخ تهیه گزارش: ${_todayJalali()}', font,
                        fontSize: 9, color: PdfColors.grey600),
                  ]),
            ),
            pw.SizedBox(height: 18),
            ...grouped.entries.expand((entry) => [
                  _pdfShareTextWidget('گروه: ${entry.key}', font,
                      fontSize: 17, fontWeight: pw.FontWeight.bold),
                  pw.SizedBox(height: 8),
                  pw.Table(
                    border: pw.TableBorder.all(color: PdfColors.grey500),
                    tableWidth: pw.TableWidth.max,
                    columnWidths: const {
                      0: pw.FixedColumnWidth(32),
                      1: pw.FlexColumnWidth(3.2),
                      2: pw.FlexColumnWidth(1.8),
                      3: pw.FlexColumnWidth(1.8),
                      4: pw.FlexColumnWidth(1.7)
                    },
                    children: [
                      pw.TableRow(
                          decoration: const pw.BoxDecoration(
                              color: PdfColors.orange100),
                          children: [
                            _pdfShareCell('ردیف', font, bold: true),
                            _pdfShareCell('کالا', font, bold: true),
                            _pdfShareCell('قیمت قبل', font, bold: true),
                            _pdfShareCell('قیمت جدید', font, bold: true),
                            _pdfShareCell('تغییر', font, bold: true),
                          ]),
                      ...entry.value.asMap().entries.map((e) {
                        final p = e.value;
                        final old = p.originalSellPrice ?? p.sellPrice;
                        final diff = p.sellPrice - old;
                        return pw.TableRow(children: [
                          _pdfShareCell('${e.key + 1}', font),
                          _pdfShareCell(p.name, font,
                              align: pw.TextAlign.right),
                          _pdfShareCell('${_formatPrice(old)} ریال', font,
                              fontSize: 8),
                          _pdfShareCell(
                              '${_formatPrice(p.sellPrice)} ریال', font,
                              fontSize: 8),
                          _pdfShareCell(
                              '${diff >= 0 ? '+' : '-'}${_formatPrice(diff.abs())}',
                              font,
                              fontSize: 8),
                        ]);
                      }),
                    ],
                  ),
                  pw.SizedBox(height: 16),
                ]),
          ],
        ),
      );
      final bytes = await pdf.save();
      final tempFile =
          File('${Directory.systemTemp.path}/changed_prices_report.pdf');
      await tempFile.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(tempFile.path)],
          text: 'گزارش قیمت‌های تغییر یافته\nتعداد کالاها: ${changed.length}');
      _showSuccessMessage('گزارش قیمت‌های تغییر یافته ارسال شد');
    } catch (e) {
      _showSuccessMessage('خطا در تهیه گزارش قیمت‌ها: $e');
    }
  }

  void _openSettingsScreen() {
    _closeKeyboard();
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _openSettingsPageFromDrawer() {
    _closeKeyboard();
    Navigator.pop(context);
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      Navigator.push(
        context,
        _slideRoute(
          SettingsScreen(
            isDarkMode: false,
            userName: _userName,
            customEvents: List<CustomEvent>.from(_customEvents),
            onCustomEventsChanged: (events) async {
              setState(() => _customEvents = events);
              await _saveCustomEvents();
              final prefs = await SharedPreferences.getInstance();
              if (prefs.getBool('notifications_enabled') == true &&
                  _userName.isNotEmpty) {
                if (await StoreNotificationService.instance.isEnabled()) {
                  await StoreNotificationService.instance
                      .scheduleMorningNotifications(
                    userName: _userName,
                    gender: _userGender,
                    customEvents: List<CustomEvent>.from(events),
                  );
                }
              }
            },
            onFixedEventDatesChanged: (inventoryDate, cleaningDate) async {
              if (!mounted) return;
              setState(() {
                _lastInventoryDate = inventoryDate;
                _lastCleaningDate = cleaningDate;
              });
              final prefs = await SharedPreferences.getInstance();
              await _syncManagerSharedSnapshot();
              if (prefs.getBool('notifications_enabled') == true &&
                  _userName.isNotEmpty) {
                await StoreNotificationService.instance
                    .scheduleMorningNotifications(
                  userName: _userName,
                  gender: _userGender,
                  customEvents: List<CustomEvent>.from(_customEvents),
                );
              }
            },
            onSettingsChanged: (darkMode, name) {
              if (!mounted) return;
              setState(() {
                _userName = name;
              });
            },
          ),
        ),
      );
    });
  }

  void _showSuccessMessage(String message) {
    OverlayEntry overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).size.height / 2 - 60,
        left: MediaQuery.of(context).size.width / 2 - 120,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 240,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            decoration: BoxDecoration(
              color: message.contains('❌') || message.contains('خطا')
                  ? Colors.red.shade700
                  : Colors.green.shade700,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  message.contains('❌') || message.contains('خطا')
                      ? Icons.error_outline
                      : Icons.check_circle,
                  color: Colors.white,
                  size: 40,
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(overlayEntry);
    Future.delayed(const Duration(seconds: 2), () {
      overlayEntry.remove();
    });
  }

  void _addSmartLog(String message) {
    setState(() {
      final timestamp = DateTime.now();
      final time =
          '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
      _smartLogs.insert(0, '[$time] $message');
    });
    _saveSmartLogs();
  }

  Future<void> _loadSmartLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('smart_logs');
    if (logsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(logsJson);
        setState(() {
          _smartLogs = decoded.map((item) => item.toString()).toList();
        });
      } catch (e) {}
    }
  }

  Future<void> _saveSmartLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('smart_logs', jsonEncode(_smartLogs));
  }

  void _clearSmartLogs() {
    _closeKeyboard();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('پاک کردن گزارش هوشمند'),
        content:
            const Text('آیا از پاک کردن همه گزارش‌های هوشمند مطمئن هستید؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              setState(() {
                _smartLogs.clear();
              });
              _saveSmartLogs();
              Navigator.pop(context);
              _showSuccessMessage('گزارش‌ها پاک شدند 🗑️');
            },
            child: const Text('پاک کردن همه'),
          ),
        ],
      ),
    );
  }

  void _searchItems(String query) {
    setState(() {
      _isSearching = query.isNotEmpty;
      _filteredItems.clear();
      _manifestSearchResults.clear();

      if (query.isEmpty) {
        _isSearching = false;
        return;
      }

      final searchTerm = _normalizeSearchText(query);

      final currentResults = _currentItems
          .where((item) =>
              _normalizeSearchText(item.name).contains(searchTerm) ||
              item.barcode.contains(searchTerm))
          .toList();
      _filteredItems = currentResults;

      for (var manifest in _savedManifests) {
        for (var item in manifest.items) {
          if (_normalizeSearchText(item.name).contains(searchTerm) ||
              item.barcode.contains(searchTerm)) {
            _manifestSearchResults.add({
              'manifest': manifest,
              'item': item,
            });
          }
        }
      }
    });
  }

  void _clearControllers() {
    _nameController.clear();
    _quantityController.clear();
    _purchasePriceController.clear();
    _barcodeController.clear();
    _packageSizeController.clear();
    setState(() {
      _selectedUnit = 'عدد';
      _isPackageUnit = false;
    });
  }

  void _removeItem(int index) {
    setState(() {
      if (_isSearching && _filteredItems.isNotEmpty) {
        final itemToRemove = _filteredItems[index];
        _currentItems.remove(itemToRemove);
        _filteredItems.removeAt(index);
        if (_filteredItems.isEmpty) {
          _isSearching = false;
          _searchController.clear();
        }
      } else {
        _currentItems.removeAt(index);
      }
    });
  }

  int get _totalPurchasePrice {
    int total = 0;
    for (var item in _currentItems) {
      total += item.purchasePrice * item.realQuantity;
    }
    return total;
  }

  void _submitDelivery() async {
    _closeKeyboard();
    final TextEditingController dateController = TextEditingController();
    final TextEditingController senderCtrl = TextEditingController();
    final TextEditingController freightCostCtrl = TextEditingController();
    dateController.text = _getTodayDate();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text(
          'ثبت نهایی تحویل بار',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('لطفاً تاریخ بارنامه را وارد کنید:'),
            const SizedBox(height: 16),
            TextFormField(
              controller: dateController,
              decoration: InputDecoration(
                labelText: 'تاریخ (مثلاً ۱۴۰۴/۰۵/۱۵)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.calendar_today),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: senderCtrl,
              decoration: InputDecoration(
                labelText: 'نام شرکت ارسال کننده',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.local_shipping_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: freightCostCtrl,
              decoration: InputDecoration(
                labelText: 'هزینه باربری (ریال)',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.payments_outlined),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.green.shade50, Colors.green.shade100],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'تعداد کالاها: ${_currentItems.length}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'مجموع قیمت: ${_displayPrice(_totalPurchasePrice)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'شماره بارنامه: ${_getNextManifestNumber()}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.blue),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              final manifestDate = dateController.text.isEmpty
                  ? _getTodayDate()
                  : dateController.text;

              final manifest = DeliveryManifest(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                number: _getNextManifestNumber(),
                date: manifestDate,
                items: List.from(_currentItems),
                totalPrice: _totalPurchasePrice,
                freightCost:
                    int.tryParse(freightCostCtrl.text.replaceAll(',', '')) ?? 0,
                senderCompany: senderCtrl.text.trim(),
                createdAt: DateTime.now().millisecondsSinceEpoch.toString(),
              );

              await _saveManifest(manifest);

              _addSmartLog(
                  '📋 بارنامه شماره ${manifest.number} با ${manifest.items.length} کالا ثبت شد');

              setState(() {
                _currentItems.clear();
                _filteredItems.clear();
                _searchController.clear();
                _isSearching = false;
              });

              Navigator.pop(context);
              _showSuccessMessage('بارنامه ثبت شد ✅');
            },
            child: const Text('ثبت نهایی'),
          ),
        ],
      ),
    );
  }

  String _getTodayDate() => _todayJalali();

  Future<void> _saveManifest(DeliveryManifest manifest) async {
    final prefs = await SharedPreferences.getInstance();
    final manifestsJson = _savedManifests.map((m) => m.toJson()).toList();
    manifestsJson.add(manifest.toJson());
    await prefs.setString('delivery_manifests', jsonEncode(manifestsJson));

    setState(() {
      _savedManifests.add(manifest);
    });
    // رویداد شبکه در صف محلی قرار می‌گیرد و در صورت فعال بودن شبکه ارسال می‌شود.
    try {
      final network = NetworkService();
      await network.queueEvent(
        type: 'manifest_created',
        actorName: _userName,
        payload: {
          'manifestNumber': manifest.number,
          'date': manifest.date,
          'senderCompany': manifest.senderCompany,
          'freightCost': manifest.freightCost,
          'itemsCount': manifest.items.length,
        },
      );
      await network.syncOutbox();
    } catch (_) {}
  }

  Future<void> _loadSavedManifests() async {
    setState(() {
      _isLoading = true;
    });

    final prefs = await SharedPreferences.getInstance();
    final manifestsJson = prefs.getString('delivery_manifests');

    if (manifestsJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(manifestsJson);
        setState(() {
          _savedManifests =
              decoded.map((item) => DeliveryManifest.fromJson(item)).toList();
          _isLoading = false;
        });
      } catch (e) {
        setState(() {
          _isLoading = false;
        });
      }
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _startEditingManifest(DeliveryManifest manifest) {
    _closeKeyboard();
    final dateController = TextEditingController(text: manifest.date);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          'ویرایش بارنامه شماره ${manifest.number}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: StatefulBuilder(
          builder: (context, setStateDialog) {
            return SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: dateController,
                    decoration: InputDecoration(
                      labelText: 'تاریخ بارنامه',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      prefixIcon: const Icon(Icons.edit_calendar),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'لیست کالاها:',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle, color: Colors.green),
                        onPressed: () {
                          Navigator.pop(context);
                          _showAddDialog(targetManifest: manifest);
                        },
                        tooltip: 'افزودن کالا',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: manifest.items.length,
                      itemBuilder: (context, index) {
                        final item = manifest.items[index];
                        return ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: Colors.blue.shade100,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                          title: Text(
                            item.name,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            'تعداد: ${item.quantity} | ${_displayPrice(item.purchasePrice)}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle_outline,
                                color: Colors.red, size: 20),
                            onPressed: () async {
                              final removedItem = manifest.items[index];
                              await _addToTrash(
                                type: 'manifest_item',
                                title:
                                    'قلم ${removedItem.name} از بارنامه ${manifest.number}',
                                data: {
                                  'manifestId': manifest.id,
                                  'item': removedItem.toJson(),
                                },
                              );
                              setState(() {
                                manifest.items.removeAt(index);
                                manifest.totalPrice -=
                                    removedItem.purchasePrice *
                                        removedItem.realQuantity;
                              });
                              setStateDialog(() {});
                              _addSmartLog(
                                  '❌ کالا "${item.name}" از بارنامه شماره ${manifest.number} حذف شد');
                              _saveManifestChanges(manifest);
                              _showSuccessMessage('کالا حذف شد ❌');
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              _closeKeyboard();
              Navigator.pop(context);
            },
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              final oldDate = manifest.date;
              final newDate = dateController.text;

              setState(() {
                manifest.date = newDate;
              });

              await _saveManifestChanges(manifest);

              if (oldDate != newDate) {
                _addSmartLog(
                    '📅 تاریخ بارنامه شماره ${manifest.number} از $oldDate به $newDate تغییر یافت');
              }

              Navigator.pop(context);
              _showSuccessMessage('تغییرات ذخیره شد ✅');
            },
            child: const Text('ذخیره تغییرات'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveManifestChanges(DeliveryManifest manifest) async {
    final prefs = await SharedPreferences.getInstance();
    final manifestsJson = _savedManifests.map((m) => m.toJson()).toList();
    await prefs.setString('delivery_manifests', jsonEncode(manifestsJson));
  }

  Future<void> _deleteManifest(DeliveryManifest manifest) async {
    _closeKeyboard();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text('حذف بارنامه شماره ${manifest.number}'),
        content: Text('آیا از حذف بارنامه تاریخ ${manifest.date} مطمئن هستید؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              await _addToTrash(
                type: 'manifest',
                title: 'بارنامه شماره ${manifest.number}',
                data: manifest.toJson(),
              );
              setState(() {
                _savedManifests.remove(manifest);
              });

              final prefs = await SharedPreferences.getInstance();
              final manifestsJson =
                  _savedManifests.map((m) => m.toJson()).toList();
              await prefs.setString(
                  'delivery_manifests', jsonEncode(manifestsJson));

              _addSmartLog('🗑️ بارنامه شماره ${manifest.number} حذف شد');

              Navigator.pop(context);

              if (_isViewingManifest && _viewingManifest?.id == manifest.id) {
                setState(() {
                  _isViewingManifest = false;
                  _viewingManifest = null;
                });
              }

              _showSuccessMessage('بارنامه حذف شد 🗑️');
            },
            child: const Text('حذف'),
          ),
        ],
      ),
    );
  }

  void _viewManifest(DeliveryManifest manifest) {
    setState(() {
      _viewingManifest = manifest;
      _isViewingManifest = true;
    });
  }

  void _goBackToMain() {
    setState(() {
      _isViewingManifest = false;
      _viewingManifest = null;
    });
  }

  void _cancelDelivery() {
    _closeKeyboard();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text('لغو عملیات'),
        content: const Text(
            'آیا از لغو این محموله مطمئن هستید؟\nهمه کالاها حذف خواهند شد.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              setState(() {
                _currentItems.clear();
                _filteredItems.clear();
                _searchController.clear();
                _isSearching = false;
              });
              _addSmartLog('❌ محموله لغو شد');
              Navigator.pop(context);
              _showSuccessMessage('محموله لغو شد ❌');
            },
            child: const Text('بله، لغو شود'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddDialog({DeliveryManifest? targetManifest}) async {
    _clearControllers();
    _closeKeyboard();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          targetManifest != null
              ? 'افزودن کالا به بارنامه شماره ${targetManifest.number}'
              : 'اضافه کردن کالا',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        content: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _barcodeController,
                        decoration: InputDecoration(
                          labelText: 'شماره بارکد',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          hintText: 'اسکن یا دستی وارد کنید',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.camera_alt,
                          color: Colors.blue, size: 30),
                      onPressed: () => _scanBarcode(forSearchOnly: false),
                      tooltip: 'اسکن بارکد با دوربین',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: 'نام کالا',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'لطفاً نام کالا را وارد کنید';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('واحد سنجش:'),
                    const SizedBox(width: 16),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selectedUnit,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'جلد', child: Text('جلد')),
                          DropdownMenuItem(value: 'عدد', child: Text('عدد')),
                          DropdownMenuItem(value: 'جین', child: Text('جین')),
                          DropdownMenuItem(value: 'بسته', child: Text('بسته')),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _selectedUnit = value!;
                            _isPackageUnit =
                                (value == 'بسته' || value == 'جین');
                            if (!_isPackageUnit) {
                              _packageSizeController.clear();
                            }
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _quantityController,
                  decoration: InputDecoration(
                    labelText:
                        'تعداد (${(_selectedUnit == 'بسته' || _selectedUnit == 'جین') ? 'بسته' : _selectedUnit})',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    hintText:
                        (_selectedUnit == 'بسته' || _selectedUnit == 'جین')
                            ? 'تعداد ${_selectedUnit}'
                            : 'تعداد را وارد کنید',
                  ),
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'لطفاً تعداد را وارد کنید';
                    }
                    if (int.tryParse(value) == null) {
                      return 'لطفاً یک عدد معتبر وارد کنید';
                    }
                    return null;
                  },
                ),
                if (_isPackageUnit) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _packageSizeController,
                    decoration: InputDecoration(
                      labelText: 'تعداد داخل هر ${_selectedUnit} (اختیاری)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      hintText:
                          'مثلاً 10 - اختیاری است؛ در صورت خالی بودن فقط تعداد ${_selectedUnit} ثبت می‌شود',
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      if (_isPackageUnit &&
                          (value == null || value.trim().isEmpty)) {
                        return 'برای واحد بسته/جین، تعداد داخل هر بسته را وارد کنید';
                      }
                      if (value != null &&
                          value.trim().isNotEmpty &&
                          int.tryParse(value) == null) {
                        return 'تعداد معتبر وارد کنید';
                      }
                      return null;
                    },
                  ),
                ],
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'قیمت خرید در بارنامه ثبت نمی‌شود و در بخش «خرید» ثبت خواهد شد.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              if (_formKey.currentState!.validate()) {
                final newItem = DeliveryItem(
                  name: _nameController.text,
                  quantity: int.parse(_quantityController.text),
                  realQuantity:
                      (_packageSizeController.text.isNotEmpty && _isPackageUnit)
                          ? int.parse(_quantityController.text) *
                              int.parse(_packageSizeController.text)
                          : int.parse(_quantityController.text),
                  purchasePrice: 0,
                  barcode: _barcodeController.text.trim(),
                  date: DateTime.now().millisecondsSinceEpoch.toString(),
                  unit: _selectedUnit,
                  packageSize: _packageSizeController.text.isNotEmpty
                      ? int.parse(_packageSizeController.text)
                      : 0,
                );

                if (targetManifest != null) {
                  setState(() {
                    targetManifest.items.add(newItem);
                    targetManifest.totalPrice = 0;
                  });
                  _addSmartLog(
                      '➕ کالا "${newItem.name}" به بارنامه شماره ${targetManifest.number} اضافه شد');
                  _saveManifestChanges(targetManifest);
                  Navigator.pop(context);
                  _showSuccessMessage('کالا اضافه شد ✅');
                } else {
                  setState(() {
                    _currentItems.add(newItem);
                    if (_searchController.text.isNotEmpty) {
                      _searchItems(_searchController.text);
                    }
                  });
                  _addSmartLog(
                      '✅ کالا "${_nameController.text}" با تعداد ${newItem.quantity} اضافه شد');
                  _clearControllers();
                  Navigator.pop(context);
                  _showSuccessMessage('کالا اضافه شد ✅');
                }
              }
            },
            child: const Text('افزودن'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    final searchDbMatches = _productDatabase.where((p) {
      final term = _normalizeSearchText(_searchController.text);
      return _normalizeSearchText(p.name).contains(term) ||
          p.barcode.contains(term);
    }).toList();

    final totalResults = _filteredItems.length +
        _manifestSearchResults.length +
        searchDbMatches.length;

    if (totalResults == 0) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.search_off, size: 60, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(
                '🔍 هیچ کالایی با این نام یا بارکد پیدا نشد',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '🔍 نتایج جستجو ($totalResults مورد):',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: Colors.blue,
              ),
            ),
          ),
          if (searchDbMatches.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '🗄️ از بانک اطلاعاتی کالاها:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ...searchDbMatches.map((dbItem) => Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.purple.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('📦 نام کالا: ${dbItem.name}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      Text('📊 موجودی: ${dbItem.stock}',
                          style: const TextStyle(fontSize: 13)),
                      Text('🏷️ قیمت فروش: ${_displayPrice(dbItem.sellPrice)}',
                          style: const TextStyle(
                              fontSize: 13,
                              color: Colors.green,
                              fontWeight: FontWeight.bold)),
                      if (dbItem.barcode.isNotEmpty)
                        Text('بارکد: ${dbItem.barcode}',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade600)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 8, horizontal: 12),
                              ),
                              icon: const Icon(Icons.shopping_cart, size: 16),
                              label: const Text('فروش'),
                              onPressed: () {
                                _openSalesInvoicesScreen();
                                _showSalesDialog(
                                  productName: dbItem.name,
                                  productBarcode: dbItem.barcode,
                                  sellPrice: dbItem.sellPrice,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )),
          ],
          if (_filteredItems.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '📦 کالاهای محموله جاری:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ..._filteredItems.map((item) => _buildSearchResultItem(item, null)),
          ],
          if (_manifestSearchResults.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '📋 بارنامه‌های ذخیره شده:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ..._manifestSearchResults.map((result) =>
                _buildManifestSearchResult(result['manifest'], result['item'])),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchResultItem(DeliveryItem item, DeliveryManifest? manifest) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: Colors.blue.shade700, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'تعداد: ${item.quantity}',
            style: const TextStyle(fontSize: 13),
          ),
          Text(
            'قیمت: ${_displayPrice(item.purchasePrice)}',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            ),
            icon: const Icon(Icons.shopping_cart, size: 16),
            label: const Text('فروش'),
            onPressed: () {
              _openSalesInvoicesScreen();
              _showSalesDialog(
                productName: item.name,
                productBarcode: item.barcode,
                sellPrice: item.purchasePrice * 2,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildManifestSearchResult(
      DeliveryManifest manifest, DeliveryItem item) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description, color: Colors.green.shade700, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'بارنامه شماره ${manifest.number}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '📌 ${item.name} | تعداد: ${item.quantity}',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            ),
            icon: const Icon(Icons.shopping_cart, size: 16),
            label: const Text('فروش'),
            onPressed: () {
              _openSalesInvoicesScreen();
              _showSalesDialog(
                productName: item.name,
                productBarcode: item.barcode,
                sellPrice: item.purchasePrice * 2,
              );
            },
          ),
        ],
      ),
    );
  }

  // ==================== صفحه اصلی با هدر جدید ====================

  Widget _buildMainView() {
    final now = DateTime.now();

    return GestureDetector(
      // ==================== با کلیک روی هر جای صفحه، کیبورد بسته شود ====================
      onTap: _closeKeyboard,
      child: RefreshIndicator(
        onRefresh: () async {
          await _loadSavedManifests();
          await _loadProductDatabase();
          await _loadSalesInvoices();
          await _loadSmartLogs();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white,
                    Colors.green.shade50,
                    Colors.green.shade700,
                  ],
                  stops: const [0.0, 0.30, 1.0],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.green.shade300.withOpacity(.3),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 65,
                        height: 65,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.5),
                            width: 2,
                          ),
                          image: const DecorationImage(
                            image: AssetImage(
                                'assets/images/Logopit_1787568628075.png'),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_greetingByHour(now.hour)} ${_userGender == 'female' ? 'خانم' : 'آقای'} ${_userName.isEmpty ? 'کاربر عزیز' : _userName}',
                              style: TextStyle(
                                color: Colors.green.shade900,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'امروز ${_todayJalaliLong()} است',
                              style: TextStyle(
                                color: Colors.green.shade900,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // آمار لحظه‌ای داخل همان کادر سبز
                  _buildLiveStats(),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // ==================== جستجو با FocusNode ====================
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    decoration: InputDecoration(
                      labelText: 'جستجو در کالاها و بارنامه‌ها',
                      hintText: 'نام کالا یا بارکد...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                _closeKeyboard();
                                setState(() {
                                  _isSearching = false;
                                  _filteredItems.clear();
                                  _manifestSearchResults.clear();
                                });
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) {
                      _searchItems(value);
                    },
                    onSubmitted: (value) {
                      // وقتی کاربر Enter زد، کیبورد بسته شود
                      _closeKeyboard();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: IconButton(
                    icon:
                        const Icon(Icons.qr_code_scanner, color: Colors.white),
                    iconSize: 29,
                    padding: const EdgeInsets.all(13),
                    onPressed: () => _scanBarcode(forSearchOnly: true),
                    tooltip: 'جستجو با اسکن بارکد',
                  ),
                ),
              ],
            ),

            if (_isSearching) ...[
              const SizedBox(height: 12),
              _buildSearchResults(),
            ] else ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'گزارش هوشمند',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_smartLogs.isNotEmpty)
                    TextButton(
                      onPressed: _clearSmartLogs,
                      child: const Text('پاک کردن'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                // فقط سه ردیف در فضای اولیه دیده می‌شود؛ بقیه گزارش‌ها با اسکرول قابل مشاهده‌اند.
                height: 118,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: _smartLogs.isEmpty
                    ? const Row(
                        children: [
                          Icon(Icons.insights_outlined, color: Colors.grey),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'هنوز گزارشی ثبت نشده؛ فعالیت‌های برنامه اینجا نمایش داده می‌شوند.',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ],
                      )
                    : Scrollbar(
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: _smartLogs.length,
                          itemBuilder: (context, index) {
                            final log = _smartLogs[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.circle, size: 7),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      log,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
              ),
              const SizedBox(height: 22),
              const Text(
                'ابزارها',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cardWidth = (constraints.maxWidth - 10) / 2;
                  final cardHeight = cardWidth / 1.65;
                  final toolsHeight = (cardHeight * 2) + 10;
                  final allTools = <Widget>[
                    _buildToolCard(
                      icon: Icons.local_shipping_outlined,
                      title: 'بارنامه',
                      subtitle: 'ثبت و مدیریت بار',
                      iconColor: Colors.blue,
                      onTap: _openManifestScreen,
                    ),
                    _buildToolCard(
                      icon: Icons.receipt_long_outlined,
                      title: 'فروش',
                      subtitle: 'فاکتورهای فروش',
                      iconColor: Colors.green,
                      onTap: _openSalesInvoicesScreen,
                    ),
                    _buildToolCard(
                      icon: Icons.payments_outlined,
                      title: 'هزینه های روزانه',
                      subtitle: 'ثبت و مدیریت هزینه ها',
                      iconColor: Colors.redAccent,
                      onTap: _openDailyExpensesScreen,
                    ),
                    _buildToolCard(
                      icon: Icons.inventory_2_outlined,
                      title: 'بانک اطلاعاتی',
                      subtitle: 'کالاها و پوشه‌ها',
                      iconColor: Colors.deepPurple,
                      onTap: _openProductDatabaseScreen,
                    ),
                    _buildToolCard(
                      icon: Icons.share_outlined,
                      title: 'اشتراک گزارش',
                      subtitle: 'گزارش فروش و بارنامه',
                      iconColor: Colors.orange,
                      onTap: _openShareReportChooser,
                    ),
                    _buildToolCard(
                      icon: Icons.settings_outlined,
                      title: 'تنظیمات',
                      subtitle: 'پروفایل و ظاهر',
                      iconColor: Colors.grey,
                      onTap: _openSettingsScreen,
                    ),
                    _buildToolCard(
                      icon: Icons.cloud_sync_outlined,
                      title: 'ارتباط با شبکه',
                      subtitle: 'همگام‌سازی و بانک مرکزی',
                      iconColor: Colors.indigo,
                      onTap: _openNetworkConnectionScreen,
                    ),
                    _buildToolCard(
                      icon: Icons.fact_check_outlined,
                      title: 'انبارگردانی',
                      subtitle: 'مغایرت موجودی کالاها',
                      iconColor: Colors.teal,
                      onTap: _openInventoryCountScreen,
                    ),
                    _buildToolCard(
                      icon: Icons.trending_up_outlined,
                      title: 'محاسبه سود فروش',
                      subtitle: 'محاسبه سود و درصد افزایش قیمت',
                      iconColor: Colors.green,
                      onTap: _openSalesProfitScreen,
                    ),
                  ];
                  final pageCount = (allTools.length / 4).ceil();
                  return SizedBox(
                    height: toolsHeight,
                    child: PageView.builder(
                      controller: _toolsPageController,
                      itemCount: pageCount,
                      onPageChanged: (index) =>
                          setState(() => _toolsPage = index),
                      itemBuilder: (context, pageIndex) {
                        final pageTools =
                            allTools.skip(pageIndex * 4).take(4).toList();
                        while (pageTools.length < 4) {
                          pageTools.add(const SizedBox.shrink());
                        }
                        return GridView.count(
                          crossAxisCount: 2,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 1.65,
                          children: pageTools,
                        );
                      },
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _toolPageCount,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: _toolsPage == index ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: _toolsPage == index
                          ? Colors.green.shade700
                          : Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              if (_currentItems.isNotEmpty) ...[
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'محموله جاری',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _submitDelivery,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('ثبت نهایی'),
                    ),
                  ],
                ),
                ...List.generate(
                  _currentItems.length,
                  (index) => _buildItemCard(index),
                ),
              ],
              const SizedBox(height: 10),
              Center(
                child: Text(
                  'توسعه‌دهنده: رضا قاسمی',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor, size: 28),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemCard(int index) {
    final item = _currentItems[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue.shade100,
          child: Text(
            '${(index + 1)}',
            style: TextStyle(color: Colors.blue.shade700),
          ),
        ),
        title: Text(
          item.name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.barcode.isNotEmpty)
              Text('بارکد: ${item.barcode}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            Text('واحد: ${item.unit}', style: const TextStyle(fontSize: 13)),
            Text('تعداد: ${item.quantity} ${item.unit}'),
            if (item.packageSize > 0)
              Text(
                  'تعداد داخل ${item.unit}: ${item.packageSize}  •  تعداد واقعی: ${item.realQuantity}'),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.white),
          onPressed: () => _removeItem(index),
        ),
      ),
    );
  }

  Widget _buildManifestView() {
    final manifest = _viewingManifest!;
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blue.shade50, Colors.blue.shade100],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('شماره بارنامه:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${manifest.number}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 18)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('تاریخ:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(manifest.date),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('تعداد کالاها:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${manifest.items.length}'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('اقلام بارنامه:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${manifest.items.length} کالا'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: manifest.items.length,
            itemBuilder: (context, index) {
              final item = manifest.items[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blue.shade100,
                    child: Text('${index + 1}',
                        style: TextStyle(color: Colors.blue.shade700)),
                  ),
                  title: Text(item.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'تعداد: ${item.quantity}${item.packageSize > 0 ? ' (مجموع: ${item.realQuantity})' : ''}'),
                      Text('واحد: ${item.unit}'),
                      if (item.packageSize > 0)
                        Text('تعداد داخل ${item.unit}: ${item.packageSize}'),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.shopping_cart, color: Colors.green),
                    onPressed: () {
                      _openSalesInvoicesScreen();
                      _showSalesDialog(
                        productName: item.name,
                        productBarcode: item.barcode,
                        sellPrice: item.purchasePrice * 2,
                      );
                    },
                    tooltip: 'فروش',
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isViewingManifest && _currentItems.isEmpty,
      onPopInvoked: (didPop) {
        if (!didPop) {
          if (_isViewingManifest) {
            _goBackToMain();
          } else if (_currentItems.isNotEmpty) {
            _cancelDelivery();
          }
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          centerTitle: true,
          title: _isViewingManifest
              ? Text(
                  'بارنامه شماره ${_viewingManifest!.number}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.white,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const StoreBrandMark(size: 34),
                    const SizedBox(width: 9),
                    const Flexible(
                      child: Text(
                        'دستیار هوشمند فروشگاه',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Colors.white),
                      ),
                    ),
                  ],
                ),
          actions: [
            if (!_isViewingManifest)
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'تنظیمات',
                onPressed: _openSettingsScreen,
              ),
            if (!_isViewingManifest)
              IconButton(
                icon: const Icon(Icons.person_outline),
                tooltip: 'پروفایل کاربر',
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                },
              ),
            if (_isViewingManifest) ...[
              IconButton(
                icon: const Icon(Icons.edit_outlined, color: Colors.white),
                onPressed: () => _startEditingManifest(_viewingManifest!),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white),
                onPressed: () => _deleteManifest(_viewingManifest!),
              ),
            ],
          ],
          leading: _isViewingManifest
              ? IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: _goBackToMain,
                )
              : TweenAnimationBuilder<double>(
                  tween:
                      Tween(begin: 0.0, end: _hasNewManagerMessage ? 1.0 : 0.0),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOut,
                  builder: (context, value, child) => Transform.translate(
                    offset: Offset(
                      _hasNewManagerMessage
                          ? (value * 5 * ((value * 10).floor().isEven ? 1 : -1))
                          : 0,
                      0,
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          color: Colors.white,
                          icon: Icon(
                            _hasNewManagerMessage
                                ? Icons.mark_email_unread_outlined
                                : Icons.mail_outline,
                            color: Colors.white,
                          ),
                          tooltip: 'پیام مدیر',
                          onPressed: _openManagerMessage,
                        ),
                        if (_hasNewManagerMessage)
                          const Positioned(
                            right: 7,
                            top: 7,
                            child: CircleAvatar(
                              radius: 5,
                              backgroundColor: Colors.red,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
        endDrawer: Drawer(
          width: MediaQuery.of(context).size.width * .82,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // بستن Drawer با کشیدن از چپ به راست؛ آستانه کوچک‌تر
            // باعث می‌شود روی گوشی‌های مختلف هم طبیعی و قابل‌اعتماد باشد.
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity > 150 && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            child: SafeArea(
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF12462D),
                          const Color(0xFF246C49),
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        const StoreBrandMark(size: 58),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_userGender == 'female' ? 'خانم' : 'آقای'} ${_userName.isEmpty ? 'کاربر عزیز' : _userName}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              const Text('تنظیمات برنامه',
                                  style: TextStyle(color: Colors.white70)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('تنظیمات'),
                    subtitle: const Text('ظاهر، پروفایل و اطلاعات برنامه'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: _openSettingsPageFromDrawer,
                  ),
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('پروفایل کاربر'),
                    subtitle: const Text('تغییر نام کاربر'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () {
                      Navigator.pop(context);
                      Future.delayed(const Duration(milliseconds: 220), () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const LoginScreen()),
                        );
                      });
                    },
                  ),
                  // طبق درخواست: سطل زباله بلافاصله بعد از «تغییر نام کاربر»
                  // و ارتباط با پشتیبانی بلافاصله زیر آن قرار می‌گیرد.
                  ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('سطل زباله'),
                    subtitle: const Text('بازیابی یا حذف دائمی موارد'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () {
                      Navigator.pop(context);
                      Future.delayed(const Duration(milliseconds: 220), () {
                        if (mounted) _openTrashScreen();
                      });
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.support_agent_outlined),
                    title: const Text('ارتباط با پشتیبانی'),
                    subtitle: const Text('ارسال پیام از طریق Gmail'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () {
                      Navigator.pop(context);
                      Future.delayed(const Duration(milliseconds: 220), () {
                        if (mounted) _contactSupport();
                      });
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.share_outlined),
                    title: const Text('اشتراک‌گذاری گزارش'),
                    subtitle: const Text('ارسال گزارش PDF فروش'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () {
                      Navigator.pop(context);
                      Future.delayed(const Duration(milliseconds: 220), () {
                        if (mounted) _shareSalesReport();
                      });
                    },
                  ),
                  const Divider(),
                  const Spacer(),
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('توسعه‌دهنده: رضا قاسمی',
                        style: TextStyle(color: Colors.grey)),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _isViewingManifest
                ? _buildManifestView()
                : _buildMainView(),
      ),
    );
  }
}

// ==================== ادامه کد (ManifestScreen, SalesInvoicesScreen, SettingsScreen, ProductDatabaseScreen, BarcodeScannerScreen و مدل‌ها) در پاسخ بعدی ====================
// ==================== صفحه اختصاصی بارنامه‌ها ====================

class ManagerMessagesScreen extends StatefulWidget {
  final List<AppMessage> messages;
  final Future<void> Function(List<AppMessage>) onMessagesChanged;

  const ManagerMessagesScreen({
    super.key,
    required this.messages,
    required this.onMessagesChanged,
  });

  @override
  State<ManagerMessagesScreen> createState() => _ManagerMessagesScreenState();
}

class _ManagerMessagesScreenState extends State<ManagerMessagesScreen> {
  late List<AppMessage> _messages;

  @override
  void initState() {
    super.initState();
    _messages = List<AppMessage>.from(widget.messages);
  }

  Future<void> _deleteMessage(int index) async {
    final deletedId = _messages[index].id;
    setState(() => _messages.removeAt(index));
    final prefs = await SharedPreferences.getInstance();
    final deleted =
        prefs.getStringList('deleted_app_message_ids') ?? <String>[];
    if (!deleted.contains(deletedId)) deleted.add(deletedId);
    await prefs.setStringList('deleted_app_message_ids', deleted);
    await widget.onMessagesChanged(_messages);
  }

  Future<void> _deleteAll() async {
    if (_messages.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف همه پیام‌ها'),
        content: const Text('همه پیام‌های دریافتی حذف شوند؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('انصراف')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف همه')),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    final deleted =
        prefs.getStringList('deleted_app_message_ids') ?? <String>[];
    for (final message in _messages) {
      if (!deleted.contains(message.id)) deleted.add(message.id);
    }
    await prefs.setStringList('deleted_app_message_ids', deleted);
    setState(() => _messages.clear());
    await widget.onMessagesChanged(_messages);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('پیام‌ها'),
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
                onPressed: _deleteAll,
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'حذف همه'),
        ],
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: _messages.isEmpty
            ? const Center(child: Text('پیامی وجود ندارد'))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.amber.shade100,
                        child: Icon(Icons.notifications_active_outlined,
                            color: Colors.amber.shade800),
                      ),
                      title: Text(message.title,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text(message.body,
                            style: const TextStyle(height: 1.7)),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'حذف پیام',
                        onPressed: () => _deleteMessage(index),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class ManifestDetailsScreen extends StatelessWidget {
  final DeliveryManifest manifest;

  const ManifestDetailsScreen({super.key, required this.manifest});

  String _price(int value) => _formatPrice(value);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('جزئیات بارنامه شماره ${manifest.number}'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
          children: [
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('بارنامه شماره ${manifest.number}',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    _infoRow('📅 تاریخ', manifest.date),
                    _infoRow(
                        '🚚 شرکت ارسال کننده',
                        manifest.senderCompany.isEmpty
                            ? 'ثبت نشده'
                            : manifest.senderCompany),
                    _infoRow(
                        '💵 هزینه باربری',
                        manifest.freightCost > 0
                            ? '${_price(manifest.freightCost)} ریال'
                            : 'اختیاری / ثبت نشده'),
                    _infoRow('📦 تعداد اقلام', '${manifest.items.length}'),
                    _infoRow('💰 مجموع ارزش کالاها',
                        '${_price(manifest.totalPrice)} ریال'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text('جزئیات کالاهای بارنامه',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...manifest.items.asMap().entries.map((entry) {
              final index = entry.key + 1;
              final item = entry.value;
              final isPackage = item.unit == 'بسته' || item.unit == 'جین';
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(radius: 16, child: Text('$index')),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text(item.name,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold))),
                        ],
                      ),
                      const Divider(height: 20),
                      _infoRow('🔢 بارکد',
                          item.barcode.isEmpty ? 'ثبت نشده' : item.barcode),
                      _infoRow('📏 واحد سنجش', item.unit),
                      if (isPackage) ...[
                        _infoRow(
                            '📦 تعداد بسته', '${item.quantity} ${item.unit}'),
                        _infoRow('🔢 تعداد داخل هر بسته',
                            '${item.packageSize > 0 ? item.packageSize : 1} عدد'),
                        _infoRow(
                            '📊 تعداد عددی کل', '${item.realQuantity} عدد'),
                      ] else ...[
                        _infoRow('🔢 تعداد', '${item.quantity} ${item.unit}'),
                        _infoRow('📊 تعداد عددی', '${item.realQuantity}'),
                      ],
                      _infoRow('💰 قیمت خرید واحد',
                          '${_price(item.purchasePrice)} ریال'),
                      _infoRow('💵 ارزش این قلم',
                          '${_price(item.purchasePrice * item.realQuantity)} ریال'),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 155,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class ManifestScreen extends StatefulWidget {
  final List<DeliveryManifest> manifests;
  final Function(DeliveryManifest) onDelete;
  final Function(DeliveryManifest) onEdit;
  final Function(DeliveryManifest) onViewDetails;
  final Function(DeliveryManifest) onShareReport;
  final Function(DeliveryManifest) onManifestSaved;

  const ManifestScreen({
    super.key,
    required this.manifests,
    required this.onDelete,
    required this.onEdit,
    required this.onViewDetails,
    required this.onShareReport,
    required this.onManifestSaved,
  });

  @override
  State<ManifestScreen> createState() => _ManifestScreenState();
}

class _ManifestScreenState extends State<ManifestScreen> {
  String _searchQuery = '';

  List<DeliveryManifest> get _filteredManifests {
    if (_searchQuery.isEmpty) return widget.manifests.reversed.toList();
    final query = _normalizeSearchText(_searchQuery);
    return widget.manifests.where((m) {
      if (m.number.toString().contains(query)) return true;
      if (m.date.contains(query)) return true;
      for (final item in m.items) {
        if (_normalizeSearchText(item.name).contains(query)) return true;
        if (item.barcode.contains(query)) return true;
      }
      return false;
    }).toList();
  }

  void _closeKeyboard() {
    FocusScope.of(context).unfocus();
  }

  Future<void> _showAddManifestDialog() async {
    _closeKeyboard();
    final barcodeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final quantityCtrl = TextEditingController();
    final packageSizeCtrl = TextEditingController();
    final freightCostCtrl = TextEditingController();
    final senderCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    String selectedUnit = 'عدد';
    bool isPackageUnit = false;
    List<Map<String, dynamic>> tempItems = [];

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return SafeArea(
              child: DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.85,
                minChildSize: 0.6,
                maxChildSize: 0.95,
                snap: true,
                snapSizes: const [0.6, 0.85, 0.95],
                builder: (context, scrollController) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Form(
                      key: formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.local_shipping,
                                  color: Colors.blue),
                              const SizedBox(width: 8),
                              const Text(
                                'بارنامه جدید',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: () {
                                  barcodeCtrl.clear();
                                  nameCtrl.clear();
                                  quantityCtrl.clear();
                                  packageSizeCtrl.clear();
                                  freightCostCtrl.clear();
                                  senderCtrl.clear();
                                  setSheetState(() {
                                    selectedUnit = 'عدد';
                                    isPackageUnit = false;
                                  });
                                },
                                icon: const Icon(Icons.clear, size: 18),
                                label: const Text('پاک کردن'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: TextFormField(
                                  controller: barcodeCtrl,
                                  decoration: InputDecoration(
                                    labelText: 'شماره بارکد (اختیاری)',
                                    hintText: 'بارکد را اسکن یا وارد کنید',
                                    prefixIcon: const Icon(Icons.qr_code),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.camera_alt,
                                      color: Colors.white),
                                  onPressed: () async {
                                    _closeKeyboard();
                                    final result = await Navigator.push<String>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const BarcodeScannerScreen(),
                                      ),
                                    );
                                    if (result != null && result.isNotEmpty) {
                                      barcodeCtrl.text = result;
                                      setSheetState(() {});
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: nameCtrl,
                            decoration: InputDecoration(
                              labelText: 'نام کالا *',
                              hintText: 'نام کالا را وارد کنید',
                              prefixIcon: const Icon(Icons.inventory_2),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'وارد کردن نام کالا الزامی است';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: DropdownButtonFormField<String>(
                                  value: selectedUnit,
                                  decoration: InputDecoration(
                                    labelText: 'واحد سنجش',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'عدد', child: Text('عدد')),
                                    DropdownMenuItem(
                                        value: 'جلد', child: Text('جلد')),
                                    DropdownMenuItem(
                                        value: 'جین', child: Text('جین')),
                                    DropdownMenuItem(
                                        value: 'بسته', child: Text('بسته')),
                                  ],
                                  onChanged: (value) {
                                    setSheetState(() {
                                      selectedUnit = value!;
                                      isPackageUnit =
                                          (value == 'بسته' || value == 'جین');
                                      if (!isPackageUnit) {
                                        packageSizeCtrl.clear();
                                      }
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  controller: quantityCtrl,
                                  decoration: InputDecoration(
                                    labelText: 'تعداد',
                                    hintText: 'تعداد را وارد کنید',
                                    prefixIcon: const Icon(Icons.numbers),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  keyboardType: TextInputType.number,
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return 'تعداد را وارد کنید';
                                    }
                                    if (int.tryParse(value) == null ||
                                        int.parse(value) <= 0) {
                                      return 'تعداد معتبر وارد کنید';
                                    }
                                    return null;
                                  },
                                ),
                              ),
                            ],
                          ),
                          if (isPackageUnit) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: packageSizeCtrl,
                              decoration: InputDecoration(
                                labelText:
                                    'تعداد داخل هر ${selectedUnit} (اختیاری)',
                                hintText:
                                    'مثلاً 10 - در صورت خالی بودن فقط تعداد ${selectedUnit} ثبت می‌شود',
                                prefixIcon: const Icon(Icons.inventory_2),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                if (isPackageUnit &&
                                    (value == null || value.trim().isEmpty)) {
                                  return 'برای واحد بسته/جین، تعداد داخل هر بسته را وارد کنید';
                                }
                                if (value != null &&
                                    value.trim().isNotEmpty &&
                                    int.tryParse(value) == null) {
                                  return 'تعداد معتبر وارد کنید';
                                }
                                return null;
                              },
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: senderCtrl,
                            decoration: InputDecoration(
                              labelText: 'نام شرکت ارسال کننده',
                              prefixIcon:
                                  const Icon(Icons.local_shipping_outlined),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: freightCostCtrl,
                            decoration: InputDecoration(
                              labelText: 'هزینه باربری (ریال)',
                              prefixIcon: const Icon(Icons.payments_outlined),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            keyboardType: TextInputType.number,
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('افزودن کالا به لیست'),
                              onPressed: () {
                                if (!formKey.currentState!.validate()) return;

                                final barcode = barcodeCtrl.text.trim();
                                final name = nameCtrl.text.trim();
                                final quantity = int.parse(quantityCtrl.text);
                                final packageSize =
                                    packageSizeCtrl.text.isNotEmpty
                                        ? int.parse(packageSizeCtrl.text)
                                        : 0;

                                final realQuantity =
                                    isPackageUnit && packageSize > 0
                                        ? quantity * packageSize
                                        : quantity;

                                final newItem = {
                                  'name': name,
                                  'quantity': quantity,
                                  'realQuantity': realQuantity,
                                  'barcode': barcode,
                                  'unit': selectedUnit,
                                  'packageSize': packageSize,
                                };

                                setSheetState(() {
                                  tempItems.add(newItem);
                                });

                                barcodeCtrl.clear();
                                nameCtrl.clear();
                                quantityCtrl.clear();
                                packageSizeCtrl.clear();
                                freightCostCtrl.clear();
                                senderCtrl.clear();
                                setSheetState(() {
                                  selectedUnit = 'عدد';
                                  isPackageUnit = false;
                                });

                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('✅ کالا به لیست اضافه شد')),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (tempItems.isNotEmpty) ...[
                            const Text(
                              '📦 کالاهای بارنامه:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Expanded(
                              child: ListView.builder(
                                itemCount: tempItems.length,
                                itemBuilder: (context, index) {
                                  final item = tempItems[index];
                                  return Card(
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 3),
                                    child: ListTile(
                                      dense: true,
                                      leading: CircleAvatar(
                                        radius: 12,
                                        backgroundColor: Colors.blue.shade100,
                                        child: Text('${index + 1}',
                                            style:
                                                const TextStyle(fontSize: 10)),
                                      ),
                                      title: Text(
                                        item['name'],
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500),
                                      ),
                                      subtitle: Text(
                                        item['unit'] == 'بسته' ||
                                                item['unit'] == 'جین'
                                            ? 'تعداد بسته: ${item['quantity']} | داخل هر بسته: ${item['packageSize']} | مجموع: ${item['realQuantity']}'
                                            : 'تعداد: ${item['quantity']} ${item['unit']}',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            color: Colors.red, size: 18),
                                        onPressed: () {
                                          setSheetState(() {
                                            tempItems.removeAt(index);
                                          });
                                        },
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ] else ...[
                            const Expanded(
                              child: Center(
                                child: Text(
                                  'هنوز کالایی اضافه نشده است',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.check_circle),
                              label: const Text('ثبت بارنامه'),
                              onPressed: tempItems.isEmpty
                                  ? null
                                  : () {
                                      _closeKeyboard();
                                      final manifestNumber =
                                          widget.manifests.length + 1;

                                      final items = tempItems.map((item) {
                                        return DeliveryItem(
                                          name: item['name'],
                                          quantity: item['quantity'],
                                          realQuantity: item['realQuantity'],
                                          purchasePrice: 0,
                                          barcode: item['barcode'],
                                          date: DateTime.now()
                                              .millisecondsSinceEpoch
                                              .toString(),
                                          unit: item['unit'],
                                          packageSize: item['packageSize'],
                                        );
                                      }).toList();

                                      final manifest = DeliveryManifest(
                                        id: DateTime.now()
                                            .millisecondsSinceEpoch
                                            .toString(),
                                        number: manifestNumber,
                                        date: _getTodayDate(),
                                        items: items,
                                        totalPrice: 0,
                                        freightCost: int.tryParse(
                                                freightCostCtrl.text
                                                    .replaceAll(',', '')) ??
                                            0,
                                        senderCompany: senderCtrl.text.trim(),
                                        createdAt: DateTime.now()
                                            .millisecondsSinceEpoch
                                            .toString(),
                                      );

                                      widget.onManifestSaved(manifest);

                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                            content: Text(
                                                '✅ بارنامه شماره $manifestNumber ثبت شد')),
                                      );

                                      Navigator.pop(sheetContext);
                                      setState(() {});
                                    },
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  String _getTodayDate() {
    final now = DateTime.now();
    final j = _gregorianToJalali(now.year, now.month, now.day);
    return '${_toPersianDigits(j[0].toString())}/${_toPersianDigits(j[1].toString().padLeft(2, '0'))}/${_toPersianDigits(j[2].toString().padLeft(2, '0'))}';
  }

  @override
  Widget build(BuildContext context) {
    final manifests = _filteredManifests;

    return Scaffold(
      appBar: AppBar(
        title: const Text('📦 بارنامه‌ها'),
        centerTitle: true,
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: () {
              if (widget.manifests.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('هیچ بارنامه‌ای برای گزارش وجود ندارد')),
                );
                return;
              }
              _shareAllManifests();
            },
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _closeKeyboard,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: InputDecoration(
                  labelText: '🔍 جستجو در بارنامه‌ها',
                  hintText: 'شماره، تاریخ، نام کالا یا بارکد',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
                onSubmitted: (_) => _closeKeyboard(),
              ),
            ),
            Expanded(
              child: manifests.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.local_shipping_outlined,
                              size: 72, color: Colors.grey),
                          SizedBox(height: 12),
                          Text('هنوز بارنامه‌ای ثبت نشده',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.bold)),
                          SizedBox(height: 6),
                          Text('برای شروع، «بارنامه جدید» را بزنید.'),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
                      itemCount: manifests.length,
                      itemBuilder: (context, index) {
                        final m = manifests[index];
                        final totalItems = m.items.length;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          elevation: 2,
                          child: InkWell(
                            onTap: () {
                              _closeKeyboard();
                              widget.onViewDetails(m);
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        backgroundColor: Colors.blue.shade100,
                                        child: Text(
                                          '${m.number}',
                                          style: TextStyle(
                                            color: Colors.blue.shade700,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'بارنامه شماره ${m.number}',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                            ),
                                            Text(
                                              'تاریخ: ${m.date}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade100,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          '$totalItems کالا',
                                          style: TextStyle(
                                            color: Colors.green.shade700,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: m.items.take(3).map((item) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade200,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          item.name,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                  if (m.items.length > 3)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        'و ${m.items.length - 3} کالای دیگر...',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade500,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.share_outlined,
                                            size: 20, color: Colors.blue),
                                        onPressed: () {
                                          _closeKeyboard();
                                          widget.onShareReport(m);
                                        },
                                        tooltip: 'اشتراک‌گذاری گزارش جامع',
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit_outlined,
                                            size: 20, color: Colors.orange),
                                        onPressed: () {
                                          _closeKeyboard();
                                          widget.onEdit(m);
                                        },
                                        tooltip: 'ویرایش',
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            size: 20, color: Colors.red),
                                        onPressed: () {
                                          _closeKeyboard();
                                          widget.onDelete(m);
                                        },
                                        tooltip: 'حذف',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddManifestDialog,
        icon: const Icon(Icons.add),
        label: const Text('بارنامه جدید'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
      ),
    );
  }

  Future<void> _shareAllManifests() async {
    try {
      _closeKeyboard();
      final font = await _loadFont();
      final pdf = pw.Document();
      final totalManifests = widget.manifests.length;
      final totalItems =
          widget.manifests.fold<int>(0, (sum, m) => sum + m.items.length);
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 30, 28, 30),
          textDirection: pw.TextDirection.rtl,
          maxPages: 500,
          header: (context) => pw.Align(
              alignment: pw.Alignment.centerRight,
              child: _pdfTextWidget('گزارش جامع بارنامه‌ها', font,
                  fontSize: 9, color: PdfColors.grey600)),
          footer: (context) => pw.Align(
              alignment: pw.Alignment.center,
              child: _pdfTextWidget(
                  'صفحه ${context.pageNumber} از ${context.pagesCount}', font,
                  fontSize: 8, color: PdfColors.grey600)),
          build: (context) => [
            pw.Center(
                child: _pdfTextWidget('گزارش جامع بارنامه‌ها', font,
                    fontSize: 24,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue,
                    textAlign: pw.TextAlign.center)),
            pw.SizedBox(height: 16),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(8)),
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _pdfTextWidget('تعداد بارنامه‌ها: $totalManifests', font,
                        fontWeight: pw.FontWeight.bold),
                    pw.SizedBox(height: 5),
                    _pdfTextWidget('تعداد کل کالاها: $totalItems', font,
                        fontWeight: pw.FontWeight.bold),
                    pw.SizedBox(height: 5),
                    _pdfTextWidget(
                        'مجموع هزینه باربری: ${_formatPrice(widget.manifests.fold<int>(0, (s, m) => s + m.freightCost))} ریال',
                        font,
                        fontWeight: pw.FontWeight.bold),
                  ]),
            ),
            pw.SizedBox(height: 14),
            ...widget.manifests.map((m) => _pdfTextWidget(
                'بارنامه شماره ${m.number} | شرکت ارسال کننده: ${m.senderCompany.isEmpty ? 'ثبت نشده' : m.senderCompany} | هزینه باربری: ${_formatPrice(m.freightCost)} ریال',
                font,
                fontSize: 9,
                fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 18),
            _pdfTextWidget('جزئیات بارنامه‌ها', font,
                fontSize: 17, fontWeight: pw.FontWeight.bold),
            pw.SizedBox(height: 8),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey500),
              tableWidth: pw.TableWidth.max,
              columnWidths: const {
                0: pw.FlexColumnWidth(1.3),
                1: pw.FlexColumnWidth(1.8),
                2: pw.FlexColumnWidth(3.8),
                3: pw.FlexColumnWidth(1.5)
              },
              children: [
                pw.TableRow(
                    repeat: true,
                    decoration:
                        const pw.BoxDecoration(color: PdfColors.blue100),
                    children: [
                      _pdfCell('شماره بارنامه', font, bold: true),
                      _pdfCell('تاریخ', font, bold: true),
                      _pdfCell('نام کالا', font, bold: true),
                      _pdfCell('تعداد', font, bold: true),
                    ]),
                ...widget.manifests
                    .expand((m) => m.items.map((item) => pw.TableRow(children: [
                          _pdfCell('${m.number}', font),
                          _pdfCell(m.date, font),
                          _pdfCell(item.name, font, align: pw.TextAlign.right),
                          _pdfCell(
                              item.unit == 'بسته' || item.unit == 'جین'
                                  ? '${item.quantity} ${item.unit} / داخل: ${item.packageSize > 0 ? item.packageSize : 1} / مجموع: ${item.realQuantity}'
                                  : '${item.quantity} ${item.unit}',
                              font),
                        ]))),
              ],
            ),
            pw.SizedBox(height: 18),
            pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: _pdfTextWidget(
                    'تاریخ تهیه گزارش: ${_getTodayDate()}', font,
                    fontSize: 9, color: PdfColors.grey600)),
          ],
        ),
      );
      final bytes = await pdf.save();
      final tempFile =
          File('${Directory.systemTemp.path}/all_manifests_report.pdf');
      await tempFile.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(tempFile.path)],
          text: 'گزارش جامع بارنامه‌ها\nتعداد بارنامه‌ها: $totalManifests');
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('گزارش جامع بارنامه‌ها ارسال شد')));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('خطا در تهیه گزارش: $e')));
    }
  }
}

// ==================== ادامه کد (SalesInvoicesScreen, SettingsScreen, ProductDatabaseScreen, BarcodeScannerScreen و مدل‌ها) در پاسخ بعدی ====================
// ==================== صفحه فاکتورهای فروش ====================

class SalesInvoicesScreen extends StatefulWidget {
  final List<SalesInvoice> invoices;
  final Future<void> Function(List<SalesInvoice>) onInvoiceDeleted;
  final Function(List<SalesInvoice>) onInvoiceUpdated;
  final Future<void> Function(List<SalesInvoice>) onInvoiceEditRequested;
  final Future<void> Function() onNewInvoice;
  final Function(SalesInvoice) onViewDetails;

  const SalesInvoicesScreen({
    super.key,
    required this.invoices,
    required this.onInvoiceDeleted,
    required this.onInvoiceUpdated,
    required this.onInvoiceEditRequested,
    required this.onNewInvoice,
    required this.onViewDetails,
  });

  @override
  State<SalesInvoicesScreen> createState() => _SalesInvoicesScreenState();
}

class _SalesInvoicesScreenState extends State<SalesInvoicesScreen> {
  List<SalesInvoice> _invoices = [];
  bool _showOnlyCredit = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _invoices = List.from(widget.invoices);
  }

  void _closeKeyboard() {
    FocusScope.of(context).unfocus();
  }

  List<SalesInvoice> _filteredLines() {
    var filtered = List<SalesInvoice>.from(_invoices);
    if (_showOnlyCredit) {
      filtered = filtered.where((inv) => inv.isCredit).toList();
    }
    final query = _normalizeSearchText(_searchQuery);
    if (query.isNotEmpty) {
      filtered = filtered
          .where((inv) =>
              _normalizeSearchText(inv.productName).contains(query) ||
              inv.barcode.contains(query) ||
              _normalizeSearchText(inv.customerName).contains(query) ||
              inv.customerPhone.contains(query) ||
              inv.number.toString().contains(query))
          .toList();
    }
    return filtered;
  }

  int _groupNetTotal(List<SalesInvoice> group) {
    if (group.isEmpty) return 0;
    final gross = group.fold<int>(0, (sum, x) => sum + x.totalPrice);
    return math.max(0, gross - group.first.discount);
  }

  Map<int, List<SalesInvoice>> _groupInvoices(List<SalesInvoice> lines) {
    final groups = <int, List<SalesInvoice>>{};
    for (final line in lines) {
      groups.putIfAbsent(line.number, () => []).add(line);
    }
    return groups;
  }

  Future<void> _editInvoiceGroup(List<SalesInvoice> group) async {
    await widget.onInvoiceEditRequested(group);
    if (mounted) setState(() => _invoices = List.from(widget.invoices));
  }

  Future<void> _deleteInvoiceGroup(int number, List<SalesInvoice> group) async {
    _closeKeyboard();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('حذف فاکتور شماره $number'),
        content: const Text(
            'آیا از حذف کل این فاکتور و تمام کالاهای آن مطمئن هستید؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('انصراف')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await widget.onInvoiceDeleted(group);
    setState(() {
      _invoices.removeWhere((inv) => inv.number == number);
    });
    widget.onInvoiceUpdated(List.from(_invoices));
    _showSuccessMessage('فاکتور شماره $number حذف شد 🗑️');
  }

  @override
  Widget build(BuildContext context) {
    final lines = _filteredLines();
    final groups = _groupInvoices(lines);
    final totalSales = _groupInvoices(lines)
        .values
        .fold<int>(0, (sum, group) => sum + _groupNetTotal(group));
    final totalCredit = _groupInvoices(lines)
        .values
        .where((group) => group.first.isCredit)
        .fold<int>(0, (sum, group) => sum + _groupNetTotal(group));

    return Scaffold(
      appBar: AppBar(
        title: const Text('🧾 فاکتورهای فروش'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: () {
              if (_invoices.isEmpty) {
                _showSuccessMessage('⚠️ هیچ فاکتوری برای گزارش وجود ندارد');
                return;
              }
              _shareSalesReport();
            },
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _closeKeyboard,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        labelText: '🔍 جستجو در فاکتورها',
                        hintText: 'نام کالا، بارکد، مشتری یا شماره فاکتور',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      onChanged: (value) =>
                          setState(() => _searchQuery = value),
                      onSubmitted: (_) => _closeKeyboard(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('نسیه'),
                    selected: _showOnlyCredit,
                    onSelected: (value) =>
                        setState(() => _showOnlyCredit = value),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _summary('تعداد فاکتور', '${groups.length}'),
                  _summary('مجموع فروش', _displayPrice(totalSales)),
                  _summary('مجموع نسیه', _displayPrice(totalCredit),
                      danger: true),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: groups.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.receipt_long,
                              size: 70, color: Colors.grey),
                          SizedBox(height: 12),
                          Text('هنوز فاکتوری ثبت نشده',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.bold)),
                          SizedBox(height: 6),
                          Text('برای شروع، «فاکتور جدید» را بزنید.'),
                        ],
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                      children: groups.entries.map((entry) {
                        final number = entry.key;
                        final group = entry.value;
                        final first = group.first;
                        final groupGross =
                            group.fold<int>(0, (sum, x) => sum + x.totalPrice);
                        final groupDiscount = group.first.discount;
                        final groupTotal =
                            math.max(0, groupGross - groupDiscount);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          elevation: 2,
                          child: InkWell(
                            onTap: () {
                              _closeKeyboard();
                              widget.onViewDetails(first);
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        backgroundColor: Colors.green.shade100,
                                        child: Text(
                                          '$number',
                                          style: TextStyle(
                                            color: Colors.green.shade700,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '🧾 فاکتور شماره $number',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                            ),
                                            Text(
                                              '📅 تاریخ: ${first.date}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit_outlined,
                                            color: Colors.orange),
                                        tooltip: 'ویرایش فاکتور',
                                        onPressed: () =>
                                            _editInvoiceGroup(group),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            color: Colors.red),
                                        tooltip: 'انتقال به سطل زباله',
                                        onPressed: () =>
                                            _deleteInvoiceGroup(number, group),
                                      ),
                                    ],
                                  ),
                                  const Divider(),
                                  Row(
                                    children: [
                                      const Icon(Icons.person_outline,
                                          size: 19),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          first.customerName.isEmpty
                                              ? 'مشتری: نقدی / بدون نام'
                                              : 'مشتری: ${first.customerName}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      if (first.isCredit)
                                        const Chip(
                                          label: Text('نسیه'),
                                          avatar:
                                              Icon(Icons.schedule, size: 16),
                                        ),
                                    ],
                                  ),
                                  if (first.customerPhone.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text('📱 موبایل: ${first.customerPhone}',
                                        style: const TextStyle(fontSize: 13)),
                                  ],
                                  const SizedBox(height: 8),
                                  const Text('📋 اقلام فاکتور',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 4),
                                  ...group.map((item) => Container(
                                        margin: const EdgeInsets.symmetric(
                                            vertical: 3),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                                child: Text(item.productName,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600))),
                                            Text(
                                                '${item.quantity} × ${_displayPrice(item.price)}'),
                                            const SizedBox(width: 8),
                                            Text(_displayPrice(item.totalPrice),
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                          ],
                                        ),
                                      )),
                                  const Divider(),
                                  if (groupDiscount > 0) ...[
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text('🏷️ تخفیف',
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold)),
                                        Text(_displayPrice(groupDiscount),
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.red)),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                  ],
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('💰 مبلغ نهایی فاکتور',
                                          style: TextStyle(
                                              fontWeight: FontWeight.bold)),
                                      Text(_displayPrice(groupTotal),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16)),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          _closeKeyboard();
          await widget.onNewInvoice();
          if (mounted) setState(() => _invoices = List.from(widget.invoices));
        },
        icon: const Icon(Icons.add),
        label: const Text('فاکتور جدید'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
      ),
    );
  }

  Widget _summary(String title, String value, {bool danger = false}) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: danger ? Colors.red : null)),
      ],
    );
  }

  void _showSuccessMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _shareSalesReport() async {
    try {
      _closeKeyboard();

      final font = await _loadFont();
      final pdf = pw.Document();

      final groupsForReport = _groupInvoices(_invoices);
      final totalSales = groupsForReport.values
          .fold<int>(0, (sum, group) => sum + _groupNetTotal(group));
      final totalCredit = groupsForReport.values
          .where((group) => group.first.isCredit)
          .fold<int>(0, (sum, group) => sum + _groupNetTotal(group));

      // متن فارسی در PDF باید صراحتاً RTL باشد.
      pw.Widget pdfText(
        String text, {
        double fontSize = 11,
        bool bold = false,
        PdfColor? color,
        pw.TextAlign align = pw.TextAlign.right,
      }) {
        return pw.Text(
          text,
          textDirection: pw.TextDirection.rtl,
          textAlign: align,
          style: pw.TextStyle(
            font: font,
            fontSize: fontSize,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: color,
          ),
        );
      }

      // برای اعداد و عبارت‌های ترکیبی فارسی/عدد، ترتیب نمایش را پایدار نگه می‌داریم.
      String pdfNumber(int value) {
        return _toPersianDigits(_formatPrice(value));
      }

      String pdfCount(int value) {
        return _toPersianDigits(value.toString());
      }

      String pdfPrice(int value) {
        return '${pdfNumber(value)} ریال';
      }

      pw.Widget cell(
        String text, {
        bool bold = false,
        double fontSize = 9,
        pw.TextAlign align = pw.TextAlign.center,
      }) {
        return pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 8,
          ),
          child: pdfText(
            text,
            fontSize: fontSize,
            bold: bold,
            align: align,
          ),
        );
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 30, 28, 30),
          textDirection: pw.TextDirection.rtl,
          maxPages: 100,
          build: (pw.Context context) {
            return [
              // =========================
              // عنوان گزارش
              // =========================
              pw.Center(
                child: pdfText(
                  'گزارش فروش',
                  fontSize: 26,
                  bold: true,
                  color: PdfColors.green,
                  align: pw.TextAlign.center,
                ),
              ),

              pw.SizedBox(height: 18),

              // =========================
              // خلاصه گزارش
              // =========================
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(14),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.start,
                      children: [
                        pdfText('تعداد فاکتورها:', bold: true),
                        pw.SizedBox(width: 8),
                        pdfText(pdfCount(_invoices.length)),
                      ],
                    ),
                    pw.SizedBox(height: 8),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.start,
                      children: [
                        pdfText('مجموع فروش:', bold: true),
                        pw.SizedBox(width: 8),
                        pdfText(
                          pdfPrice(totalSales),
                          bold: true,
                          color: PdfColors.green,
                        ),
                      ],
                    ),
                    pw.SizedBox(height: 8),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.start,
                      children: [
                        pdfText('مجموع نسیه:', bold: true),
                        pw.SizedBox(width: 8),
                        pdfText(
                          pdfPrice(totalCredit),
                          bold: true,
                          color: PdfColors.orange,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 20),

              // =========================
              // عنوان جدول
              // =========================
              pdfText(
                'لیست فاکتورها:',
                fontSize: 18,
                bold: true,
              ),

              pw.SizedBox(height: 10),

              // =========================
              // جدول فاکتورها
              // =========================
              // ترتیب children عمداً از راست به چپ است:
              // مشتری | قیمت | تعداد | کالا | شماره | ردیف
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.black,
                  width: 0.8,
                ),
                tableWidth: pw.TableWidth.max,
                columnWidths: const {
                  0: pw.FlexColumnWidth(1.55),
                  1: pw.FlexColumnWidth(1.55),
                  2: pw.FlexColumnWidth(1.35),
                  3: pw.FlexColumnWidth(0.8),
                  4: pw.FlexColumnWidth(2.2),
                  5: pw.FlexColumnWidth(0.8),
                  6: pw.FlexColumnWidth(0.65),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.green100,
                    ),
                    children: [
                      cell('مشتری', bold: true),
                      cell('مبلغ نهایی', bold: true),
                      cell('تخفیف', bold: true),
                      cell('تعداد', bold: true),
                      cell('کالا', bold: true),
                      cell('شماره', bold: true),
                      cell('ردیف', bold: true),
                    ],
                  ),
                  ..._invoices.asMap().entries.map((entry) {
                    final index = entry.key + 1;
                    final inv = entry.value;

                    final customerName = inv.customerName.trim().isEmpty
                        ? 'نقدی'
                        : inv.customerName.trim();

                    return pw.TableRow(
                      children: [
                        cell(
                          customerName,
                          fontSize: 8.5,
                        ),
                        cell(
                          pdfPrice(math.max(0, inv.totalPrice - inv.discount)),
                          fontSize: 8.5,
                        ),
                        cell(
                          pdfPrice(inv.discount),
                          fontSize: 8.5,
                        ),
                        cell(
                          pdfCount(inv.quantity),
                          fontSize: 8.5,
                        ),
                        cell(
                          inv.productName,
                          fontSize: 8.5,
                        ),
                        cell(
                          pdfCount(inv.number),
                          fontSize: 8.5,
                        ),
                        cell(
                          pdfCount(index),
                          fontSize: 8.5,
                        ),
                      ],
                    );
                  }),
                ],
              ),

              pw.SizedBox(height: 24),

              pw.SizedBox(height: 12),
              pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pdfText(
                  'مجموع تخفیف‌ها: ${pdfPrice(_invoices.fold<int>(0, (sum, inv) => sum + inv.discount))}',
                  bold: true,
                ),
              ),

              // =========================
              // تاریخ تهیه گزارش
              // =========================
              pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: pdfText(
                  'تاریخ تهیه: ${_todayJalali()}',
                  fontSize: 9,
                  color: PdfColors.grey,
                  align: pw.TextAlign.left,
                ),
              ),
            ];
          },
        ),
      );

      final bytes = await pdf.save();
      final tempFile = File(
        '${Directory.systemTemp.path}/sales_report.pdf',
      );
      await tempFile.writeAsBytes(bytes, flush: true);

      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text:
            'گزارش فروش\nتعداد فاکتورها: ${_toPersianDigits(_invoices.length.toString())}',
      );

      _showSuccessMessage('گزارش فروش ارسال شد');
    } catch (e) {
      _showSuccessMessage('خطا در ارسال گزارش فروش: $e');
    }
  }

  String _todayJalali() {
    final now = DateTime.now();
    final j = _gregorianToJalali(now.year, now.month, now.day);
    return '${_toPersianDigits(j[0].toString())}/${_toPersianDigits(j[1].toString().padLeft(2, '0'))}/${_toPersianDigits(j[2].toString().padLeft(2, '0'))}';
  }
}

class TrashScreen extends StatefulWidget {
  final List<TrashItem> items;
  final Future<bool> Function(TrashItem) onRestore;
  final Future<void> Function() onChanged;

  const TrashScreen({
    super.key,
    required this.items,
    required this.onRestore,
    required this.onChanged,
  });

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late List<TrashItem> _items;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
    _cleanupExpired();
  }

  Future<void> _cleanupExpired() async {
    final cutoff =
        DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final expired = _items.where((e) => e.deletedAt <= cutoff).toList();
    if (expired.isEmpty) return;
    _items.removeWhere((e) => e.deletedAt <= cutoff);
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'trash_items', jsonEncode(_items.map((e) => e.toJson()).toList()));
    await widget.onChanged();
  }

  String _typeTitle(String type) {
    switch (type) {
      case 'invoice':
        return 'فاکتور فروش';
      case 'product':
        return 'کالا';
      case 'manifest':
        return 'بارنامه';
      default:
        return 'مورد حذف‌شده';
    }
  }

  Future<void> _restore(TrashItem item) async {
    final ok = await widget.onRestore(item);
    if (!mounted) return;
    if (ok) {
      setState(() => _items.removeWhere((x) => x.id == item.id));
      await _save();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${item.title} بازیابی شد ✅')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'بازیابی انجام نشد؛ ممکن است شناسه فاکتور تکراری باشد یا موجودی کافی نباشد.',
        ),
      ));
    }
  }

  Future<void> _deletePermanently(TrashItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف دائمی'),
        content: Text(
            '«${item.title}» برای همیشه حذف شود؟ این عملیات قابل برگشت نیست.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('انصراف')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف دائمی')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _items.removeWhere((x) => x.id == item.id));
    await _save();
  }

  Future<void> _emptyTrash() async {
    if (_items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('خالی کردن سطل زباله'),
        content: const Text('تمام موارد سطل زباله برای همیشه حذف شوند؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('انصراف')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('خالی کردن')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _items.clear());
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🗑️ سطل زباله'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          if (_items.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.delete_forever),
                tooltip: 'خالی کردن سطل',
                onPressed: _emptyTrash),
        ],
      ),
      body: _items.isEmpty
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.delete_outline, size: 80, color: Colors.grey),
              SizedBox(height: 12),
              Text('سطل زباله خالی است',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text('موارد حذف‌شده تا ۷ روز اینجا نگهداری می‌شوند.'),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                final date =
                    DateTime.fromMillisecondsSinceEpoch(item.deletedAt);
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                        child: Icon(item.type == 'invoice'
                            ? Icons.receipt_long
                            : item.type == 'manifest'
                                ? Icons.local_shipping_outlined
                                : Icons.inventory_2_outlined)),
                    title: Text(item.title,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                        '${_typeTitle(item.type)} • حذف شده در ${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}'),
                    trailing: Wrap(spacing: 0, children: [
                      IconButton(
                          icon: const Icon(Icons.restore, color: Colors.green),
                          tooltip: 'بازیابی',
                          onPressed: () => _restore(item)),
                      IconButton(
                          icon: const Icon(Icons.delete_forever,
                              color: Colors.red),
                          tooltip: 'حذف دائمی',
                          onPressed: () => _deletePermanently(item)),
                    ]),
                  ),
                );
              },
            ),
    );
  }
}

// ==================== صفحه هزینه های روزانه ====================

class DailyExpensesScreen extends StatefulWidget {
  final List<DailyExpense> expenses;
  final Future<void> Function(List<DailyExpense>) onChanged;

  const DailyExpensesScreen({
    super.key,
    required this.expenses,
    required this.onChanged,
  });

  @override
  State<DailyExpensesScreen> createState() => _DailyExpensesScreenState();
}

class _DailyExpensesScreenState extends State<DailyExpensesScreen> {
  late List<DailyExpense> _expenses;
  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  final _dateController = TextEditingController(text: _todayJalali());
  String? _editingId;

  @override
  void initState() {
    super.initState();
    _expenses = List.from(widget.expenses);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  String _normalizeDigits(String value) {
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    const ar = '٠١٢٣٤٥٦٧٨٩';
    for (var i = 0; i < 10; i++) {
      value = value.replaceAll(fa[i], '$i').replaceAll(ar[i], '$i');
    }
    return value;
  }

  String _formatAmount(String value) {
    final n = int.tryParse(_normalizeDigits(value).replaceAll(',', '').trim());
    if (n == null) return value;
    return _toPersianDigits(n.toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'),
          (m) => ',',
        ));
  }

  void _formatAmountField(TextEditingController controller) {
    final raw = _normalizeDigits(controller.text).replaceAll(',', '');
    if (raw.isEmpty) return;
    final number = int.tryParse(raw);
    if (number == null) return;
    final formatted = _formatAmount(raw);
    if (controller.text == formatted) return;
    final oldOffset = controller.selection.baseOffset;
    controller.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(
        offset: formatted.length
            .clamp(0, oldOffset + (formatted.length - controller.text.length)),
      ),
    );
  }

  Future<void> _saveExpense() async {
    final name = _nameController.text.trim();
    final amount = int.tryParse(
      _normalizeDigits(_amountController.text).replaceAll(',', '').trim(),
    );
    final date = _dateController.text.trim();

    if (name.isEmpty || amount == null || amount < 0 || date.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('لطفاً نام هزینه، مبلغ و تاریخ را کامل وارد کنید.')),
      );
      return;
    }

    final item = DailyExpense(
      id: _editingId ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      amount: amount,
      date: date,
    );

    setState(() {
      if (_editingId == null) {
        _expenses.insert(0, item);
      } else {
        final index = _expenses.indexWhere((e) => e.id == _editingId);
        if (index != -1) _expenses[index] = item;
      }
      _editingId = null;
      _nameController.clear();
      _amountController.clear();
      _dateController.text = _todayJalali();
    });
    await widget.onChanged(List.from(_expenses));
  }

  void _editExpense(DailyExpense expense) {
    setState(() {
      _editingId = expense.id;
      _nameController.text = expense.name;
      _amountController.text = expense.amount.toString();
      _dateController.text = expense.date;
    });
  }

  Future<void> _deleteExpense(DailyExpense expense) async {
    setState(() => _expenses.removeWhere((e) => e.id == expense.id));
    await widget.onChanged(List.from(_expenses));
  }

  @override
  Widget build(BuildContext context) {
    final total = _expenses.fold<int>(0, (sum, e) => sum + e.amount);
    return Scaffold(
      appBar: AppBar(
        title: const Text('💰 هزینه های روزانه'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 2,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _editingId == null ? 'ثبت هزینه جدید' : 'ویرایش هزینه',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'نام هزینه',
                      prefixIcon: Icon(Icons.description_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _amountController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9۰-۹٠-٩,]'))
                    ],
                    onChanged: (_) => _formatAmountField(_amountController),
                    decoration: const InputDecoration(
                      labelText: 'مبلغ به ریال',
                      prefixIcon: Icon(Icons.payments_outlined),
                      suffixText: 'ریال',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _dateController,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: 'روز / تاریخ',
                      hintText: 'مثلاً ۱۴۰۵/۰۶/۱۳',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    onPressed: _saveExpense,
                    icon: Icon(_editingId == null ? Icons.add : Icons.save),
                    label: Text(_editingId == null
                        ? 'تأیید و ثبت هزینه'
                        : 'ذخیره ویرایش'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                  ),
                  if (_editingId != null)
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _editingId = null;
                          _nameController.clear();
                          _amountController.clear();
                          _dateController.text = _todayJalali();
                        });
                      },
                      child: const Text('انصراف از ویرایش'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            color: Colors.green.shade50,
            child: ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined,
                  color: Colors.green),
              title: const Text('جمع کل هزینه ها',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: Text(
                '${_toPersianDigits(total.toString())} ریال',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (_expenses.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('هنوز هزینه‌ای ثبت نشده است.')),
              ),
            )
          else
            ..._expenses.map(
              (expense) => Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.red.shade50,
                    child: Icon(Icons.receipt_long_outlined,
                        color: Colors.red.shade700),
                  ),
                  title: Text(expense.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${expense.date}\n${_formatAmount(expense.amount.toString())} ریال'),
                  isThreeLine: true,
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      IconButton(
                        tooltip: 'ویرایش',
                        icon:
                            const Icon(Icons.edit_outlined, color: Colors.blue),
                        onPressed: () => _editExpense(expense),
                      ),
                      IconButton(
                        tooltip: 'حذف',
                        icon:
                            const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _deleteExpense(expense),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ==================== صفحه تنظیمات ====================

class SettingsScreen extends StatefulWidget {
  final bool isDarkMode;
  final String userName;
  final List<CustomEvent> customEvents;
  final Future<void> Function(List<CustomEvent>) onCustomEventsChanged;
  final Future<void> Function(DateTime? inventoryDate, DateTime? cleaningDate)?
      onFixedEventDatesChanged;
  final Function(bool, String) onSettingsChanged;

  const SettingsScreen({
    super.key,
    required this.isDarkMode,
    required this.userName,
    required this.customEvents,
    required this.onCustomEventsChanged,
    this.onFixedEventDatesChanged,
    required this.onSettingsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _darkMode;
  late TextEditingController _nameController;
  bool _notificationsEnabled = false;
  bool _limitedNotifications = false;
  bool _notificationBusy = false;
  late List<CustomEvent> _customEvents;
  DateTime? _inventoryLastDate;
  DateTime? _cleaningLastDate;

  @override
  void initState() {
    super.initState();
    _darkMode = widget.isDarkMode;
    _nameController = TextEditingController(text: widget.userName);
    _customEvents = List.from(widget.customEvents);
    _loadFixedEventDates();
    _loadNotificationSetting();
  }

  Future<void> _loadNotificationSetting() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? false;
      _limitedNotifications =
          prefs.getBool('limited_notifications_enabled') ?? false;
    });
  }

  Future<void> _toggleNotifications(bool value) async {
    if (_notificationBusy) return;
    setState(() => _notificationBusy = true);

    try {
      if (value) {
        final granted =
            await StoreNotificationService.instance.enableNotifications();
        if (!mounted) return;

        if (!granted) {
          setState(() => _notificationsEnabled = false);
          _showSnackbar(
            '⚠️ دسترسی اعلان فعال نشد. لطفاً اجازه اعلان برنامه را در تنظیمات گوشی فعال کنید.',
          );
          return;
        }

        setState(() => _notificationsEnabled = true);
        _showSnackbar('✅ سیستم اعلان فعال شد');
        final prefs = await SharedPreferences.getInstance();
        final limited = prefs.getBool('limited_notifications_enabled') ?? false;
        if (!limited) {
          await StoreNotificationService.instance.showActivationNotification();
        }
        final name = prefs.getString('user_name') ?? widget.userName;
        final gender =
            prefs.getString('user_gender') == 'female' ? 'female' : 'male';
        if (name.isNotEmpty) {
          await StoreNotificationService.instance.scheduleMorningNotifications(
            userName: name,
            gender: gender,
            customEvents: List<CustomEvent>.from(_customEvents),
          );
        }
      } else {
        await StoreNotificationService.instance.cancelMorningNotifications();
        await StoreNotificationService.instance.disableNotifications();
        if (!mounted) return;
        setState(() => _notificationsEnabled = false);
        _showSnackbar('اعلان‌های برنامه غیرفعال شد');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _notificationsEnabled = false);
      _showSnackbar('❌ فعال‌سازی اعلان با خطا مواجه شد');
    } finally {
      if (mounted) setState(() => _notificationBusy = false);
    }
  }

  Future<void> _loadFixedEventDates() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final fallbackInventory = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 19));
    final fallbackCleaning = DateTime(now.year, now.month, now.day);
    if (!mounted) return;
    setState(() {
      _inventoryLastDate = DateTime.tryParse(
              prefs.getString('fixed_inventory_last_date_v2') ?? '') ??
          fallbackInventory;
      _cleaningLastDate = DateTime.tryParse(
              prefs.getString('fixed_cleaning_last_date_v1') ?? '') ??
          fallbackCleaning;
    });
  }

  Future<void> _setFixedEventDate({required bool inventory}) async {
    final current = inventory
        ? (_inventoryLastDate ?? DateTime.now())
        : (_cleaningLastDate ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
    );
    if (picked == null) return;
    final date = DateTime(picked.year, picked.month, picked.day);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        inventory
            ? 'fixed_inventory_last_date_v2'
            : 'fixed_cleaning_last_date_v1',
        date.toIso8601String());
    if (!mounted) return;
    setState(() {
      if (inventory) {
        _inventoryLastDate = date;
      } else {
        _cleaningLastDate = date;
      }
    });
    await widget.onFixedEventDatesChanged
        ?.call(_inventoryLastDate, _cleaningLastDate);
    _showSnackbar(inventory
        ? 'روزشمار انبارگردانی تغییر کرد.'
        : 'روزشمار نظافت تغییر کرد.');
  }

  Future<void> _addOrEditEvent({CustomEvent? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    DateTime selectedDate = DateTime.tryParse(existing?.isoDate ?? '') ??
        DateTime.now().add(const Duration(days: 1));
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<CustomEvent>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title:
              Text(existing == null ? 'افزودن رویداد جدید' : 'ویرایش رویداد'),
          content: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                    labelText: 'نام رویداد',
                    prefixIcon: Icon(Icons.event_outlined)),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'نام رویداد را وارد کنید'
                    : null,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_month_outlined),
                title: const Text('تاریخ رویداد'),
                subtitle: Text(_jalaliLongForDate(selectedDate)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime.now(),
                    lastDate: DateTime(2100),
                    builder: (context, child) => Directionality(
                        textDirection: TextDirection.rtl, child: child!),
                  );
                  if (picked != null)
                    setStateDialog(() => selectedDate = picked);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('انصراف')),
            ElevatedButton(
              onPressed: () {
                if (!(formKey.currentState?.validate() ?? false)) return;
                Navigator.pop(
                    dialogContext,
                    CustomEvent(
                      id: existing?.id ??
                          DateTime.now().microsecondsSinceEpoch.toString(),
                      name: nameController.text.trim(),
                      isoDate: DateTime(selectedDate.year, selectedDate.month,
                              selectedDate.day)
                          .toIso8601String(),
                    ));
              },
              child: const Text('تأیید'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    if (result == null) return;
    setState(() {
      final index = _customEvents.indexWhere((e) => e.id == result.id);
      if (index >= 0) {
        _customEvents[index] = result;
      } else {
        _customEvents.add(result);
      }
    });
    await widget.onCustomEventsChanged(List.from(_customEvents));
  }

  Future<void> _deleteEvent(CustomEvent event) async {
    setState(() => _customEvents.removeWhere((e) => e.id == event.id));
    await widget.onCustomEventsChanged(List.from(_customEvents));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _closeKeyboard() {
    FocusScope.of(context).unfocus();
  }

  Future<void> _saveSettings() async {
    _closeKeyboard();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', _darkMode);
    await prefs.setString('user_name', _nameController.text);
    widget.onSettingsChanged(_darkMode, _nameController.text);
  }

  void _sendEmail() async {
    final Uri emailUri = Uri(
      scheme: 'mailto',
      path: 'rezagasem.82@gmail.com',
      query: 'subject=پیشنهاد برای اپلیکیشن تحویل بار&body=سلام،%0A%0A',
    );
    try {
      await launchUrl(emailUri);
    } catch (e) {
      _showSnackbar('❌ خطا در باز کردن ایمیل');
    }
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('⚙️ تنظیمات'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () async {
              await _saveSettings();
              _showSnackbar('✅ تنظیمات ذخیره شد');
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _closeKeyboard,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '🌓 ظاهر',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    SwitchListTile(
                      title: const Text('حالت تاریک (دارک مود)'),
                      subtitle: Text(_darkMode ? 'فعال' : 'غیرفعال'),
                      value: _darkMode,
                      onChanged: (value) {
                        setState(() {
                          _darkMode = value;
                        });
                      },
                      secondary: Icon(
                        _darkMode ? Icons.dark_mode : Icons.light_mode,
                        color: _darkMode ? Colors.white : Colors.orange,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '🔔 اعلان‌ها',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    SwitchListTile(
                      title: const Text('فعال سازی اعلان اپلیکیشن'),
                      subtitle: Text(
                        _notificationBusy
                            ? 'در حال بررسی دسترسی...'
                            : (_notificationsEnabled ? 'فعال' : 'غیرفعال'),
                      ),
                      value: _notificationsEnabled,
                      onChanged:
                          _notificationBusy ? null : _toggleNotifications,
                      secondary: Icon(
                        _notificationsEnabled
                            ? Icons.notifications_active
                            : Icons.notifications_off_outlined,
                        color:
                            _notificationsEnabled ? Colors.green : Colors.grey,
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('محدودسازی اعلان‌ها'),
                      subtitle: const Text(
                          'فقط اعلان صبح ۸:۳۰، ورود یک‌بار در روز و اولین فاکتور فروش هر روز'),
                      value: _limitedNotifications,
                      onChanged: (value) async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool(
                            'limited_notifications_enabled', value);
                        if (mounted)
                          setState(() => _limitedNotifications = value);
                      },
                      secondary:
                          const Icon(Icons.notifications_paused_outlined),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                            child: Text('📅 رویدادهای روزشمار',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold))),
                        IconButton(
                            onPressed: () => _addOrEditEvent(),
                            icon: const Icon(Icons.add_circle,
                                color: Colors.green),
                            tooltip: 'افزودن رویداد'),
                      ],
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.inventory_2_outlined,
                          color: Colors.teal),
                      title: const Text('انبارگردانی'),
                      subtitle: Text(_inventoryLastDate == null
                          ? 'هر ۴۰ روز یک‌بار'
                          : 'روزشمار فعال • ${_jalaliLongForDate(_inventoryLastDate!)}'),
                      trailing: const Icon(Icons.edit_calendar_outlined),
                      onTap: () => _setFixedEventDate(inventory: true),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cleaning_services_outlined,
                          color: Colors.green),
                      title: const Text('نظافت'),
                      subtitle: Text(_cleaningLastDate == null
                          ? 'هر ۳۰ روز یک‌بار'
                          : 'روزشمار فعال • ${_jalaliLongForDate(_cleaningLastDate!)}'),
                      trailing: const Icon(Icons.edit_calendar_outlined),
                      onTap: () => _setFixedEventDate(inventory: false),
                    ),
                    if (_customEvents.isEmpty)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('رویداد سفارشی ثبت نشده است.'))
                    else
                      ..._customEvents.map((event) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.event_available_outlined,
                                color: Colors.green),
                            title: Text(event.name),
                            subtitle: Text(_jalaliLongForDate(
                                DateTime.parse(event.isoDate))),
                            trailing: Wrap(children: [
                              IconButton(
                                  icon: const Icon(Icons.edit_outlined,
                                      color: Colors.blue),
                                  onPressed: () =>
                                      _addOrEditEvent(existing: event)),
                              IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                  onPressed: () => _deleteEvent(event)),
                            ]),
                          )),
                  ],
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '👤 اطلاعات کاربر',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'نام کامل',
                        prefixIcon: Icon(Icons.person),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '📧 ارتباط با ما',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.email, color: Colors.blue),
                      title: const Text('ارسال ایمیل'),
                      subtitle: const Text('rezagasem.82@gmail.com'),
                      onTap: _sendEmail,
                    ),
                    ListTile(
                      leading: const Icon(Icons.feedback, color: Colors.orange),
                      title: const Text('ارسال پیشنهاد'),
                      subtitle: const Text(
                          'نظرات و پیشنهادات خود را با ما به اشتراک بگذارید'),
                      onTap: _sendEmail,
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(Icons.apps, size: 48, color: Colors.green),
                    const SizedBox(height: 8),
                    const Text(
                      'اپلیکیشن تحویل بار و فروش',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'نسخه 2.2.0',
                      style:
                          TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'توسعه‌دهنده: رضا قاسمی',
                      style:
                          TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '📧 rezagasem.82@gmail.com',
                      style:
                          TextStyle(fontSize: 13, color: Colors.blue.shade700),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== صفحه بانک اطلاعاتی کالاها با قابلیت حذف ====================

class SalesProfitScreen extends StatefulWidget {
  final List<ProductDatabaseItem> products;
  final Future<void> Function(ProductDatabaseItem updatedProduct)?
      onPriceChanged;

  const SalesProfitScreen({
    super.key,
    required this.products,
    this.onPriceChanged,
  });

  @override
  State<SalesProfitScreen> createState() => _SalesProfitScreenState();
}

class _SalesProfitScreenState extends State<SalesProfitScreen> {
  late List<ProductDatabaseItem> _products;
  String _searchQuery = '';
  String _selectedGroup = 'همه';
  double _profitFilterCenter = 0;

  @override
  void initState() {
    super.initState();
    _products = List<ProductDatabaseItem>.from(widget.products);
  }

  List<String> get _groups {
    final values = <String>{'عمومی'};
    for (final p in _products) {
      if (p.groupName.trim().isNotEmpty) values.add(p.groupName.trim());
    }

    // «کالاهای جدید» یک گروه ویژه است و همیشه باید در صدر گروه‌ها باشد.
    // بعد از آن «همه گروه‌ها» و سپس گروه‌های عادی نمایش داده می‌شوند.
    final groups = <String>[];
    if (_products.any((p) => p.isNewProduct)) {
      groups.add('🆕 کالاهای جدید');
    }
    groups.add('همه');
    groups.addAll(values.where((e) => e != 'همه'));
    return groups;
  }

  Widget _groupChip(String group) {
    final selected = _selectedGroup == group;
    final isNewGroup = group == '🆕 کالاهای جدید';
    final label = group == 'همه' ? 'همه گروه‌ها' : group;

    // رنگ متن در حالت انتخاب‌شده عمداً تیره و خوانا است تا با زمینه روشن/سبز
    // تداخل نداشته باشد و «کالاهای جدید» نیز با رنگ طلایی هویت مستقل داشته باشد.
    final foreground = selected
        ? (isNewGroup ? Colors.brown.shade900 : Colors.green.shade900)
        : (isNewGroup ? Colors.amber.shade900 : Colors.grey.shade900);
    final background = isNewGroup
        ? (selected ? Colors.amber.shade200 : Colors.amber.shade50)
        : (selected ? Colors.green.shade100 : Colors.grey.shade100);

    return ChoiceChip(
      selected: selected,
      backgroundColor: background,
      selectedColor: background,
      side: BorderSide(
        color: isNewGroup ? Colors.amber.shade700 : Colors.grey.shade400,
      ),
      avatar: Icon(
        isNewGroup ? Icons.star_rounded : Icons.folder_rounded,
        size: 19,
        color: foreground,
      ),
      label: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontWeight:
              selected || isNewGroup ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
      onSelected: (_) => setState(() => _selectedGroup = group),
    );
  }

  List<ProductDatabaseItem> get _filteredProducts {
    final query = _normalizeSearchText(_searchQuery);
    return _products.where((p) {
      final matchesQuery = query.isEmpty ||
          _normalizeSearchText(p.name).contains(query) ||
          p.barcode.toLowerCase().contains(query);
      final matchesGroup = _selectedGroup == 'همه' ||
          (_selectedGroup == '🆕 کالاهای جدید'
              ? p.isNewProduct
              : p.groupName.trim() == _selectedGroup);
      final percentage = _percentage(p);
      final matchesProfit = _profitFilterCenter <= 0 ||
          (percentage != null &&
              percentage >= _profitFilterCenter - 10 &&
              percentage <= _profitFilterCenter + 10);
      return matchesQuery && matchesGroup && matchesProfit;
    }).toList();
  }

  int _profit(ProductDatabaseItem p) => p.sellPrice - p.buyPrice;

  double? _percentage(ProductDatabaseItem p) {
    if (p.buyPrice <= 0) return null;
    return (_profit(p) / p.buyPrice) * 100;
  }

  String _formatPercent(double value) {
    final rounded = double.parse(value.toStringAsFixed(1));
    final text = rounded == rounded.roundToDouble()
        ? rounded.toInt().toString()
        : rounded.toString();
    return _toPersianDigits(text);
  }

  Future<void> _editSellingPrice(ProductDatabaseItem product) async {
    final controller =
        TextEditingController(text: product.sellPrice.toString());
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('ویرایش قیمت فروش: ${product.name}'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.rtl,
            decoration: const InputDecoration(
              labelText: 'قیمت فروش جدید (ریال)',
              prefixIcon: Icon(Icons.edit_outlined),
            ),
            validator: (value) {
              final price = int.tryParse(
                (value ?? '').replaceAll(',', '').replaceAll('٬', '').trim(),
              );
              if (price == null || price < 0) return 'قیمت معتبر وارد کنید';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.check),
            label: const Text('ثبت قیمت جدید'),
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                  dialogContext,
                  int.parse(
                    controller.text
                        .replaceAll(',', '')
                        .replaceAll('٬', '')
                        .trim(),
                  ));
            },
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null || result == product.sellPrice) return;

    final originalPrice = product.originalSellPrice ?? product.sellPrice;
    final updated = product.copyWith(
      sellPrice: result,
      isPriceModified: true,
      originalSellPrice: originalPrice,
    );

    if (widget.onPriceChanged != null) {
      await widget.onPriceChanged!(updated);
    }
    if (!mounted) return;
    setState(() {
      final index = _products.indexWhere((p) => p.barcode == updated.barcode);
      if (index != -1) _products[index] = updated;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'قیمت فروش «${product.name}» از ${_displayPrice(product.sellPrice)} به ${_displayPrice(result)} ریال تغییر کرد ✅',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final products = _filteredProducts;
    final changedCount = _products.where((p) => p.isPriceModified).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('📈 محاسبه سود و تغییر قیمت'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          if (changedCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Center(
                child: Text(
                  'تغییر یافته: ${_toPersianDigits(changedCount.toString())}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              textDirection: TextDirection.rtl,
              decoration: InputDecoration(
                labelText: 'جستجوی کالا',
                hintText: 'نام کالا یا بارکد',
                prefixIcon: const Icon(Icons.search),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),
          if (_groups.length > 1)
            SizedBox(
              height: 48,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                itemCount: _groups.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, index) {
                  final group = _groups[index];
                  return _groupChip(group);
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                'تعداد کالاها: ${_toPersianDigits(products.length.toString())}   |   زرد = قیمت ویرایش شده   |   🆕 = کالای جدید',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          if (widget.products.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('فیلتر درصد سود',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(_profitFilterCenter <= 0
                            ? 'همه'
                            : 'بین ${_formatPercent((_profitFilterCenter - 10).clamp(0, 100))}٪ تا ${_formatPercent((_profitFilterCenter + 10).clamp(0, 100))}٪'),
                      ]),
                  Slider(
                    min: 0,
                    max: 100,
                    divisions: 20,
                    value: _profitFilterCenter,
                    label: _profitFilterCenter <= 0
                        ? 'همه'
                        : '${_formatPercent(_profitFilterCenter)}٪',
                    onChanged: (value) =>
                        setState(() => _profitFilterCenter = value),
                  ),
                ],
              ),
            ),
          ],
          Expanded(
            child: products.isEmpty
                ? Center(
                    child: Text(_products.isEmpty
                        ? 'هنوز کالایی در بانک اطلاعاتی ثبت نشده است.'
                        : 'کالایی با این مشخصات پیدا نشد.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: products.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final product = products[index];
                      final profit = _profit(product);
                      final percentage = _percentage(product);
                      final isProfit = profit >= 0;
                      final statusColor = isProfit ? Colors.green : Colors.red;
                      final cardColor = product.isPriceModified
                          ? Colors.yellow.shade100
                          : null;

                      return Card(
                        color: cardColor,
                        elevation: product.isPriceModified ? 3 : 1.5,
                        margin: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor:
                                        statusColor.withOpacity(.12),
                                    child: Text(
                                        _toPersianDigits('${index + 1}'),
                                        style: TextStyle(
                                            color: statusColor,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                  product.name.isEmpty
                                                      ? 'کالای بدون نام'
                                                      : product.name,
                                                  style: const TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.bold)),
                                            ),
                                            if (product.isNewProduct)
                                              const Text('جدید',
                                                  style: TextStyle(
                                                      color: Colors.amber,
                                                      fontWeight:
                                                          FontWeight.bold)),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text('گروه: ${product.groupName}',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade700)),
                                      ],
                                    ),
                                  ),
                                  if (product.isNewProduct)
                                    const Tooltip(
                                      message:
                                          'این کالا در بانک جدید برای اولین بار وارد شده است',
                                      child:
                                          Icon(Icons.star, color: Colors.amber),
                                    ),
                                  if (product.isPriceModified)
                                    const Tooltip(
                                      message: 'قیمت این کالا ویرایش شده است',
                                      child: Icon(Icons.edit_note,
                                          color: Colors.orange),
                                    ),
                                ],
                              ),
                              if (product.barcode.isNotEmpty) ...[
                                const SizedBox(height: 5),
                                Text(
                                    'بارکد: ${_toPersianDigits(product.barcode)}',
                                    textDirection: TextDirection.rtl,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600)),
                              ],
                              const Divider(height: 22),
                              Row(
                                children: [
                                  Expanded(
                                      child: _priceColumn(
                                          'قیمت خرید', product.buyPrice)),
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text('قیمت فروش',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600)),
                                        const SizedBox(height: 4),
                                        Text(_displayPrice(product.sellPrice),
                                            textDirection: TextDirection.rtl,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700)),
                                        if (product.originalSellPrice != null &&
                                            product.isPriceModified)
                                          Text(
                                              'قبلی: ${_displayPrice(product.originalSellPrice!)}',
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.grey.shade700)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              ElevatedButton.icon(
                                onPressed: () => _editSellingPrice(product),
                                icon: const Icon(Icons.edit_outlined),
                                label: const Text('تغییر قیمت فروش'),
                                style: ElevatedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(42)),
                              ),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: statusColor.withOpacity(.09),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: statusColor.withOpacity(.25)),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                        isProfit
                                            ? Icons.trending_up
                                            : Icons.trending_down,
                                        color: statusColor),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: Text(
                                            isProfit ? 'سود فروش' : 'ضرر فروش',
                                            style: TextStyle(
                                                color: statusColor,
                                                fontWeight: FontWeight.bold))),
                                    Text(
                                        '${profit >= 0 ? '+' : '-'}${_displayPrice(profit.abs())}',
                                        textDirection: TextDirection.rtl,
                                        style: TextStyle(
                                            color: statusColor,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15)),
                                    const SizedBox(width: 10),
                                    if (percentage != null)
                                      Text(
                                          '${percentage >= 0 ? '+' : '-'}${_formatPercent(percentage.abs())}٪',
                                          style: TextStyle(
                                              color: statusColor,
                                              fontWeight: FontWeight.bold))
                                    else
                                      Text('درصد نامشخص',
                                          style: TextStyle(
                                              color: Colors.grey.shade600,
                                              fontSize: 12)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _priceColumn(String title, int price) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(title,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 4),
        Text(_displayPrice(price),
            textDirection: TextDirection.rtl,
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class ProductDatabaseScreen extends StatefulWidget {
  final List<ProductDatabaseItem> database;
  final Function(List<ProductDatabaseItem>) onDatabaseUpdated;
  final Future<void> Function(ProductDatabaseItem) onItemDeleted;
  final Future<void> Function(List<ProductDatabaseItem>) onDeleteAll;

  const ProductDatabaseScreen({
    super.key,
    required this.database,
    required this.onDatabaseUpdated,
    required this.onItemDeleted,
    required this.onDeleteAll,
  });

  @override
  State<ProductDatabaseScreen> createState() => _ProductDatabaseScreenState();
}

class _ProductDatabaseScreenState extends State<ProductDatabaseScreen> {
  late List<ProductDatabaseItem> _items;
  bool _isLoading = false;
  String _selectedFolder = 'همه';
  String _newItemFolder = 'عمومی';
  List<String> _customFolders = [];

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.database);
    _loadFolders();
    final folders = _folders;
    if (folders.length > 1) {
      _newItemFolder = folders.firstWhere(
        (f) => f != 'عمومی',
        orElse: () => 'عمومی',
      );
    }
  }

  void _closeKeyboard() {
    FocusScope.of(context).unfocus();
  }

  Future<void> _loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('product_folders') ?? [];
    if (!mounted) return;
    setState(() => _customFolders = saved);
  }

  Future<void> _saveFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('product_folders', _customFolders);
  }

  List<String> get _folders {
    final values = <String>{'عمومی', ..._customFolders};
    for (final item in _items) {
      if (item.folder.trim().isNotEmpty) values.add(item.folder.trim());
    }
    return values.toList()
      ..sort((a, b) {
        if (a == 'عمومی') return -1;
        if (b == 'عمومی') return 1;
        return a.compareTo(b);
      });
  }

  List<ProductDatabaseItem> get _visibleItems {
    if (_selectedFolder == 'همه') return _items;
    return _items.where((item) => item.folder == _selectedFolder).toList();
  }

  void _notifyUpdate() {
    widget.onDatabaseUpdated(_items);
  }

  String _formatPrice(int price) {
    return price.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (match) => '${match[1]},',
        );
  }

  void _showDeleteDialog(ProductDatabaseItem item) {
    _closeKeyboard();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('🗑️ حذف کالا'),
        content: Text('آیا از حذف کالا "${item.name}" مطمئن هستید؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              setState(() {
                _items.removeWhere((p) => p.barcode == item.barcode);
              });
              await widget.onItemDeleted(item);
              _notifyUpdate();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('✅ کالا "${item.name}" حذف شد')),
              );
            },
            child: const Text('حذف'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDeleteAllDialog() async {
    _closeKeyboard();
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('بانک اطلاعاتی خالی است')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('⚠️ حذف کل اطلاعات'),
        content: Text(
            'تمام ${_items.length} کالای بانک اطلاعاتی به سطل زباله منتقل می‌شوند. ادامه می‌دهید؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('انصراف')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('انتقال به سطل زباله'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final deleted = List<ProductDatabaseItem>.from(_items);
    setState(() {
      _items.clear();
      _customFolders.clear();
    });
    await _saveFolders();
    await widget.onDeleteAll(deleted);
    _notifyUpdate();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('کل اطلاعات بانک به سطل زباله منتقل شد 🗑️')));
  }

  void _showNewFolderDialog() {
    _closeKeyboard();
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('📁 ایجاد پوشه جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'نام پوشه',
            hintText: 'مثلاً نوشیدنی‌ها',
            prefixIcon: const Icon(Icons.folder_outlined),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              if (_folders.contains(name)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('این پوشه از قبل وجود دارد')),
                );
                return;
              }
              setState(() {
                _customFolders = [..._customFolders, name];
                _newItemFolder = name;
                _selectedFolder = name;
              });
              _saveFolders();
              Navigator.pop(context);
            },
            child: const Text('ایجاد'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  void _showGuideDialog() {
    _closeKeyboard();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.help_outline, color: Colors.blue),
            SizedBox(width: 8),
            Expanded(child: Text('راهنمای فایل ورودی')),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ساختار اکسل باید به این ترتیب باشد:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 10),
              Text('A: شماره بارکد'),
              Text('B: نام کالا'),
              Text('C: تعداد موجودی'),
              Text('D: قیمت خرید (ریال)'),
              Text('E: قیمت فروش (ریال)'),
              Text('F: نام گروه'),
              SizedBox(height: 12),
              Text(
                'ستون F نام گروه کالا است و کالاها بر اساس آن گروه‌بندی می‌شوند.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('متوجه شدم'),
          ),
        ],
      ),
    );
  }

  Future<void> _importExcel() async {
    try {
      _closeKeyboard();
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );

      if (result == null || result.files.single.path == null) return;

      setState(() => _isLoading = true);

      final bytes = File(result.files.single.path!).readAsBytesSync();
      final excel = excel_lib.Excel.decodeBytes(bytes);
      int addedCount = 0;
      int updatedCount = 0;

      // بانک فعلی را بر اساس بارکد ایندکس می‌کنیم تا وارد کردن بانک جدید
      // باعث ایجاد کالای تکراری نشود.
      final existingByBarcode = <String, int>{};
      for (var i = 0; i < _items.length; i++) {
        final barcode = _items[i].barcode.trim();
        if (barcode.isNotEmpty) existingByBarcode[barcode] = i;
      }

      for (var table in excel.tables.keys) {
        final rows = excel.tables[table]?.rows;
        if (rows == null) continue;

        for (final row in rows) {
          if (row.length < 6) continue;

          final col0 = row[0]?.value?.toString().trim() ?? '';
          final col1 = row[1]?.value?.toString().trim() ?? '';
          final groupName = row[5]?.value?.toString().trim() ?? '';

          if (col0.isEmpty && col1.isEmpty) continue;
          if (col0.contains('بارکد') || col1.contains('نام')) continue;

          final stock = int.tryParse(row[2]?.value?.toString() ?? '0') ?? 0;
          final buyPrice = int.tryParse(
                  row[3]?.value?.toString().replaceAll(',', '') ?? '0') ??
              0;
          final sellPrice = int.tryParse(
                  row[4]?.value?.toString().replaceAll(',', '') ?? '0') ??
              0;

          if (col1.isEmpty) continue;

          final barcode = col0;
          final group = groupName.isEmpty ? 'عمومی' : groupName;

          if (barcode.isNotEmpty && existingByBarcode.containsKey(barcode)) {
            // بارکد قبلاً در بانک وجود داشته است: نام، گروه و تنظیمات
            // مدیریتی قبلی حفظ می‌شوند و فقط موجودی و قیمت‌ها به‌روز می‌شوند.
            final index = existingByBarcode[barcode]!;
            final old = _items[index];
            _items[index] = old.copyWith(
              stock: stock,
              buyPrice: buyPrice,
              sellPrice: sellPrice,
            );
            updatedCount++;
          } else {
            // بارکد جدید است و وارد چرخه سه‌نوبتی «کالاهای جدید» می‌شود.
            final item = ProductDatabaseItem(
              barcode: barcode,
              name: col1,
              stock: stock,
              buyPrice: buyPrice,
              sellPrice: sellPrice,
              folder: 'عمومی',
              groupName: group,
              isNewProduct: true,
              newProductBankAppearances: 0,
            );
            _items.add(item);
            if (barcode.isNotEmpty) {
              existingByBarcode[barcode] = _items.length - 1;
            }
            addedCount++;
          }
        }
      }

      setState(() => _isLoading = false);
      _notifyUpdate();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$addedCount کالای جدید اضافه شد و $updatedCount کالای قبلی بر اساس بارکد به‌روزرسانی شد ✅',
          ),
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('خطا در خواندن فایل اکسل ❌')),
      );
    }
  }

  Future<void> _importPdf() async {
    try {
      _closeKeyboard();
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (result == null || result.files.single.path == null) return;
      _showSnackbar('⚠️ قابلیت وارد کردن PDF به زودی اضافه می‌شود');
    } catch (e) {
      _showSnackbar('❌ خطا در خواندن فایل PDF');
    }
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showAddManualDialog() {
    _closeKeyboard();
    final barcodeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final stockCtrl = TextEditingController();
    final buyCtrl = TextEditingController();
    final sellCtrl = TextEditingController();
    final groupCtrl = TextEditingController(text: 'عمومی');
    final formKey = GlobalKey<FormState>();
    var folder = _newItemFolder;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('➕ افزودن کالا به بانک'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: barcodeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'شماره بارکد',
                      prefixIcon: Icon(Icons.qr_code_2),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'نام کالا',
                      prefixIcon: Icon(Icons.inventory_2_outlined),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'نام کالا الزامی است'
                        : null,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _folders.contains(folder) ? folder : 'عمومی',
                    decoration: const InputDecoration(
                      labelText: 'پوشه کالا',
                      prefixIcon: Icon(Icons.folder_outlined),
                    ),
                    items: _folders
                        .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => folder = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: groupCtrl,
                    decoration: const InputDecoration(
                      labelText: 'نام گروه کالا',
                      prefixIcon: Icon(Icons.category_outlined),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'نام گروه الزامی است'
                        : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: stockCtrl,
                    decoration:
                        const InputDecoration(labelText: 'تعداد موجودی'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: buyCtrl,
                    decoration:
                        const InputDecoration(labelText: 'قیمت خرید (ریال)'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: sellCtrl,
                    decoration:
                        const InputDecoration(labelText: 'قیمت فروش (ریال)'),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: const Text('ثبت'),
              onPressed: () {
                if (!formKey.currentState!.validate()) return;

                setState(() {
                  _items.add(ProductDatabaseItem(
                    barcode: barcodeCtrl.text.trim(),
                    name: nameCtrl.text.trim(),
                    stock: int.tryParse(stockCtrl.text) ?? 0,
                    buyPrice:
                        int.tryParse(buyCtrl.text.replaceAll(',', '')) ?? 0,
                    sellPrice:
                        int.tryParse(sellCtrl.text.replaceAll(',', '')) ?? 0,
                    folder: folder,
                    groupName: groupCtrl.text.trim().isEmpty
                        ? 'عمومی'
                        : groupCtrl.text.trim(),
                    isNewProduct: true,
                  ));
                  _newItemFolder = folder;
                });

                _notifyUpdate();
                Navigator.pop(dialogContext);
                _showSnackbar('✅ کالا در پوشه «$folder» ثبت شد');
              },
            ),
          ],
        ),
      ),
    ).then((_) {
      barcodeCtrl.dispose();
      nameCtrl.dispose();
      stockCtrl.dispose();
      buyCtrl.dispose();
      sellCtrl.dispose();
      groupCtrl.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleItems;

    return Scaffold(
      appBar: AppBar(
        title: const Text('🗄️ بانک اطلاعاتی کالاها'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'پوشه جدید',
            onPressed: _showNewFolderDialog,
          ),
          IconButton(
            icon: const Icon(Icons.help_outline, color: Colors.white),
            tooltip: 'راهنمای ستون‌ها',
            onPressed: _showGuideDialog,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'حذف کل اطلاعات',
            onPressed: _showDeleteAllDialog,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'افزودن دستی',
            onPressed: _showAddManualDialog,
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _closeKeyboard,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withOpacity(.65),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size.fromHeight(52),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: const Icon(Icons.table_chart_outlined),
                                label: const Text('ورود اکسل'),
                                onPressed: _importExcel,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: Colors.red.shade50,
                                  foregroundColor: Colors.red.shade700,
                                  side: BorderSide(color: Colors.red.shade200),
                                  minimumSize: const Size.fromHeight(52),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: const Icon(Icons.picture_as_pdf),
                                label: const Text('ورود PDF'),
                                onPressed: _importPdf,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            'پوشه‌ها',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 7),
                        SizedBox(
                          height: 42,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              _folderChip('همه'),
                              ..._folders.map(_folderChip),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.folder_open_outlined,
                                    size: 64, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text(
                                  _selectedFolder == 'همه'
                                      ? 'بانک اطلاعاتی خالی است'
                                      : 'این پوشه خالی است',
                                ),
                                const SizedBox(height: 8),
                                ElevatedButton.icon(
                                  onPressed: _showAddManualDialog,
                                  icon: const Icon(Icons.add),
                                  label: const Text('افزودن کالا'),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(12),
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final item = visible[index];
                              return Card(
                                color: item.isPriceModified
                                    ? Colors.yellow.shade100
                                    : null,
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      CircleAvatar(
                                        backgroundColor:
                                            Colors.deepPurple.shade50,
                                        child: const Icon(
                                            Icons.inventory_2_outlined),
                                      ),
                                      if (item.isNewProduct)
                                        const Positioned(
                                          right: -4,
                                          top: -7,
                                          child: Icon(Icons.star,
                                              color: Colors.amber, size: 20),
                                        ),
                                    ],
                                  ),
                                  title: Row(
                                    children: [
                                      Expanded(
                                          child: Text(item.name,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.bold))),
                                      if (item.isNewProduct)
                                        const Text('جدید',
                                            style: TextStyle(
                                                color: Colors.amber,
                                                fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  subtitle: Text(
                                    'گروه: ${item.groupName}\n'
                                    'پوشه: ${item.folder}\n'
                                    'بارکد: ${item.barcode.isEmpty ? "ندارد" : item.barcode}\n'
                                    'موجودی: ${item.stock} | خرید: ${_formatPrice(item.buyPrice)} ریال',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        '${_formatPrice(item.sellPrice)} ریال',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.green,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            color: Colors.red, size: 20),
                                        onPressed: () =>
                                            _showDeleteDialog(item),
                                        tooltip: 'حذف کالا',
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _folderChip(String folder) {
    final selected = _selectedFolder == folder;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: ChoiceChip(
        selected: selected,
        label: Text(folder == 'همه' ? 'همه کالاها' : '📁 $folder'),
        onSelected: (_) {
          setState(() {
            _selectedFolder = folder;
            if (folder != 'همه') _newItemFolder = folder;
          });
        },
      ),
    );
  }
}

// ==================== اسکنر بارکد ====================

class InventoryCountScreen extends StatefulWidget {
  final List<ProductDatabaseItem> products;
  final List<InventoryCountEntry> entries;
  final Future<void> Function(List<InventoryCountEntry>) onChanged;

  const InventoryCountScreen({
    super.key,
    required this.products,
    required this.entries,
    required this.onChanged,
  });

  @override
  State<InventoryCountScreen> createState() => _InventoryCountScreenState();
}

class _InventoryCountScreenState extends State<InventoryCountScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Map<String, TextEditingController> _actualControllers = {};
  late List<InventoryCountEntry> _entries;
  List<ProductDatabaseItem> _results = [];

  @override
  void initState() {
    super.initState();
    _entries = List<InventoryCountEntry>.from(widget.entries);
    _results = List<ProductDatabaseItem>.from(widget.products);
    for (final entry in _entries) {
      _actualControllers[entry.barcode] = TextEditingController(
        text: entry.actualStock.toString(),
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (final controller in _actualControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _search(String value) {
    final q = _normalizeSearchText(value);
    setState(() {
      _results = q.isEmpty
          ? List<ProductDatabaseItem>.from(widget.products)
          : widget.products
              .where((p) =>
                  _normalizeSearchText(p.name).contains(q) ||
                  p.barcode.contains(q))
              .toList();
    });
  }

  Future<void> _scan() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()),
    );
    if (!mounted || result == null || result.isEmpty) return;
    _searchController.text = result;
    _search(result);
    final product = widget.products.cast<ProductDatabaseItem?>().firstWhere(
          (p) => p!.barcode == result,
          orElse: () => null,
        );
    if (product != null) _addProduct(product);
  }

  void _addProduct(ProductDatabaseItem product) {
    if (_entries.any((e) => e.barcode == product.barcode)) {
      _showMessage('این کالا قبلاً به لیست انبارگردانی اضافه شده است.');
      return;
    }
    setState(() {
      _entries.add(InventoryCountEntry(
        id: '${DateTime.now().microsecondsSinceEpoch}-${product.barcode}',
        barcode: product.barcode,
        name: product.name,
        systemStock: product.stock,
        actualStock: product.stock,
        date: _todayJalali(),
      ));
      _actualControllers[product.barcode] =
          TextEditingController(text: product.stock.toString());
      _searchController.clear();
      _results = List<ProductDatabaseItem>.from(widget.products);
    });
  }

  Future<void> _finalize() async {
    final updated = <InventoryCountEntry>[];
    for (final entry in _entries) {
      final value = int.tryParse(
            _actualControllers[entry.barcode]?.text.replaceAll(',', '') ?? '',
          ) ??
          0;
      updated.add(InventoryCountEntry(
        id: entry.id,
        barcode: entry.barcode,
        name: entry.name,
        systemStock: entry.systemStock,
        actualStock: value,
        date: entry.date,
      ));
    }
    await widget.onChanged(updated);
    if (!mounted) return;
    setState(() => _entries = updated);
    _showMessage('انبارگردانی با موفقیت ثبت نهایی شد ✅');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📦 انبارگردانی'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.assessment_outlined),
            tooltip: 'گزارش انبارگردانی',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => InventoryReportScreen(entries: _entries),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _search,
                    decoration: InputDecoration(
                      labelText: 'جستجوی کالا یا بارکد',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: IconButton(
                    onPressed: _scan,
                    icon:
                        const Icon(Icons.qr_code_scanner, color: Colors.white),
                    tooltip: 'اسکن بارکد',
                  ),
                ),
              ],
            ),
          ),
          if (_searchController.text.isNotEmpty)
            SizedBox(
              height: 145,
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (_, index) {
                  final product = _results[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Text(product.name),
                    subtitle: Text(
                        'بارکد: ${product.barcode} | موجودی سیستمی: ${product.stock}'),
                    trailing: const Icon(Icons.add_circle_outline),
                    onTap: () => _addProduct(product),
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(
              children: [
                const Expanded(
                  child: Text('اقلام انبارگردانی',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                ),
                Text('${_entries.length} کالا'),
              ],
            ),
          ),
          Expanded(
            child: _entries.isEmpty
                ? const Center(
                    child: Text(
                        'برای شروع، کالا را جستجو یا بارکد آن را اسکن کنید.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _entries.length,
                    itemBuilder: (_, index) {
                      final entry = _entries[index];
                      final actualController =
                          _actualControllers[entry.barcode]!;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(entry.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16)),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      setState(() {
                                        _actualControllers
                                            .remove(entry.barcode)
                                            ?.dispose();
                                        _entries.removeAt(index);
                                      });
                                    },
                                    icon: const Icon(Icons.delete_outline,
                                        color: Colors.red),
                                  ),
                                ],
                              ),
                              Text('بارکد: ${entry.barcode}'),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: InputDecorator(
                                      decoration: const InputDecoration(
                                          labelText: 'موجودی سیستمی',
                                          border: OutlineInputBorder()),
                                      child: Text(
                                          _toPersianDigits(
                                              entry.systemStock.toString()),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: actualController,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                          labelText: 'موجودی واقعی',
                                          border: OutlineInputBorder()),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _entries.isEmpty ? null : _finalize,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('ثبت نهایی انبارگردانی'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _entries.isEmpty
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    InventoryReportScreen(entries: _entries),
                              ),
                            ),
                    icon: const Icon(Icons.assessment_outlined),
                    tooltip: 'گزارش انبارگردانی',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class InventoryReportScreen extends StatelessWidget {
  final List<InventoryCountEntry> entries;

  const InventoryReportScreen({super.key, required this.entries});

  /// ساخت و اشتراک‌گذاری گزارش PDF انبارگردانی.
  ///
  /// نکته مهم: متن فارسی این گزارش عمداً دوباره با ArabicReshaper
  /// پردازش نمی‌شود؛ چون PDF با textDirection: rtl خودش شکل‌دهی حروف
  /// فارسی/عربی را انجام می‌دهد. همچنین از ایموجی در PDF استفاده نمی‌کنیم
  /// تا کاراکترهای ناشناخته (�) در بعضی گوشی‌ها ایجاد نشود.
  Future<void> _shareInventoryReport(BuildContext context) async {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('هنوز گزارشی برای اشتراک‌گذاری وجود ندارد.')),
      );
      return;
    }

    try {
      final font = await _loadFont();
      final pdf = pw.Document();

      final mismatches = entries.where((e) => e.difference != 0).toList();
      final shortage = mismatches
          .where((e) => e.difference < 0)
          .fold<int>(0, (sum, e) => sum + e.difference.abs());
      final surplus = mismatches
          .where((e) => e.difference > 0)
          .fold<int>(0, (sum, e) => sum + e.difference);

      final reportDate = entries.map((e) => e.date.trim()).firstWhere(
            (date) => date.isNotEmpty,
            orElse: _todayJalali,
          );

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(24, 28, 24, 28),
          textDirection: pw.TextDirection.rtl,
          maxPages: 100,
          header: (context) => pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 10),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _pdfShareTextWidget(
                  'گزارش انبارگردانی',
                  font,
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.green,
                ),
                _pdfShareTextWidget(
                  'تاریخ: $reportDate',
                  font,
                  fontSize: 9,
                  color: PdfColors.grey700,
                ),
              ],
            ),
          ),
          footer: (context) => pw.Align(
            alignment: pw.Alignment.center,
            child: _pdfShareTextWidget(
              'صفحه ${context.pageNumber} از ${context.pagesCount}',
              font,
              fontSize: 8,
              color: PdfColors.grey600,
            ),
          ),
          build: (context) => [
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  _inventoryPdfSummaryItem(
                    'کل اقلام',
                    _toPersianDigits(entries.length.toString()),
                    font,
                    PdfColors.black,
                  ),
                  _inventoryPdfSummaryItem(
                    'مغایرت',
                    _toPersianDigits(mismatches.length.toString()),
                    font,
                    PdfColors.red,
                  ),
                  _inventoryPdfSummaryItem(
                    'کسری',
                    _toPersianDigits(shortage.toString()),
                    font,
                    PdfColors.red,
                  ),
                  _inventoryPdfSummaryItem(
                    'اضافی',
                    _toPersianDigits(surplus.toString()),
                    font,
                    PdfColors.green,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 18),
            _pdfShareTextWidget(
              'جزئیات شمارش کالاها',
              font,
              fontSize: 15,
              fontWeight: pw.FontWeight.bold,
              textAlign: pw.TextAlign.right,
            ),
            pw.SizedBox(height: 8),
            pw.Table(
              border: pw.TableBorder.all(
                color: PdfColors.grey600,
                width: 0.7,
              ),
              tableWidth: pw.TableWidth.max,
              columnWidths: const {
                0: pw.FlexColumnWidth(0.55),
                1: pw.FlexColumnWidth(2.55),
                2: pw.FlexColumnWidth(1.35),
                3: pw.FlexColumnWidth(1.15),
                4: pw.FlexColumnWidth(1.15),
                5: pw.FlexColumnWidth(1.05),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.green100),
                  children: [
                    _pdfShareCell('ردیف', font, bold: true, fontSize: 8.5),
                    _pdfShareCell('نام کالا', font, bold: true, fontSize: 8.5),
                    _pdfShareCell('بارکد', font, bold: true, fontSize: 8.5),
                    _pdfShareCell('موجودی سیستمی', font,
                        bold: true, fontSize: 8.2),
                    _pdfShareCell('موجودی واقعی', font,
                        bold: true, fontSize: 8.2),
                    _pdfShareCell('مغایرت', font, bold: true, fontSize: 8.5),
                  ],
                ),
                ...entries.asMap().entries.map((item) {
                  final index = item.key + 1;
                  final entry = item.value;
                  final difference = entry.difference > 0
                      ? '+${entry.difference}'
                      : '${entry.difference}';

                  return pw.TableRow(
                    children: [
                      _pdfShareCell(
                        _toPersianDigits(index.toString()),
                        font,
                        fontSize: 8.5,
                      ),
                      _pdfShareCell(
                        entry.name.trim().isEmpty
                            ? 'بدون نام'
                            : entry.name.trim(),
                        font,
                        align: pw.TextAlign.right,
                        fontSize: 8.5,
                      ),
                      _pdfShareCell(
                        _toPersianDigits(entry.barcode),
                        font,
                        fontSize: 8,
                      ),
                      _pdfShareCell(
                        _toPersianDigits(entry.systemStock.toString()),
                        font,
                        fontSize: 8.5,
                      ),
                      _pdfShareCell(
                        _toPersianDigits(entry.actualStock.toString()),
                        font,
                        fontSize: 8.5,
                      ),
                      _pdfShareCell(
                        _toPersianDigits(difference),
                        font,
                        fontSize: 8.5,
                      ),
                    ],
                  );
                }),
              ],
            ),
            pw.SizedBox(height: 16),
            if (mismatches.isEmpty)
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.green),
                  borderRadius: pw.BorderRadius.circular(5),
                ),
                child: _pdfShareTextWidget(
                  'هیچ مغایرتی بین موجودی سیستمی و موجودی واقعی ثبت نشده است.',
                  font,
                  fontSize: 9.5,
                  textAlign: pw.TextAlign.right,
                ),
              )
            else
              _pdfShareTextWidget(
                'تعداد اقلام دارای مغایرت: ${_toPersianDigits(mismatches.length.toString())}',
                font,
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.red,
                textAlign: pw.TextAlign.right,
              ),
          ],
        ),
      );

      final bytes = await pdf.save();
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/inventory_report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf')],
        text:
            'گزارش انبارگردانی\nتعداد اقلام: ${_toPersianDigits(entries.length.toString())}\nتاریخ: $reportDate',
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطا در تهیه گزارش انبارگردانی: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  pw.Widget _inventoryPdfSummaryItem(
    String title,
    String value,
    pw.Font font,
    PdfColor color,
  ) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        _pdfShareTextWidget(
          value,
          font,
          fontSize: 14,
          fontWeight: pw.FontWeight.bold,
          color: color,
          textAlign: pw.TextAlign.center,
        ),
        pw.SizedBox(height: 3),
        _pdfShareTextWidget(
          title,
          font,
          fontSize: 8.5,
          color: PdfColors.grey700,
          textAlign: pw.TextAlign.center,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mismatches = entries.where((e) => e.difference != 0).toList();
    final shortage = mismatches
        .where((e) => e.difference < 0)
        .fold<int>(0, (sum, e) => sum + e.difference.abs());
    final surplus = mismatches
        .where((e) => e.difference > 0)
        .fold<int>(0, (sum, e) => sum + e.difference);

    return Scaffold(
      appBar: AppBar(
        title: const Text('📊 گزارش انبارگردانی'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed:
                entries.isEmpty ? null : () => _shareInventoryReport(context),
            icon: const Icon(Icons.share_outlined),
            tooltip: 'اشتراک‌گذاری گزارش انبارگردانی',
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text('هنوز گزارشی از انبارگردانی ثبت نشده است.'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _summary('کل اقلام', '${entries.length}',
                                Colors.black87),
                            _summary(
                                'مغایرت', '${mismatches.length}', Colors.red),
                            _summary(
                                'کسری',
                                _toPersianDigits(shortage.toString()),
                                Colors.red),
                            _summary(
                                'اضافی',
                                _toPersianDigits(surplus.toString()),
                                Colors.green),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text('تاریخ گزارش: ${entries.last.date}',
                              style: const TextStyle(color: Colors.grey)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (mismatches.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(
                          child: Text(
                              'مغایرتی بین موجودی سیستمی و واقعی پیدا نشد ✅')),
                    ),
                  )
                else
                  ...mismatches.map(
                    (entry) => Card(
                      margin: const EdgeInsets.only(bottom: 9),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(entry.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text('بارکد: ${entry.barcode}'),
                            const Divider(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                    'سیستمی: ${_toPersianDigits(entry.systemStock.toString())}'),
                                Text(
                                    'واقعی: ${_toPersianDigits(entry.actualStock.toString())}'),
                                Text(
                                  'مغایرت: ${entry.difference > 0 ? '+' : ''}${_toPersianDigits(entry.difference.toString())}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: entry.difference > 0
                                        ? Colors.green
                                        : Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: entries.isEmpty
                        ? null
                        : () => _shareInventoryReport(context),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('اشتراک‌گذاری گزارش انبارگردانی'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _summary(String title, String value, Color color) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 11)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.bold, color: color, fontSize: 16)),
      ],
    );
  }
}

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleBarcode(BarcodeCapture capture) {
    if (_scanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;

      if (value != null && value.isNotEmpty) {
        _scanned = true;
        _controller.stop();

        Navigator.pop(context, value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('اسکن بارکد'),
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _handleBarcode,
          ),
          Center(
            child: Container(
              width: 280,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 50,
            child: Text(
              'بارکد را داخل کادر قرار دهید',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== مدل‌های داده ====================

class AppMessage {
  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool isRead;

  const AppMessage(
      {required this.id,
      required this.title,
      required this.body,
      required this.createdAt,
      this.isRead = false});

  AppMessage copyWith({bool? isRead}) => AppMessage(
      id: id,
      title: title,
      body: body,
      createdAt: createdAt,
      isRead: isRead ?? this.isRead);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
        'isRead': isRead
      };

  factory AppMessage.fromJson(Map<String, dynamic> json) => AppMessage(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? 'پیام',
        body: json['body']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        isRead: json['isRead'] == true,
      );
}

class CustomEvent {
  final String id;
  final String name;
  final String isoDate;

  CustomEvent({required this.id, required this.name, required this.isoDate});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'isoDate': isoDate};

  factory CustomEvent.fromJson(Map<String, dynamic> json) => CustomEvent(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        isoDate:
            json['isoDate']?.toString() ?? DateTime.now().toIso8601String(),
      );
}

class DailyExpense {
  final String id;
  final String name;
  final int amount;
  final String date;

  DailyExpense({
    required this.id,
    required this.name,
    required this.amount,
    required this.date,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'amount': amount,
        'date': date,
      };

  factory DailyExpense.fromJson(Map<String, dynamic> json) => DailyExpense(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        amount: json['amount'] is int
            ? json['amount'] as int
            : int.tryParse('${json['amount']}') ?? 0,
        date: json['date']?.toString() ?? '',
      );
}

class InventoryCountEntry {
  final String id;
  final String barcode;
  final String name;
  final int systemStock;
  final int actualStock;
  final String date;

  InventoryCountEntry({
    required this.id,
    required this.barcode,
    required this.name,
    required this.systemStock,
    required this.actualStock,
    required this.date,
  });

  int get difference => actualStock - systemStock;

  Map<String, dynamic> toJson() => {
        'id': id,
        'barcode': barcode,
        'name': name,
        'systemStock': systemStock,
        'actualStock': actualStock,
        'date': date,
      };

  factory InventoryCountEntry.fromJson(Map<String, dynamic> json) =>
      InventoryCountEntry(
        id: json['id']?.toString() ?? '',
        barcode: json['barcode']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        systemStock: (json['systemStock'] ?? 0) is int
            ? json['systemStock'] as int
            : int.tryParse('${json['systemStock']}') ?? 0,
        actualStock: (json['actualStock'] ?? 0) is int
            ? json['actualStock'] as int
            : int.tryParse('${json['actualStock']}') ?? 0,
        date: json['date']?.toString() ?? '',
      );
}

class TrashItem {
  final String id;
  final String type;
  final String title;
  final int deletedAt;
  final Map<String, dynamic> data;

  TrashItem({
    required this.id,
    required this.type,
    required this.title,
    required this.deletedAt,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'deletedAt': deletedAt,
        'data': data,
      };

  factory TrashItem.fromJson(Map<String, dynamic> json) => TrashItem(
        id: json['id']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
        title: json['title']?.toString() ?? 'مورد حذف‌شده',
        deletedAt: json['deletedAt'] ?? 0,
        data: Map<String, dynamic>.from(json['data'] ?? {}),
      );
}

class ProductDatabaseItem {
  final String barcode;
  final String name;
  final int stock;
  final int buyPrice;
  final int sellPrice;
  final String folder;
  final String groupName;
  final bool isPriceModified;
  final int? originalSellPrice;
  final bool isNewProduct;
  // تعداد دفعاتی که این بارکد از زمان ورود به بانک جدید دیده شده است.
  // 1، 2 و 3 یعنی کالا در گروه «کالاهای جدید» باقی می‌ماند؛ از نوبت چهارم خارج می‌شود.
  final int newProductBankAppearances;

  ProductDatabaseItem({
    required this.barcode,
    required this.name,
    required this.stock,
    required this.buyPrice,
    required this.sellPrice,
    this.folder = 'عمومی',
    this.groupName = 'عمومی',
    this.isPriceModified = false,
    this.originalSellPrice,
    this.isNewProduct = false,
    this.newProductBankAppearances = 0,
  });

  ProductDatabaseItem copyWith({
    String? barcode,
    String? name,
    int? stock,
    int? buyPrice,
    int? sellPrice,
    String? folder,
    String? groupName,
    bool? isPriceModified,
    int? originalSellPrice,
    bool? isNewProduct,
    int? newProductBankAppearances,
  }) =>
      ProductDatabaseItem(
        barcode: barcode ?? this.barcode,
        name: name ?? this.name,
        stock: stock ?? this.stock,
        buyPrice: buyPrice ?? this.buyPrice,
        sellPrice: sellPrice ?? this.sellPrice,
        folder: folder ?? this.folder,
        groupName: groupName ?? this.groupName,
        isPriceModified: isPriceModified ?? this.isPriceModified,
        originalSellPrice: originalSellPrice ?? this.originalSellPrice,
        isNewProduct: isNewProduct ?? this.isNewProduct,
        newProductBankAppearances:
            newProductBankAppearances ?? this.newProductBankAppearances,
      );

  Map<String, dynamic> toJson() => {
        'barcode': barcode,
        'name': name,
        'stock': stock,
        'buyPrice': buyPrice,
        'sellPrice': sellPrice,
        'folder': folder,
        'groupName': groupName,
        'isPriceModified': isPriceModified,
        'originalSellPrice': originalSellPrice,
        'isNewProduct': isNewProduct,
        'newProductBankAppearances': newProductBankAppearances,
      };

  factory ProductDatabaseItem.fromJson(Map<String, dynamic> json) =>
      ProductDatabaseItem(
        barcode: json['barcode'] ?? '',
        name: json['name'] ?? '',
        stock: json['stock'] ?? 0,
        buyPrice: json['buyPrice'] ?? 0,
        sellPrice: json['sellPrice'] ?? 0,
        folder: (json['folder'] ?? 'عمومی').toString(),
        groupName: (json['groupName'] ?? json['folder'] ?? 'عمومی').toString(),
        isPriceModified: json['isPriceModified'] == true,
        isNewProduct: json['isNewProduct'] == true,
        newProductBankAppearances: json['newProductBankAppearances'] is num
            ? (json['newProductBankAppearances'] as num)
                .toInt()
                .clamp(0, 4)
                .toInt()
            : 0,
        originalSellPrice: json['originalSellPrice'] is num
            ? (json['originalSellPrice'] as num).toInt()
            : null,
      );
}

class DeliveryItem {
  final String name;
  final int quantity;
  final int realQuantity;
  final int purchasePrice;
  final String barcode;
  final String date;
  final String unit;
  final int packageSize;

  DeliveryItem({
    required this.name,
    required this.quantity,
    required this.realQuantity,
    required this.purchasePrice,
    required this.barcode,
    required this.date,
    required this.unit,
    required this.packageSize,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'quantity': quantity,
        'realQuantity': realQuantity,
        'purchasePrice': purchasePrice,
        'barcode': barcode,
        'date': date,
        'unit': unit,
        'packageSize': packageSize,
      };

  factory DeliveryItem.fromJson(Map<String, dynamic> json) => DeliveryItem(
        name: json['name'],
        quantity: json['quantity'],
        realQuantity: json['realQuantity'] ?? json['quantity'],
        purchasePrice: json['purchasePrice'] ?? 0,
        barcode: json['barcode'],
        date: json['date'],
        unit: json['unit'] ?? 'عدد',
        packageSize: json['packageSize'] ?? 0,
      );
}

class DeliveryManifest {
  String id;
  int number;
  String date;
  List<DeliveryItem> items;
  int totalPrice;
  int freightCost;
  String senderCompany;
  String createdAt;

  DeliveryManifest({
    required this.id,
    required this.number,
    required this.date,
    required this.items,
    required this.totalPrice,
    this.freightCost = 0,
    this.senderCompany = '',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'date': date,
        'items': items.map((item) => item.toJson()).toList(),
        'totalPrice': totalPrice,
        'freightCost': freightCost,
        'senderCompany': senderCompany,
        'createdAt': createdAt,
      };

  factory DeliveryManifest.fromJson(Map<String, dynamic> json) {
    final itemsList = (json['items'] as List)
        .map((item) => DeliveryItem.fromJson(item))
        .toList();
    return DeliveryManifest(
      id: json['id'],
      number: json['number'] ?? 0,
      date: json['date'],
      items: itemsList,
      totalPrice: json['totalPrice'] ?? 0,
      freightCost: json['freightCost'] ?? 0,
      senderCompany: json['senderCompany'] ?? '',
      createdAt: json['createdAt'],
    );
  }
}

class SalesInvoice {
  final String id;
  final int number;
  final String productName;
  final String barcode;
  final int price;
  final int quantity;
  final int totalPrice;
  final int discount;
  final String customerName;
  final String customerPhone;
  final bool isCredit;
  final String date;
  final String createdAt;

  SalesInvoice({
    required this.id,
    required this.number,
    required this.productName,
    required this.barcode,
    required this.price,
    required this.quantity,
    required this.totalPrice,
    this.discount = 0,
    required this.customerName,
    required this.customerPhone,
    required this.isCredit,
    required this.date,
    required this.createdAt,
  });

  SalesInvoice copyWith({int? number}) => SalesInvoice(
        id: id,
        number: number ?? this.number,
        productName: productName,
        barcode: barcode,
        price: price,
        quantity: quantity,
        totalPrice: totalPrice,
        discount: discount,
        customerName: customerName,
        customerPhone: customerPhone,
        isCredit: isCredit,
        date: date,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'productName': productName,
        'barcode': barcode,
        'price': price,
        'quantity': quantity,
        'totalPrice': totalPrice,
        'discount': discount,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'isCredit': isCredit,
        'date': date,
        'createdAt': createdAt,
      };

  factory SalesInvoice.fromJson(Map<String, dynamic> json) => SalesInvoice(
        id: json['id'],
        number: json['number'] ?? 0,
        productName: json['productName'] ?? '',
        barcode: json['barcode'] ?? '',
        price: json['price'] ?? 0,
        quantity: json['quantity'] ?? 0,
        totalPrice: json['totalPrice'] ?? 0,
        discount: json['discount'] ?? 0,
        customerName: json['customerName'] ?? '',
        customerPhone: json['customerPhone'] ?? '',
        isCredit: json['isCredit'] ?? false,
        date: json['date'] ?? '',
        createdAt: json['createdAt'] ?? '',
      );
}

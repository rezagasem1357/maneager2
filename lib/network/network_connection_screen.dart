import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network_service.dart';

class NetworkConnectionScreen extends StatefulWidget {
  const NetworkConnectionScreen({super.key});

  @override
  State<NetworkConnectionScreen> createState() => _NetworkConnectionScreenState();
}

class _NetworkConnectionScreenState extends State<NetworkConnectionScreen> {
  final _service = NetworkService();
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _storeCtrl = TextEditingController(text: 'store-1');
  bool _autoSync = true;
  static const String _role = 'manager';
  bool _loading = false;
  bool _online = false;
  int _pending = 0;
  DateTime? _lastSync;
  String _status = 'برای شروع، تنظیمات سرور را وارد کنید.';
  String _license = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await _service.loadConfig();
    final p = await _service.pendingCount();
    final last = await _service.lastSync();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = c.baseUrl;
      _keyCtrl.text = c.anonKey;
      _storeCtrl.text = c.storeId;
      _autoSync = c.autoSync;
      _pending = p;
      _lastSync = last;
      _license = c.license;
    });
    await _refreshStatus();
    if (_autoSync) _startAutoSync();
  }

  void _startAutoSync() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted) return;
      await _sync();
    });
  }

  Future<void> _refreshStatus() async {
    final online = await _service.isOnline();
    if (mounted) setState(() => _online = online);
  }

  Future<void> _saveSettings() async {
    await _service.saveConfig(
      baseUrl: _urlCtrl.text,
      anonKey: _keyCtrl.text,
      storeId: _storeCtrl.text,
      role: _role,
      autoSync: _autoSync,
    );
    if (_autoSync) {
      _startAutoSync();
    } else {
      _timer?.cancel();
    }
  }

  bool _checkLicense() {
    if (_license.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لایسنس این دستگاه یافت نشد. ابتدا باید از صفحه ورود با لایسنس معتبر وارد شوید.'),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
    return true;
  }

  Future<void> _test() async {
    if (!_checkLicense()) return;
    setState(() {
      _loading = true;
      _status = 'در حال آزمایش اتصال...';
    });
    await _saveSettings();
    final result = await _service.testConnection();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _status = result.message;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _sync() async {
    if (_loading) return;
    if (!_checkLicense()) return;
    await _saveSettings();
    final result = await _service.syncOutbox();
    final p = await _service.pendingCount();
    final last = await _service.lastSync();
    if (!mounted) return;
    setState(() {
      _pending = p;
      _lastSync = last;
      _status = result.message;
    });
  }

  Future<void> _downloadProductDatabase() async {
    if (!_checkLicense()) return;
    setState(() {
      _loading = true;
      _status = 'در حال دریافت بانک اطلاعاتی...';
    });
    await _saveSettings();
    final snapshot = await _service.downloadSnapshot();
    if (!mounted) return;
    setState(() => _loading = false);
    if (snapshot == null) {
      setState(() => _status = 'بانک اطلاعاتی مرکزی پیدا نشد یا اتصال برقرار نشد.');
      return;
    }
    final products = snapshot['product_database'];
    if (products is List) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('product_database', jsonEncode(products));
    }
    final info = await _service.fetchSnapshotInfo();
    if (info != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('database_update_seen_at', info.updatedAt);
      await prefs.setString('manager_message_read_id', 'database_update:${info.updatedAt}');
    }
    final last = await _service.lastSync();
    setState(() {
      _lastSync = last;
      _status = 'بانک اطلاعاتی از سرور دریافت و روی دستگاه ذخیره شد.';
    });
  }

  Future<void> _uploadProductDatabase() async {
    if (!_checkLicense()) return;
    setState(() {
      _loading = true;
      _status = 'در حال ارسال بانک اطلاعاتی...';
    });
    await _saveSettings();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('product_database') ?? '[]';

    // فقط «ارسال بانک» یک نوبت جدید برای تشخیص کالاهای تازه محسوب می‌شود.
    // بنابراین تغییر روزشمار، هزینه‌ها یا رویدادهای دیگر باعث جلو رفتن شمارنده
    // کالای جدید نمی‌شود.
    final oldSnapshot = await _service.downloadSnapshot();
    List<dynamic> products = [];
    try {
      products = jsonDecode(raw) as List<dynamic>;
    } catch (_) {}

    final oldProducts = oldSnapshot?['product_database'];
    final oldBarcodes = oldProducts is List
        ? oldProducts
            .whereType<Map>()
            .map((e) => e['barcode']?.toString().trim() ?? '')
            .where((e) => e.isNotEmpty)
            .toSet()
        : <String>{};

    // سابقهٔ ورود هر بارکد به بانک را روی دستگاه مدیر نگه می‌داریم تا اگر
    // کالایی مدتی حذف و بعد دوباره وارد شد، شمارش سه نوبت آن از بین نرود.
    Map<String, dynamic> history = {};
    try {
      final historyRaw = prefs.getString('product_new_appearance_history_v1');
      if (historyRaw != null && historyRaw.isNotEmpty) {
        history = Map<String, dynamic>.from(jsonDecode(historyRaw) as Map);
      }
    } catch (_) {
      history = {};
    }

    final normalizedProducts = <dynamic>[];
    for (final rawItem in products) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final barcode = item['barcode']?.toString().trim() ?? '';
      if (barcode.isEmpty) {
        // کالای بدون بارکد را وارد شمارش بارکد نمی‌کنیم.
        item['isNewProduct'] = item['isNewProduct'] == true;
        normalizedProducts.add(item);
        continue;
      }

      final historicalCount = (history[barcode] is num)
          ? (history[barcode] as num).toInt().clamp(0, 4).toInt()
          : ((item['newProductBankAppearances'] is num)
              ? (item['newProductBankAppearances'] as num).toInt().clamp(0, 4).toInt()
              : 0);

      int appearanceCount;
      if (oldBarcodes.contains(barcode)) {
        // بارکد قبلاً در بانک سرور بوده؛ کالای قدیمی فقط به‌روزرسانی می‌شود.
        // اگر هنوز در دوره سه‌نوبتی «جدید» است، یک نوبت دیگر جلو می‌رود.
        appearanceCount = historicalCount > 0
            ? (historicalCount + 1).clamp(1, 4).toInt()
            : 0;
      } else {
        // بارکد برای اولین بار در بانک سرور دیده می‌شود.
        appearanceCount = (historicalCount + 1).clamp(1, 4).toInt();
      }

      history[barcode] = appearanceCount;
      item['newProductBankAppearances'] = appearanceCount;
      item['isNewProduct'] = appearanceCount >= 1 && appearanceCount <= 3;
      normalizedProducts.add(item);
    }

    products = normalizedProducts;
    await prefs.setString('product_new_appearance_history_v1', jsonEncode(history));
    await prefs.setString('product_database', jsonEncode(products));

    final dailyExpensesRaw = prefs.getString('daily_expenses') ?? '[]';
    final customEventsRaw = prefs.getString('custom_events') ?? '[]';
    List<dynamic> dailyExpenses = [];
    List<dynamic> customEvents = [];
    try { dailyExpenses = jsonDecode(dailyExpensesRaw) as List<dynamic>; } catch (_) {}
    try { customEvents = jsonDecode(customEventsRaw) as List<dynamic>; } catch (_) {}
    final result = await _service.uploadSnapshot({
      'product_database': products,
      'daily_expenses': dailyExpenses,
      'custom_events': customEvents,
      'fixed_inventory_last_date_v2': prefs.getString('fixed_inventory_last_date_v2'),
      'fixed_cleaning_last_date_v1': prefs.getString('fixed_cleaning_last_date_v1'),
    }, actorName: _storeCtrl.text);
    final last = await _service.lastSync();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _lastSync = last;
      _status = result.message;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _storeCtrl.dispose();
    super.dispose();
  }

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.06),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ارتباط با شبکه'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: _online ? Colors.green.shade100 : Colors.red.shade100,
                  child: Icon(
                    _online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                    color: _online ? Colors.green : Colors.red,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_online ? 'اینترنت متصل است' : 'اینترنت در دسترس نیست', style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(_status, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _card(
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: _license.isEmpty ? Colors.orange.shade100 : Colors.blue.shade100,
                  child: Icon(
                    Icons.verified_user_outlined,
                    color: _license.isEmpty ? Colors.orange : Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('لایسنس این دستگاه', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        _license.isEmpty ? 'یافت نشد — از صفحه ورود وارد شوید.' : _license,
                        style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'فقط دستگاه‌هایی با همین لایسنس با هم همگام‌سازی می‌شوند.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('تنظیمات اتصال', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(controller: _urlCtrl, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'آدرس Supabase', hintText: 'https://xxxx.supabase.co', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                TextField(controller: _keyCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Publishable / Anon Key', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                TextField(controller: _storeCtrl, decoration: const InputDecoration(labelText: 'شناسه فروشگاه', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.admin_panel_settings_outlined, color: Colors.green),
                      SizedBox(width: 10),
                      Expanded(child: Text('این نسخه مخصوص مدیر است و دسترسی مدیریت بانک اطلاعاتی دارد.')),
                    ],
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('همگام‌سازی خودکار'),
                  subtitle: const Text('هر ۳۰ ثانیه هنگام باز بودن برنامه بررسی می‌شود.'),
                  value: _autoSync,
                  onChanged: (v) => setState(() => _autoSync = v),
                ),
                Row(
                  children: [
                    Expanded(child: OutlinedButton.icon(onPressed: _loading ? null : _test, icon: const Icon(Icons.wifi_find), label: const Text('تست اتصال'))),
                    const SizedBox(width: 10),
                    Expanded(child: ElevatedButton.icon(onPressed: _loading ? null : _sync, icon: const Icon(Icons.sync), label: const Text('همگام‌سازی'))),
                  ],
                ),
              ],
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('بانک اطلاعاتی', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('مدیر می‌تواند نسخه مرکزی بانک کالا را منتشر کند و صندوق‌داران آن را دریافت کنند.'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: ElevatedButton.icon(onPressed: _loading ? null : _uploadProductDatabase, icon: const Icon(Icons.cloud_upload_outlined), label: const Text('ارسال بانک'))),
                    const SizedBox(width: 10),
                    Expanded(child: OutlinedButton.icon(onPressed: _loading ? null : _downloadProductDatabase, icon: const Icon(Icons.cloud_download_outlined), label: const Text('دریافت بانک'))),
                  ],
                ),
              ],
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('صف ارسال: $_pending مورد', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(_lastSync == null ? 'آخرین همگام‌سازی: هنوز انجام نشده' : 'آخرین همگام‌سازی: ${_lastSync!.toLocal()}'),
                const SizedBox(height: 10),
                const Text('این معماری برای حالت آفلاین هم طراحی شده است؛ اطلاعات ابتدا روی دستگاه ذخیره می‌شوند و بعد از اتصال ارسال خواهند شد.', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          if (_loading) const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())),
        ],
      ),
    );
  }
}

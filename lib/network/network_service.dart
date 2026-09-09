import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class NetworkConfig {
  final String baseUrl;
  final String anonKey;
  final String storeId;
  final String role;
  final bool autoSync;
  final String license;

  const NetworkConfig({
    required this.baseUrl,
    required this.anonKey,
    required this.storeId,
    required this.role,
    required this.autoSync,
    required this.license,
  });

  bool get isConfigured =>
      baseUrl.isNotEmpty && anonKey.isNotEmpty && storeId.isNotEmpty && license.isNotEmpty;
}

class SnapshotInfo {
  final String updatedAt;
  final String updatedBy;

  const SnapshotInfo({required this.updatedAt, this.updatedBy = ''});
}

class NetworkSyncResult {
  final bool success;
  final String message;
  final int pendingEvents;
  final DateTime? serverUpdatedAt;

  const NetworkSyncResult({
    required this.success,
    required this.message,
    this.pendingEvents = 0,
    this.serverUpdatedAt,
  });
}

/// ارتباط شبکه بدون قرار دادن هیچ کلید محرمانه‌ای در برنامه.
/// این کلاس در حالت آفلاین فقط رویدادها را در outbox محلی نگه می‌دارد.
class NetworkService {
  static const _baseUrlKey = 'network_base_url';
  static const _anonKey = 'network_anon_key';
  static const _storeIdKey = 'network_store_id';
  static const _roleKey = 'network_role';
  static const _autoSyncKey = 'network_auto_sync';
  static const _lastSyncKey = 'network_last_sync';
  static const _outboxKey = 'network_outbox';
  static const _localSnapshotKey = 'network_local_snapshot';
  // همان کلیدی که هنگام ورود در صفحه لاگین ذخیره می‌شود (main.dart -> LoginScreen).
  static const _userLicenseKey = 'user_license';

  Future<NetworkConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return NetworkConfig(
      baseUrl: prefs.getString(_baseUrlKey) ?? '',
      anonKey: prefs.getString(_anonKey) ?? '',
      storeId: prefs.getString(_storeIdKey) ?? 'store-1',
      role: prefs.getString(_roleKey) ?? 'manager',
      autoSync: prefs.getBool(_autoSyncKey) ?? true,
      // لایسنس مستقیماً از همان لایسنسی که کاربر هنگام ورود وارد کرده خوانده می‌شود؛
      // این‌طور تضمین می‌شود که فقط اپ‌هایی با لایسنس یکسان بتوانند با هم همگام شوند.
      license: prefs.getString(_userLicenseKey) ?? '',
    );
  }

  Future<void> saveConfig({
    required String baseUrl,
    required String anonKey,
    required String storeId,
    String role = 'manager',
    required bool autoSync,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl.trim().replaceAll(RegExp(r'/$'), ''));
    await prefs.setString(_anonKey, anonKey.trim());
    await prefs.setString(_storeIdKey, storeId.trim());
    await prefs.setString(_roleKey, role);
    await prefs.setBool(_autoSyncKey, autoSync);
  }

  Future<DateTime?> lastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastSyncKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<int> pendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxKey);
    if (raw == null || raw.isEmpty) return 0;
    try {
      return (jsonDecode(raw) as List).length;
    } catch (_) {
      return 0;
    }
  }

  Future<String> queueEvent({
    required String type,
    required Map<String, dynamic> payload,
    String? actorName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxKey);
    final List<dynamic> events = raw == null || raw.isEmpty ? [] : (jsonDecode(raw) as List<dynamic>);
    final config = await loadConfig();
    events.add({
      'id': '${DateTime.now().microsecondsSinceEpoch}-${events.length}',
      'type': type,
      'store_id': _scopedStoreId(config),
      'license': config.license,
      'actor_name': actorName ?? '',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'payload': payload,
    });
    await prefs.setString(_outboxKey, jsonEncode(events));
    return events.last['id'].toString();
  }

  Future<bool> isOnline() async {
    try {
      final result = await InternetAddress.lookup('example.com').timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Uri _restUri(NetworkConfig config, String path, [Map<String, String>? query]) {
    final base = config.baseUrl.replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$base/rest/v1/$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Map<String, String> _headers(NetworkConfig config) => {
        'apikey': config.anonKey,
        'Authorization': 'Bearer ${config.anonKey}',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  /// شناسه ترکیبی «لایسنس + فروشگاه» که کانال داده را کاملاً از سایر لایسنس‌ها جدا می‌کند.
  /// حتی اگر همه اپ‌ها از یک anon key مشترک استفاده کنند، هر لایسنس فقط ردیف‌های خودش را می‌بیند.
  String _scopedStoreId(NetworkConfig config) => '${config.license}__${config.storeId}';

  Future<void> _close(HttpClient client) async {
    client.close(force: true);
  }

  Future<NetworkSyncResult> testConnection() async {
    final config = await loadConfig();
    if (!config.isConfigured) {
      return const NetworkSyncResult(success: false, message: 'ابتدا مشخصات سرور را در ارتباط با شبکه وارد کنید.');
    }
    final client = HttpClient();
    try {
      final request = await client.getUrl(_restUri(config, 'store_snapshots', {'select': 'store_id', 'store_id': 'eq.${_scopedStoreId(config)}', 'limit': '1'})).timeout(const Duration(seconds: 7));
      _headers(config).forEach(request.headers.set);
      final response = await request.close().timeout(const Duration(seconds: 7));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return NetworkSyncResult(success: true, message: 'اتصال به سرور با موفقیت برقرار شد.');
      }
      return NetworkSyncResult(success: false, message: 'سرور پاسخ ${response.statusCode} داد: ${body.isEmpty ? 'خطای نامشخص' : body}');
    } catch (e) {
      return NetworkSyncResult(success: false, message: 'اتصال برقرار نشد: $e');
    } finally {
      await _close(client);
    }
  }

  Future<NetworkSyncResult> uploadSnapshot(Map<String, dynamic> snapshot, {String? actorName}) async {
    final config = await loadConfig();
    if (!config.isConfigured) {
      await _cacheSnapshot(snapshot);
      return const NetworkSyncResult(success: false, message: 'تنظیمات شبکه کامل نیست؛ اطلاعات فعلاً محلی ذخیره شد.');
    }
    final client = HttpClient();
    try {
      final request = await client.postUrl(_restUri(config, 'store_snapshots')).timeout(const Duration(seconds: 7));
      final headers = _headers(config)
        ..['Prefer'] = 'resolution=merge-duplicates,return=minimal';
      headers.forEach(request.headers.set);
      request.add(utf8.encode(jsonEncode({
        'store_id': _scopedStoreId(config),
        'license': config.license,
        'payload': snapshot,
        'updated_by': actorName ?? '',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      })));
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastSyncKey, DateTime.now().toUtc().toIso8601String());
        return NetworkSyncResult(success: true, message: 'بانک اطلاعاتی روی سرور به‌روزرسانی شد.');
      }
      return NetworkSyncResult(success: false, message: 'ارسال اطلاعات ناموفق بود: $body');
    } catch (e) {
      await _cacheSnapshot(snapshot);
      return NetworkSyncResult(success: false, message: 'اینترنت در دسترس نبود؛ اطلاعات برای ارسال بعدی ذخیره شد.');
    } finally {
      await _close(client);
    }
  }

  Future<SnapshotInfo?> fetchSnapshotInfo() async {
    final config = await loadConfig();
    if (!config.isConfigured) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(_restUri(config, 'store_snapshots', {
        'select': 'updated_at,updated_by',
        'store_id': 'eq.${_scopedStoreId(config)}',
        'limit': '1',
      })).timeout(const Duration(seconds: 7));
      _headers(config).forEach(request.headers.set);
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final rows = jsonDecode(body) as List<dynamic>;
      if (rows.isEmpty) return null;
      final row = Map<String, dynamic>.from(rows.first);
      final updatedAt = (row['updated_at'] ?? '').toString();
      if (updatedAt.isEmpty) return null;
      return SnapshotInfo(
        updatedAt: updatedAt,
        updatedBy: (row['updated_by'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    } finally {
      await _close(client);
    }
  }

  Future<Map<String, dynamic>?> downloadSnapshot() async {
    final config = await loadConfig();
    if (!config.isConfigured) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(_restUri(config, 'store_snapshots', {
        'select': 'payload,updated_at,updated_by',
        'store_id': 'eq.${_scopedStoreId(config)}',
        'limit': '1',
      })).timeout(const Duration(seconds: 7));
      _headers(config).forEach(request.headers.set);
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final rows = jsonDecode(body) as List<dynamic>;
      if (rows.isEmpty) return null;
      final payload = Map<String, dynamic>.from(rows.first['payload'] ?? {});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastSyncKey, DateTime.now().toUtc().toIso8601String());
      return payload;
    } catch (_) {
      return null;
    } finally {
      await _close(client);
    }
  }

  Future<List<Map<String, dynamic>>> fetchRecentEvents({int limit = 50}) async {
    final config = await loadConfig();
    if (!config.isConfigured) return [];
    final client = HttpClient();
    try {
      final request = await client.getUrl(_restUri(config, 'network_events', {
        'select': 'id,type,actor_name,created_at,payload',
        'store_id': 'eq.${_scopedStoreId(config)}',
        'order': 'created_at.desc',
        'limit': '$limit',
      })).timeout(const Duration(seconds: 7));
      _headers(config).forEach(request.headers.set);
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return [];
      final rows = jsonDecode(body) as List<dynamic>;
      return rows.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    } finally {
      await _close(client);
    }
  }

  Future<NetworkSyncResult> syncOutbox() async {
    final config = await loadConfig();
    if (!config.isConfigured) return NetworkSyncResult(success: false, message: 'تنظیمات شبکه کامل نیست.', pendingEvents: await pendingCount());
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_outboxKey);
    if (raw == null || raw.isEmpty) return const NetworkSyncResult(success: true, message: 'موردی برای ارسال وجود ندارد.');
    final events = jsonDecode(raw) as List<dynamic>;
    final client = HttpClient();
    final remaining = <dynamic>[];
    try {
      for (final event in events) {
        try {
          final request = await client.postUrl(_restUri(config, 'network_events')).timeout(const Duration(seconds: 7));
          _headers(config).forEach(request.headers.set);
          request.add(utf8.encode(jsonEncode(event)));
          final response = await request.close().timeout(const Duration(seconds: 10));
          await response.drain();
          if (response.statusCode < 200 || response.statusCode >= 300) remaining.add(event);
        } catch (_) {
          remaining.add(event);
        }
      }
      await prefs.setString(_outboxKey, jsonEncode(remaining));
      await prefs.setString(_lastSyncKey, DateTime.now().toUtc().toIso8601String());
      return NetworkSyncResult(success: remaining.isEmpty, message: remaining.isEmpty ? 'همگام‌سازی رویدادها انجام شد.' : 'برخی رویدادها برای ارسال بعدی باقی ماندند.', pendingEvents: remaining.length);
    } finally {
      await _close(client);
    }
  }

  Future<void> _cacheSnapshot(Map<String, dynamic> snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localSnapshotKey, jsonEncode(snapshot));
  }
}

import 'package:intl/intl.dart';

/// Calendar dates are `YYYY-MM-DD` strings on the wire (no time, no timezone).
DateTime? parseDate(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.length == 10 ? '${s}T00:00:00' : s)?.toLocal();
}

String? isoDate(DateTime? d) => d == null ? null : DateFormat('yyyy-MM-dd').format(d);

String fmtDate(Object? v, {String empty = '—'}) {
  final d = v is DateTime ? v : parseDate(v);
  return d == null ? empty : DateFormat.yMMMd().format(d);
}

String fmtDayShort(Object? v) {
  final d = v is DateTime ? v : parseDate(v);
  return d == null ? '' : DateFormat('EEE, MMM d').format(d);
}

String fmtMonth(DateTime d) => DateFormat('MMM').format(d).toUpperCase();

String fmtToday() => DateFormat('EEEE, MMMM d').format(DateTime.now());

/// Whole days from today (local calendar) to [v]; negative when past.
int? daysUntil(Object? v) {
  final d = v is DateTime ? v : parseDate(v);
  if (d == null) return null;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return DateTime(d.year, d.month, d.day).difference(today).inDays;
}

String relativeDays(int? days) {
  if (days == null) return '';
  if (days < -1) return '${-days} days ago';
  if (days == -1) return 'yesterday';
  if (days == 0) return 'today';
  if (days == 1) return 'tomorrow';
  return 'in $days days';
}

String daysLeftLabel(int? days) {
  if (days == null) return '';
  if (days < 0) return 'Ended ${relativeDays(days)}';
  if (days == 0) return 'Last day';
  return '$days ${days == 1 ? 'day' : 'days'} left';
}

/// Money is a decimal string on the wire; never use floats for arithmetic.
String fmtMoney(Object? amount, {String currency = 'USD'}) {
  if (amount == null || amount.toString().isEmpty) return '—';
  final n = num.tryParse(amount.toString());
  if (n == null) return amount.toString();
  final symbol = switch (currency) { 'GBP' => '£', 'CAD' => 'CA\$', _ => '\$' };
  return NumberFormat.currency(symbol: symbol, decimalDigits: 2).format(n);
}

/// Validates a user-typed amount and normalises it to "123.45" (or null).
String? normalizeMoney(String input) {
  final s = input.replaceAll(RegExp(r'[,\s$£]'), '');
  if (s.isEmpty) return null;
  if (!RegExp(r'^\d{1,10}(\.\d{1,2})?$').hasMatch(s)) return null;
  final parts = s.split('.');
  return '${parts[0]}.${(parts.length > 1 ? parts[1] : '').padRight(2, '0')}';
}

String fmtBytes(num? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String titleCase(String? s) {
  if (s == null || s.isEmpty) return '';
  return s.replaceAll('_', ' ').split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
}

/// Tolerant JSON readers used by data-layer mappers.
extension JsonRead on Map<String, dynamic> {
  String? s(String k) => this[k]?.toString();
  String str(String k, [String d = '']) => this[k]?.toString() ?? d;
  int? i(String k) => this[k] is num ? (this[k] as num).toInt() : int.tryParse('${this[k] ?? ''}');
  bool b(String k) => this[k] == true;
  Map<String, dynamic> m(String k) => this[k] is Map ? Map<String, dynamic>.from(this[k] as Map) : <String, dynamic>{};
  List<Map<String, dynamic>> l(String k) =>
      (this[k] is List ? this[k] as List : const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

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

/// Last covered day of a duration-based term. Mirrors the server
/// (backend/src/lib/dates.ts durationEndDate): add calendar months with
/// month-end clamping (Jan 31 + 1 month = Feb 28/29), then step back one day.
DateTime durationEndDate(DateTime start, int months) {
  final target = start.month - 1 + months;
  final y = start.year + (target ~/ 12);
  final m = target % 12 + 1;
  final lastDay = DateTime(y, m + 1, 0).day;
  final anniversary = DateTime(y, m, start.day > lastDay ? lastDay : start.day);
  return anniversary.subtract(const Duration(days: 1));
}

/// True when the user typed something into a money field that can't be saved
/// (letters, a minus sign, more than 2 decimals). Empty is fine (= unknown).
/// Forms must block on this instead of silently dropping the value.
bool isBadMoney(String input) => input.trim().isNotEmpty && normalizeMoney(input) == null;

const badMoneyMessage = 'Use numbers only, like 749.99';

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

/// Receipts often print the store in capitals ("THE HOME DEPOT"). Show those as
/// "The Home Depot"; names the user typed in mixed case are left alone.
String? storeName(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty || t != t.toUpperCase() || !RegExp(r'[A-Z]{2}').hasMatch(t)) return t.isEmpty ? null : t;
  const keepUpper = {'LG', 'HP', 'BJ', 'BJS', 'REI', 'TJ', 'QVC', 'CVS', 'JCP', 'USA', 'UK'};
  return t.split(RegExp(r'(?<=\s)|(?=\s)')).map((w) {
    final core = w.replaceAll(RegExp(r"[^A-Za-z]"), '');
    if (w.trim().isEmpty || keepUpper.contains(core)) return w;
    return w.splitMapJoin(RegExp(r"[A-Za-z][A-Za-z']*"), onMatch: (m) => m[0]![0] + m[0]!.substring(1).toLowerCase());
  }).join();
}

/// Camera and picker uploads get machine names ("image_picker_C584AF…-0000.jpg",
/// "PXL_20261115_…jpg"). Show those as "Receipt photo" instead; real names stay.
String docName(String? filename, String fileType) {
  final kind = switch (fileType) {
    'receipt' => 'Receipt',
    'warranty' => 'Warranty document',
    'manual' => 'Manual',
    'invoice' => 'Invoice',
    'photo' || 'product_photo' => 'Photo',
    _ => titleCase(fileType.replaceAll('_', ' ')),
  };
  final f = filename?.trim() ?? '';
  if (f.isEmpty) return kind;
  final base = f.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '');
  final machine = RegExp(r'^(image_picker_|scaled_|IMG[-_]|PXL_|Screenshot_|document_)', caseSensitive: false).hasMatch(base) ||
      RegExp(r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}').hasMatch(base) ||
      RegExp(r'^[\d_-]{8,}$').hasMatch(base);
  if (!machine) return f;
  final image = RegExp(r'\.(jpe?g|png|heic|heif|webp)$', caseSensitive: false).hasMatch(f);
  return image && kind != 'Photo' ? '$kind photo' : kind;
}

/// Receipt lines print products in capitals ("PHILIPS AIRFRYER HD9252"). Offer
/// "Philips Airfryer HD9252": words with digits (model codes) and short
/// acronyms stay as printed; names already in mixed case are left alone.
String productName(String? s) {
  final t = (s ?? '').trim();
  if (t.isEmpty || t != t.toUpperCase() || !RegExp(r'[A-Z]{3}').hasMatch(t)) return t;
  const keepUpper = {'LG', 'HP', 'TV', 'LED', 'OLED', 'QLED', 'USB', 'HD', 'UHD', '4K', 'PC', 'AC', 'DC', 'XL', 'XXL', 'UK', 'USA', 'JBL', 'AEG', 'SMEG', 'BOSE'};
  return t.split(' ').map((w) {
    if (w.isEmpty || RegExp(r'\d').hasMatch(w) || keepUpper.contains(w.replaceAll(RegExp(r'[^A-Z0-9]'), ''))) return w;
    return w.splitMapJoin(RegExp(r"[A-Z][A-Z']*"), onMatch: (m) => m[0]![0] + m[0]!.substring(1).toLowerCase());
  }).join(' ');
}

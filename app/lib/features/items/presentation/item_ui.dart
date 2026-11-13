import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/utils/format.dart';
import '../domain/items.dart';

/// Icon for an item, from its category or name (prototype uses product-like icons).
IconData itemIcon({String? category, String? name}) {
  final n = (name ?? '').toLowerCase();
  bool has(List<String> w) => w.any(n.contains);
  if (has(['airpod', 'headphone', 'earbud', 'speaker', 'soundbar'])) return PhosphorIconsRegular.headphones;
  if (has(['tv', 'television', 'monitor', 'display'])) return PhosphorIconsRegular.television;
  if (has(['washer', 'washing'])) return PhosphorIconsRegular.washingMachine;
  if (has(['dryer'])) return PhosphorIconsRegular.wind;
  if (has(['vacuum', 'dyson', 'broom'])) return PhosphorIconsRegular.broom;
  if (has(['laptop', 'macbook', 'computer', 'pc'])) return PhosphorIconsRegular.laptop;
  if (has(['phone', 'iphone', 'pixel', 'galaxy'])) return PhosphorIconsRegular.deviceMobile;
  if (has(['tablet', 'ipad'])) return PhosphorIconsRegular.deviceTablet;
  if (has(['watch'])) return PhosphorIconsRegular.watch;
  if (has(['camera'])) return PhosphorIconsRegular.camera;
  if (has(['drill', 'saw', 'tool', 'dewalt', 'makita', 'milwaukee', 'ryobi'])) return PhosphorIconsRegular.wrench;
  if (has(['mixer', 'blender', 'kettle', 'espresso', 'coffee', 'toaster', 'oven', 'microwave'])) return PhosphorIconsRegular.cookingPot;
  if (has(['fridge', 'refrigerator', 'freezer'])) return PhosphorIconsRegular.snowflake;
  if (has(['console', 'playstation', 'xbox', 'switch'])) return PhosphorIconsRegular.gameController;
  return switch (category) {
    'audio' => PhosphorIconsRegular.headphones,
    'appliances' => PhosphorIconsRegular.washingMachine,
    'computers' => PhosphorIconsRegular.laptop,
    'phones_tablets' => PhosphorIconsRegular.deviceMobile,
    'gaming' => PhosphorIconsRegular.gameController,
    'cameras' => PhosphorIconsRegular.camera,
    'furniture' => PhosphorIconsRegular.armchair,
    'tools' => PhosphorIconsRegular.wrench,
    'automotive' => PhosphorIconsRegular.car,
    'kitchen' => PhosphorIconsRegular.cookingPot,
    'wearables' => PhosphorIconsRegular.watch,
    'electronics' => PhosphorIconsRegular.plug,
    'home' => PhosphorIconsRegular.house,
    _ => PhosphorIconsRegular.package,
  };
}

IconData docIcon(String? fileType, String? mime) {
  if (mime == 'application/pdf') return PhosphorIconsRegular.filePdf;
  return switch (fileType) {
    'receipt' => PhosphorIconsRegular.receipt,
    'warranty_card' => PhosphorIconsRegular.certificate,
    'manual' => PhosphorIconsRegular.bookOpen,
    'product_photo' => PhosphorIconsRegular.image,
    'claim_evidence' => PhosphorIconsRegular.camera,
    'registration' => PhosphorIconsRegular.clipboardText,
    _ => PhosphorIconsRegular.file,
  };
}

const coverageTypeLabels = {
  'manufacturer': 'Manufacturer',
  'retailer': 'Retailer',
  'extended': 'Extended',
  'protection_plan': 'Protection plan',
  'credit_card': 'Card benefit',
  'statutory_note': 'Note',
  'other': 'Other',
};

String coverageTitle(Warranty w) {
  final type = coverageTypeLabels[w.coverageType] ?? 'Coverage';
  return switch (w.termKind) {
    'duration' => '${w.durationMonths ?? '?'}-month ${type.toLowerCase()} coverage',
    'fixed_date' => '$type coverage',
    'lifetime' => 'Lifetime $type coverage',
    'conditional' => 'Conditional $type coverage',
    _ => '$type coverage · terms unknown',
  };
}

String coverageTerm(Warranty w) => switch (w.termKind) {
      'duration' => 'Duration · ${w.durationMonths} months from ${w.startAnchor == 'delivery_date' ? 'delivery' : w.startAnchor == 'custom' ? 'a set date' : 'purchase'}',
      'fixed_date' => 'Fixed end date',
      'lifetime' => 'Lifetime · no end date',
      'conditional' => w.conditions ?? 'Conditional terms',
      _ => 'No terms recorded',
    };

String coverageRange(Warranty w) {
  if (w.endDate == null) return w.termKind == 'lifetime' ? 'No end date' : 'End date unknown';
  return '${w.startDate == null ? 'Start unknown' : fmtDate(w.startDate)} → ${fmtDate(w.endDate)}';
}

/// Elapsed share of the coverage term (for the progress bar), or null.
double? coverageProgress(Warranty w) {
  final s = parseDate(w.startDate), e = parseDate(w.endDate);
  if (s == null || e == null) return null;
  final total = e.difference(s).inDays;
  if (total <= 0) return 1;
  return (DateTime.now().difference(s).inDays / total).clamp(0, 1).toDouble();
}

String returnAnchorLabel(String a) => switch (a) {
      'purchase_date' => 'purchase',
      'delivery_date' => 'delivery',
      'custom' => 'a set date',
      _ => 'an unknown date',
    };

String returnMeaning(String basis) => switch (basis) {
      'request_by' => 'Start the return by',
      'postmark_by' => 'Postmarked by',
      'merchant_receipt_by' => 'Received by the store by',
      _ => 'Deadline',
    };

String returnStateLabel(String s) => switch (s) {
      'not_started' => 'Not started',
      'initiated' => 'Return started',
      'shipped' => 'Shipped back',
      'received_by_merchant' => 'Received by store',
      'refunded' => 'Refund received',
      'rejected' => 'Rejected by store',
      _ => 'Cancelled',
    };

const lifecycleLabels = {'owned': 'Owned', 'returned': 'Returned', 'sold': 'Sold', 'gifted': 'Gifted', 'lost': 'Lost', 'disposed': 'Disposed'};

/// One-line status for an item row, most urgent first.
(String, bool) itemStatus(ItemSummary it) {
  final ret = daysUntil(it.nextReturnDeadline);
  if (ret != null && ret >= 0) return ('Return window ends ${relativeDays(ret)}', ret <= 3);
  final reg = daysUntil(it.nextRegistrationDeadline);
  if (it.registrationPending && reg != null && reg >= 0) return ('Registration due ${relativeDays(reg)}', reg <= 3);
  final cov = daysUntil(it.nearestCoverageEnd);
  if (cov != null && cov >= 0) return ('Coverage ends ${fmtDate(it.nearestCoverageEnd)}', cov <= 30);
  if (it.lifecycle != 'owned') return (lifecycleLabels[it.lifecycle] ?? it.lifecycle, false);
  if (it.coverageCount == 0) return ('Coverage unknown', false);
  if (it.hasUnconfirmedCoverage) return ('Coverage estimated', false);
  return ('No upcoming deadlines', false);
}

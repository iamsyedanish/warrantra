import 'package:flutter_test/flutter_test.dart';
import 'package:warrantra/core/utils/format.dart';
import 'package:warrantra/features/capture/data/capture_repository_impl.dart';
import 'package:warrantra/features/capture/presentation/upload_flow.dart';
import 'package:warrantra/features/items/data/items_repository_impl.dart';
import 'package:warrantra/features/items/domain/items.dart';
import 'package:warrantra/features/items/presentation/item_ui.dart';

void main() {
  group('format', () {
    test('normalizeMoney strips symbols and keeps 2 decimals', () {
      expect(normalizeMoney(r'$1,299.5'), '1299.50');
      expect(normalizeMoney(''), isNull);
    });
    test('isoDate round-trips', () => expect(isoDate(parseDate('2026-11-04')), '2026-11-04'));
  });

  test('mimeFor recognises supported types only', () {
    expect(mimeFor('a.JPG'), 'image/jpeg');
    expect(mimeFor('scan.pdf'), 'application/pdf');
    expect(mimeFor('x.docx'), isNull);
  });

  test('scan review draft maps evidence and status', () {
    final job = scanFromJson({
      'id': 's1',
      'feature': 'receipt_extraction',
      'state': 'succeeded',
      'review_draft': {
        'merchant': {'value': 'Lowe\'s', 'evidence': 'LOWES #123', 'status': 'extracted'},
        'purchase_date': {'value': null, 'evidence': null, 'status': 'missing'},
        'lines': [
          {'line_index': 0, 'description': 'DRILL', 'quantity': 1, 'line_amount': '99.00'}
        ],
        'suggestions': {'return_policy': [], 'warranty': []},
        'warnings': ['tax: could not be verified'],
      },
    });
    expect(job.receipt!.merchant.found, isTrue);
    expect(job.receipt!.purchaseDate.found, isFalse);
    expect(job.receipt!.lines.single.lineAmount, '99.00');
    expect(job.done, isTrue);
  });

  test('item status prefers the nearest return deadline', () {
    final soon = isoDate(DateTime.now().add(const Duration(days: 2)))!;
    final item = itemSummaryFromJson({'id': 'i', 'name': 'AirPods', 'next_return_deadline': soon, 'coverage_count': 1});
    final (label, urgent) = itemStatus(item);
    expect(label, startsWith('Return window ends'));
    expect(urgent, isTrue);
  });

  test('coverage title for lifetime and unknown terms', () {
    expect(coverageTitle(const Warranty(id: 'w', coverageType: 'manufacturer', termKind: 'lifetime', certainty: 'user_confirmed')), 'Lifetime Manufacturer coverage');
    expect(coverageTitle(const Warranty(id: 'w', coverageType: 'retailer', termKind: 'unknown', certainty: 'unknown')), contains('terms unknown'));
  });
}

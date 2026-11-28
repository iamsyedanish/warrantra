// The guide's steps point at real parts of the screen; every such step must have
// a picture, and every target must be tagged somewhere in the app.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warrantra/features/guide/guide_content.dart';
import 'package:warrantra/features/guide/guide_illustration.dart';

void main() {
  final steps = [for (final t in guideTopics) ...t.steps, ...guideIntroTour];
  final targets = {for (final s in steps) if (s.target != null) s.target!};

  test('every pointed-at step has a picture', () {
    final missing = targets.where((t) => !GuideIllustration.has(t)).toList();
    expect(missing, isEmpty, reason: 'No illustration for: $missing');
  });

  test('every target is tagged in the app', () {
    final source = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.contains('features/guide/')).map((f) => f.readAsStringSync()).join('\n');
    final untagged = targets.where((t) => !source.contains("'$t'")).toList();
    expect(untagged, isEmpty, reason: 'Not tagged with GuideTarget: $untagged');
  });

  test('topics have friendly, short steps', () {
    for (final t in guideTopics) {
      expect(t.steps, isNotEmpty, reason: t.id);
      for (final s in t.steps) {
        expect(s.text.length, lessThan(140), reason: '${t.id}: "${s.text}" is too long');
      }
    }
  });
}

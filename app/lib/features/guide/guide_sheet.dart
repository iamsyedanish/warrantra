import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/display.dart';
import '../../core/widgets/scaffold.dart';
import '../../core/router/app_router.dart' show rootNavigatorKey;
import '../capture/presentation/add_sheet.dart';
import 'guide_avatar.dart';
import 'guide_content.dart';
import 'guide_illustration.dart';
import 'guide_spotlight.dart';

/// Bumped to ask the app shell to run the spotlight tour.
final guideTourRequests = ValueNotifier<int>(0);

/// Prefs key: the first-login introduction has been shown on this phone.
const guideIntroSeenKey = 'guide_intro_seen_v1';

String _path(BuildContext context) {
  try {
    return GoRouter.of(context).routeInformationProvider.value.uri.path;
  } catch (_) {
    return '';
  }
}

/// Opens the guide for the screen the user is on.
Future<void> showGuide(BuildContext context) {
  final path = _path(context);
  return showWSheet<void>(context, builder: (ctx) => _GuideSheet(path: path, host: context));
}

/// Pip in a screen header, except on the signed-out screens.
Widget? guideHeaderButton(BuildContext context) {
  final path = _path(context);
  if (RegExp(r'^/(signin|signup|forgot|onboarding|splash)').hasMatch(path)) return null;
  return const GuideButton(size: 30);
}

/// The small Pip button used in screen headers and above the tab bar.
class GuideButton extends StatelessWidget {
  const GuideButton({super.key, this.size = 34});
  final double size;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Ask ${GuideAvatar.name} for help',
      child: InkResponse(
        radius: size * 0.75,
        onTap: () => showGuide(context),
        child: Padding(padding: const EdgeInsets.all(3), child: GuideAvatar(size: size)),
      ),
    );
  }
}

class _GuideSheet extends StatefulWidget {
  const _GuideSheet({required this.path, required this.host});
  final String path;
  final BuildContext host;
  @override
  State<_GuideSheet> createState() => _GuideSheetState();
}

class _GuideSheetState extends State<_GuideSheet> {
  final _search = TextEditingController();
  GuideTopic? _open;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Closes the panel, goes to the right screen and walks through it.
  Future<void> _showMe(GuideTopic t) async {
    final host = widget.host;
    Navigator.pop(context);
    final r = t.route;
    if (r == 'add') {
      if (host.mounted) unawaited(showAddSheet(host));
    } else if (r != null && r != widget.path && host.mounted) {
      if (const ['/home', '/items', '/vault', '/settings'].contains(r)) {
        host.go(r);
      } else {
        host.push(r);
      }
    }
    // Let the screen (or sheet) build before spotlighting its parts.
    await Future<void>.delayed(const Duration(milliseconds: 650));
    final nav = rootNavigatorKey.currentState;
    final overlay = nav?.overlay;
    if (nav != null && overlay != null && nav.mounted) await GuideSpotlight.run(nav.context, t.steps, heading: t.title, overlay: overlay);
  }

  void _tour() {
    final host = widget.host;
    Navigator.pop(context);
    if (host.mounted) host.go('/home');
    guideTourRequests.value++;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final height = MediaQuery.of(context).size.height * 0.78;
    final here = guideTopics.where((t) => t.matches(widget.path)).toList();
    final q = _search.text;
    final results = guideTopics.where((t) => t.search(q)).toList();
    return SizedBox(
      height: height,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Pip speaking.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const GuideAvatar(size: 52),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: const BorderRadius.only(topRight: Radius.circular(14), bottomLeft: Radius.circular(14), bottomRight: Radius.circular(14)),
              ),
              child: Text(
                _open != null
                    ? 'Here’s how ${_open!.title.toLowerCase()} works.'
                    : here.isNotEmpty
                        ? 'Hi, I’m ${GuideAvatar.name}! Here’s help for this screen, or search for anything.'
                        : 'Hi, I’m ${GuideAvatar.name}! What would you like help with?',
                style: TextStyle(fontSize: 14, height: 1.35, color: c.accentSoftText, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Expanded(child: _open != null ? _detail(_open!) : _list(here, results, q)),
      ]),
    );
  }

  Widget _list(List<GuideTopic> here, List<GuideTopic> results, String q) {
    final c = context.w;
    return ListView(padding: EdgeInsets.zero, children: [
      TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search help, e.g. “return” or “scan”',
          prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 20, color: c.textSubtle),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      if (q.isEmpty && here.isNotEmpty) ...[
        const WSectionHeader('On this screen'),
        for (final t in here) _TopicRow(t, highlighted: true, onTap: () => setState(() => _open = t)),
        const SizedBox(height: 8),
      ],
      WSectionHeader(q.isEmpty ? 'Everything in Warrantra' : '${results.length} result${results.length == 1 ? '' : 's'}'),
      if (results.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('Nothing matches that. Try a shorter word, like “claim” or “reminder”.', style: TextStyle(color: c.textMuted)),
        ),
      for (final t in results) _TopicRow(t, onTap: () => setState(() => _open = t)),
      const SizedBox(height: 10),
      WButton.secondary('Take the tour again', icon: PhosphorIconsRegular.compass, onPressed: _tour),
    ]);
  }

  Widget _detail(GuideTopic t) {
    final c = context.w;
    return ListView(padding: EdgeInsets.zero, children: [
      Row(children: [
        WTintIcon(t.icon, t.tint, size: 44),
        const SizedBox(width: 12),
        Expanded(child: Text(t.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text))),
      ]),
      const SizedBox(height: 10),
      Text(t.summary, style: TextStyle(fontSize: 14.5, height: 1.45, color: c.textMuted)),
      const SizedBox(height: 16),
      for (final (i, s) in t.steps.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: t.tint.withValues(alpha: 0.16), shape: BoxShape.circle),
              child: Text('${i + 1}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.tint)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(padding: const EdgeInsets.only(top: 3), child: Text(s.text, style: TextStyle(fontSize: 15, height: 1.4, color: c.text))),
                // A picture of the screen with this part pointed out.
                if (GuideIllustration.has(s.target)) ...[
                  const SizedBox(height: 10),
                  GuideIllustration(target: s.target!, height: 140),
                ],
              ]),
            ),
          ]),
        ),
      const SizedBox(height: 6),
      if (t.route != null || t.matches(widget.path))
        WButton('Show me step by step', icon: PhosphorIconsRegular.handPointing, onPressed: () => _showMe(t)),
      const SizedBox(height: 4),
      WButton.ghost('All help topics', onPressed: () => setState(() => _open = null)),
    ]);
  }
}

class _TopicRow extends StatelessWidget {
  const _TopicRow(this.t, {required this.onTap, this.highlighted = false});
  final GuideTopic t;
  final VoidCallback onTap;
  final bool highlighted;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: highlighted ? c.accentSoft : c.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: highlighted ? c.accentRing : c.divider)),
            child: Row(children: [
              WTintIcon(t.icon, t.tint, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                  const SizedBox(height: 2),
                  Text(t.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, height: 1.35, color: c.textMuted)),
                ]),
              ),
              Icon(PhosphorIconsRegular.caretRight, size: 16, color: c.textSubtle),
            ]),
          ),
        ),
      ),
    );
  }
}

/// First-login introduction. Returns true when the user wants the tour.
Future<bool> showGuideIntro(BuildContext context) async {
  final r = await showWSheet<bool>(
    context,
    builder: (ctx) {
      final c = ctx.w;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 4),
        const Center(child: GuideAvatar(size: 96)),
        const SizedBox(height: 14),
        Text('Hi, I’m ${GuideAvatar.name}!', textAlign: TextAlign.center, style: ctx.t.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'I’ll help you find your way around Warrantra. Want a 30-second tour? You can ask me anything later: just tap me in the corner of any screen.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14.5, height: 1.45, color: c.textMuted),
        ),
        const SizedBox(height: 20),
        WButton('Show me around', icon: PhosphorIconsRegular.compass, onPressed: () => Navigator.pop(ctx, true)),
        const SizedBox(height: 4),
        WButton.ghost('Maybe later', onPressed: () => Navigator.pop(ctx, false)),
      ]);
    },
  );
  return r ?? false;
}

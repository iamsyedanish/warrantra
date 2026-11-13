import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../domain/household.dart';
import 'household_providers.dart';

Future<String?> _ask(BuildContext context, String title, String label, {String? hint, TextInputType? type}) {
  final c = TextEditingController();
  return showWSheet<String>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: ctx.t.titleLarge),
        const SizedBox(height: 10),
        WField(label: label, controller: c, hint: hint, keyboardType: type),
        WButton('Continue', onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? null : c.text.trim())),
      ]));
}

String roleLabel(String r) => switch (r) { 'owner' => 'Owner', 'admin' => 'Admin', 'editor' => 'Adds and edits', 'viewer' => 'Views only', _ => titleCase(r) };

class HouseholdScreen extends ConsumerWidget {
  const HouseholdScreen({super.key, this.shareItemId, this.kind = 'household'});
  final String? shareItemId;
  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final list = ref.watch(workspacesProvider);
    final me = ref.watch(meProvider).value;
    return WScreen(
      title: kind == 'business' ? 'Properties' : 'Household',
      actions: [
        WIconButton(PhosphorIconsRegular.ticket, tooltip: 'Accept invitation', onPressed: () async {
          final t = await _ask(context, 'Accept an invitation', 'Invitation code');
          if (t == null) return;
          try {
            await ref.read(householdRepositoryProvider).acceptInvite(t);
            ref.invalidate(workspacesProvider);
            if (context.mounted) showToast(context, 'Joined');
          } catch (e) {
            if (context.mounted) showFailure(context, e);
          }
        }),
      ],
      children: [
        AsyncBody<List<Workspace>>(
          value: list,
          onRetry: () => ref.invalidate(workspacesProvider),
          data: (all) {
            final ws = all.where((w) => w.kind == kind).toList();
            if (ws.isEmpty) {
              final allowed = me?.plan.workspaces ?? false;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                WEmpty(
                  icon: kind == 'business' ? PhosphorIconsRegular.buildings : PhosphorIconsRegular.usersThree,
                  title: kind == 'business' ? 'Track assets across properties' : 'Share a household vault',
                  message: kind == 'business'
                      ? 'A pilot for landlords and property operators: assets by location, service history and evidence.'
                      : 'Move items into a shared vault so household members see their receipts and coverage. Items you keep private stay private.',
                  action: WButton(allowed ? 'Create ${kind == 'business' ? 'portfolio' : 'household'}' : 'Available with Pro', expand: false, onPressed: () async {
                    if (!allowed) {
                      context.push('/settings/paywall');
                      return;
                    }
                    final name = await _ask(context, 'Name it', 'Name', hint: kind == 'business' ? 'e.g. Rivera Rentals' : 'e.g. Rivera home');
                    if (name == null) return;
                    try {
                      await ref.read(householdRepositoryProvider).create(kind: kind, name: name);
                      ref.invalidate(workspacesProvider);
                    } catch (e) {
                      if (context.mounted) showFailure(context, e);
                    }
                  }),
                ),
              ]);
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final w in ws) _WorkspaceView(id: w.id, shareItemId: shareItemId, myId: me?.profile.id)]);
          },
        ),
        const SizedBox(height: 10),
        Text('Each member gets their own reminders. Items shared here keep their receipts and coverage.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
      ],
    );
  }
}

class _WorkspaceView extends ConsumerWidget {
  const _WorkspaceView({required this.id, this.shareItemId, this.myId});
  final String id;
  final String? shareItemId, myId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final ws = ref.watch(workspaceProvider(id));
    final repo = ref.read(householdRepositoryProvider);
    Future<void> act(Future<void> Function() f, String done) async {
      try {
        await f();
        ref.invalidate(workspaceProvider(id));
        ref.invalidate(workspacesProvider);
        if (context.mounted) showToast(context, done);
      } catch (e) {
        if (context.mounted) showFailure(context, e);
      }
    }

    return AsyncBody<Workspace>(
      value: ws,
      data: (w) {
        final mine = w.ownerId == myId;
        final alreadyShared = shareItemId != null && w.items.any((i) => i.itemId == shareItemId);
        final byLoc = <String?, List<SharedItem>>{};
        for (final i in w.items) {
          byLoc.putIfAbsent(i.locationId, () => []).add(i);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(w.name, style: context.t.headlineSmall),
          Text('${w.items.length} shared item${w.items.length == 1 ? '' : 's'}${w.kind == 'business' ? ' · ${w.locations.length} locations' : ''}', style: TextStyle(color: c.textMuted)),
          if (shareItemId != null) ...[
            const SizedBox(height: 12),
            WButton(alreadyShared ? 'Already shared here' : 'Share this item here', icon: PhosphorIconsRegular.shareNetwork,
                onPressed: alreadyShared ? null : () => act(() => repo.shareItem(w.id, shareItemId!), 'Shared with ${w.name}')),
          ],
          const WSectionHeader('Members'),
          for (final m in w.members.where((m) => m.state != 'revoked'))
            WListRow(
              leading: WAvatar(m.name ?? '?', size: 36),
              title: '${m.name ?? 'Member'}${m.userId == myId ? ' (you)' : ''}',
              subtitle: '${roleLabel(m.role)}${m.joinedAt == null ? '' : ' · joined ${fmtDate(m.joinedAt)}'}',
              caret: false,
              trailing: mine && m.userId != myId
                  ? TextButton(
                      onPressed: () async {
                        final ok = await confirmDialog(context, title: 'Remove ${m.name ?? 'this member'}?', message: "They lose access to shared items. Their own items aren't affected.", confirm: 'Remove', destructive: true);
                        if (ok) await act(() => repo.updateMember(w.id, m.userId, {'state': 'revoked'}), 'Member removed');
                      },
                      child: const Text('Remove'))
                  : null,
            ),
          if (mine)
            WButton.secondary('Invite a member', icon: PhosphorIconsRegular.userPlus, onPressed: () async {
              final email = await _ask(context, 'Invite a member', 'Email', type: TextInputType.emailAddress);
              if (email != null) await act(() => repo.invite(w.id, email: email, role: 'editor'), 'Invitation sent');
            })
          else
            WButton.ghost('Leave', onPressed: () => act(() => repo.leave(w.id), 'You left ${w.name}')),
          if (w.kind == 'business') ...[
            WSectionHeader('Locations', action: 'Add', actionIcon: PhosphorIconsRegular.plus, onAction: () async {
              final n = await _ask(context, 'Add a location', 'Name', hint: 'e.g. 12 Oak St, Unit 2');
              if (n != null) await act(() => repo.addLocation(w.id, name: n), 'Location added');
            }),
            for (final l in w.locations) ...[
              Text(l.name, style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
              for (final i in byLoc[l.id] ?? const <SharedItem>[]) WListRow(icon: PhosphorIconsRegular.package, title: i.name, subtitle: [i.brand, i.model].whereType<String>().join(' · '), onTap: () => context.push('/items/${i.itemId}')),
              const SizedBox(height: 6),
            ],
          ],
          const WSectionHeader('Shared items'),
          if (w.items.isEmpty) Text('Nothing shared yet. Open an item and choose "Share with household".', style: TextStyle(color: c.textMuted)),
          for (final i in w.kind == 'business' ? (byLoc[null] ?? const <SharedItem>[]) : w.items)
            WListRow(icon: PhosphorIconsRegular.package, title: i.name, subtitle: [i.brand, i.model].whereType<String>().join(' · '), onTap: () => context.push('/items/${i.itemId}')),
          const SizedBox(height: 16),
        ]);
      },
    );
  }
}

class EmailForwardingScreen extends ConsumerWidget {
  const EmailForwardingScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final addr = ref.watch(forwardingProvider);
    final log = ref.watch(inboundLogProvider).value ?? const <InboundEmail>[];
    final me = ref.watch(meProvider).value;
    final repo = ref.read(householdRepositoryProvider);
    Future<void> rotate() async {
      try {
        await repo.rotateAddress();
        ref.invalidate(forwardingProvider);
      } catch (e) {
        if (context.mounted) showFailure(context, e);
      }
    }

    if (me != null && !me.plan.emailForwarding) {
      return WScreen(title: 'Email forwarding', children: [
        WEmpty(
          icon: PhosphorIconsRegular.envelopeSimple,
          title: 'Forward receipts by email',
          message: 'Pro gives you a private address. Each forward becomes a draft you review. We never read your inbox.',
          action: WButton('See Pro', expand: false, onPressed: () => context.push('/settings/paywall')),
        ),
      ]);
    }
    return WScreen(title: 'Email forwarding', children: [
      Text('Forward receipts here', style: context.t.titleLarge),
      Text('Each forward becomes a draft you review. We never read your inbox.', style: TextStyle(color: c.textMuted)),
      const SizedBox(height: 14),
      AsyncBody<ForwardingAddress?>(
        value: addr,
        data: (a) => a == null
            ? WButton('Create my address', onPressed: rotate)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                WCard(child: SelectableText(a.address, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.text))),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: WButton('Copy', icon: PhosphorIconsRegular.copy, onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: a.address));
                    if (context.mounted) showToast(context, 'Copied');
                  })),
                  const SizedBox(width: 8),
                  Expanded(child: WButton.secondary('New address', icon: PhosphorIconsRegular.arrowsClockwise, onPressed: () async {
                    final ok = await confirmDialog(context, title: 'Get a new address?', message: 'The old address stops accepting email immediately.', confirm: 'New address');
                    if (ok) await rotate();
                  })),
                ]),
                WButton.ghost('Turn off forwarding', onPressed: () async {
                  await repo.disableAddress();
                  ref.invalidate(forwardingProvider);
                }),
              ]),
      ),
      WSectionHeader('Recent', action: 'Drafts', onAction: () => context.push('/drafts')),
      if (log.isEmpty) Text('Nothing received yet.', style: TextStyle(color: c.textMuted)),
      for (final e in log)
        WListRow(
          icon: e.state == 'rejected' ? PhosphorIconsRegular.fileX : PhosphorIconsRegular.fileText,
          title: e.state == 'rejected' ? 'Rejected · ${e.reason ?? 'not accepted'}' : '${e.attachments} attachment${e.attachments == 1 ? '' : 's'} · ${titleCase(e.state)}',
          subtitle: fmtDate(e.receivedAt),
          onTap: e.draftId == null ? null : () => context.push('/drafts'),
        ),
      const SizedBox(height: 10),
      Text('PDF and image attachments up to 10 MB from your account email. Unknown senders are ignored.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
    ]);
  }
}

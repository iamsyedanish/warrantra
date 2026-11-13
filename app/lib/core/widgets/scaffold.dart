import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../errors/failure.dart';
import '../theme/tokens.dart';
import 'buttons.dart';
import 'display.dart';

/// Standard pushed screen: back/close button, title, optional actions,
/// scrollable body and a pinned bottom action area.
class WScreen extends StatelessWidget {
  const WScreen({
    super.key,
    this.title,
    required this.children,
    this.bottom,
    this.actions = const [],
    this.close = false,
    this.padding,
    this.onBack,
    this.scroll = true,
    this.showBack = true,
  });

  final String? title;
  final List<Widget> children;
  final Widget? bottom;
  final List<Widget> actions;
  final bool close;
  final EdgeInsets? padding;
  final VoidCallback? onBack;
  final bool scroll;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final body = Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Row(
                children: [
                  if (showBack)
                    WIconButton(
                      close ? PhosphorIconsRegular.x : PhosphorIconsRegular.caretLeft,
                      tooltip: close ? 'Close' : 'Back',
                      onPressed: onBack ?? () => context.canPop() ? context.pop() : context.go('/home'),
                    ),
                  Expanded(
                    child: Text(
                      title ?? '',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: c.text),
                    ),
                  ),
                  if (actions.isEmpty && showBack) const SizedBox(width: 40) else Row(mainAxisSize: MainAxisSize.min, children: actions),
                ],
              ),
            ),
            Expanded(child: scroll ? SingleChildScrollView(child: body) : body),
            if (bottom != null)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                decoration: BoxDecoration(
                  color: c.bg,
                  border: Border(top: BorderSide(color: c.divider)),
                ),
                child: bottom,
              ),
          ],
        ),
      ),
    );
  }
}

/// Big heading block used at the top of most screens.
class WHeading extends StatelessWidget {
  const WHeading(this.title, {super.key, this.overline, this.subtitle, this.large = false});
  final String title;
  final String? overline;
  final String? subtitle;
  final bool large;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (overline != null) ...[Text(overline!, style: TextStyle(fontSize: 13, color: c.textMuted)), const SizedBox(height: 4)],
          Text(title, style: large ? context.t.headlineMedium : context.t.headlineSmall),
          if (subtitle != null) ...[const SizedBox(height: 6), Text(subtitle!, style: TextStyle(fontSize: 14.5, height: 1.5, color: c.textMuted))],
        ],
      ),
    );
  }
}

/// Renders an AsyncValue with consistent loading / error (with retry) states.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.data, this.onRetry, this.loading});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: data,
      loading: () =>
          loading ??
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
      error: (e, _) => ErrorView(failure: e is Failure ? e : Failure.unknown, onRetry: onRetry),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.failure, this.onRetry});
  final Failure failure;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    return WEmpty(
      icon: failure.isOffline ? PhosphorIconsRegular.cloudSlash : PhosphorIconsRegular.warningCircle,
      title: failure.isOffline ? "You're offline" : "Couldn't load this",
      message: failure.message,
      action: onRetry == null ? null : WButton.secondary('Try again', onPressed: onRetry, expand: false),
    );
  }
}

/// Feedback helpers.
void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

void showFailure(BuildContext context, Object error) {
  showToast(context, error is Failure ? error.message : Failure.unknown.message);
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = false,
  IconData? icon,
}) async {
  final c = context.w;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: icon == null ? null : Icon(icon, color: c.accent),
      title: Text(title, style: ctx.t.titleLarge),
      content: Text(message, style: TextStyle(fontSize: 14.5, height: 1.5, color: c.textMuted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: TextStyle(color: c.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            confirm,
            style: TextStyle(color: destructive ? c.danger : c.accent, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  return ok ?? false;
}

Future<T?> showWSheet<T>(BuildContext context, {required Widget Function(BuildContext) builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom), child: builder(ctx)),
  );
}

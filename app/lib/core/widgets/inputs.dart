import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../theme/tokens.dart';

/// Labeled text field with optional evidence/helper line (prototype review form).
class WField extends StatelessWidget {
  const WField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.error,
    this.keyboardType,
    this.obscure = false,
    this.maxLines = 1,
    this.onChanged,
    this.readOnly = false,
    this.onTap,
    this.suffix,
    this.inputFormatters,
    this.textInputAction,
    this.autofillHints,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final String? error;
  final TextInputType? keyboardType;
  final bool obscure;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final bool readOnly;
  final VoidCallback? onTap;
  final Widget? suffix;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textMuted),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            obscureText: obscure,
            maxLines: obscure ? 1 : maxLines,
            minLines: maxLines > 1 ? 3 : 1,
            onChanged: onChanged,
            readOnly: readOnly,
            onTap: onTap,
            inputFormatters: inputFormatters,
            textInputAction: textInputAction,
            autofillHints: autofillHints,
            style: TextStyle(fontSize: 15, color: c.text),
            decoration: InputDecoration(hintText: hint, suffixIcon: suffix, errorText: error),
          ),
          if (helper != null) ...[const SizedBox(height: 4), Text(helper!, style: TextStyle(fontSize: 12, color: c.textSubtle))],
        ],
      ),
    );
  }
}

/// Date picker field showing a formatted date (ISO value in the controller).
class WDateField extends StatelessWidget {
  const WDateField({super.key, required this.label, required this.value, required this.onChanged, this.hint = 'Not set', this.helper, this.allowClear = true});
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final String hint;
  final String? helper;
  final bool allowClear;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final text = value == null ? '' : MaterialLocalizations.of(context).formatMediumDate(value!);
    return WField(
      label: label,
      controller: TextEditingController(text: text),
      hint: hint,
      helper: helper,
      readOnly: true,
      suffix: value != null && allowClear
          ? IconButton(
              icon: Icon(PhosphorIconsRegular.x, size: 16, color: c.textSubtle),
              onPressed: () => onChanged(null),
            )
          : Icon(PhosphorIconsRegular.calendarBlank, size: 18, color: c.textSubtle),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(context: context, initialDate: value ?? now, firstDate: DateTime(1990), lastDate: DateTime(now.year + 15));
        if (picked != null) onChanged(picked);
      },
    );
  }
}

/// Single-choice pill group (prototype option buttons).
class WChoiceChips<T> extends StatelessWidget {
  const WChoiceChips({super.key, required this.options, required this.value, required this.onChanged, this.label});
  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(
              label!,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textMuted),
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final (v, text) in options) _Pill(text: text, selected: v == value, onTap: () => onChanged(v))],
          ),
        ],
      ),
    );
  }
}

/// Multi-select pills (reminder offsets, filters).
class WMultiChips<T> extends StatelessWidget {
  const WMultiChips({super.key, required this.options, required this.values, required this.onChanged, this.label});
  final List<(T, String)> options;
  final Set<T> values;
  final ValueChanged<Set<T>> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(
              label!,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textMuted),
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (v, text) in options)
                _Pill(text: text, selected: values.contains(v), onTap: () => onChanged(values.contains(v) ? ({...values}..remove(v)) : ({...values, v}))),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.selected, required this.onTap});
  final String text;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.accentSoft : c.surface,
        shape: StadiumBorder(side: BorderSide(color: selected ? c.accent : c.divider)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: selected ? c.accentSoftText : c.text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Checkbox row (receipt lines, evidence picker, acceptance toggles).
class WCheckRow extends StatelessWidget {
  const WCheckRow({super.key, required this.value, required this.onChanged, required this.title, this.subtitle, this.trailing, this.radio = false});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool radio;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final icon = radio
        ? (value ? PhosphorIconsFill.radioButton : PhosphorIconsRegular.circle)
        : (value ? PhosphorIconsFill.checkSquare : PhosphorIconsRegular.square);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(WRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: value ? c.accent : c.textSubtle),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: c.text),
                  ),
                  if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12.5, height: 1.4, color: c.textMuted)),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// Settings-style switch row.
class WSwitchRow extends StatelessWidget {
  const WSwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.text),
                ),
                if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12.5, height: 1.4, color: c.textMuted)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

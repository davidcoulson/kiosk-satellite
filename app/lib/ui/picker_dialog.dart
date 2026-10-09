import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The frame the big pickers (dashboard views, entities, players) open
/// in: a 760 by 560 dialog on a roomy screen, full screen under 640. Pair
/// it with `barrierDismissible: false`: it closes on an outside tap
/// itself, after its first half second, so the second tap of a double tap
/// on the field that opened it does not close it again.
class PickerDialog<T> extends StatefulWidget {
  const PickerDialog({super.key, required this.title, required this.builder});

  final String title;
  final Widget Function(void Function(T?) close) builder;

  @override
  State<PickerDialog<T>> createState() => _PickerDialogState<T>();
}

class _PickerDialogState<T> extends State<PickerDialog<T>> {
  final _openedAt = DateTime.now();

  void _close(T? value) => Navigator.of(context).pop(value);

  /// An outside tap closes the picker, but not the second tap of a double
  /// tap on the field: that lands outside the dialog the first one opened.
  void _outsideTap() {
    if (DateTime.now().difference(_openedAt).inMilliseconds > 500) {
      _close(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.width < 640) {
      return Dialog.fullscreen(child: SafeArea(child: widget.builder(_close)));
    }
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _outsideTap,
          ),
        ),
        Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 760,
            height: math.min(560.0, size.height - 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: widget.builder(_close),
            ),
          ),
        ),
      ],
    );
  }
}

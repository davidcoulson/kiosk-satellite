import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints [child] into an image once and reuses the image until [content]
/// changes.
///
/// For text with blurred shadows over a scene that repaints every frame.
/// Impeller has no raster cache, so every blurred shadow otherwise goes
/// through offscreen blur passes on every frame: in windy Weather Mood
/// scenes the clock and chip shadows cost a Galaxy Tab S8 about 80% of a
/// core and a tenth of its frames. [content] must cover everything the
/// child shows, since the image is only redrawn when it changes or the
/// size does.
///
/// [bleed] is how far the shadows reach past the child's box. The image
/// takes that margin in too, without changing the layout.
///
/// The child stays mounted across content changes and only the image is
/// retaken, so a child that settles over a few frames (an icon read from
/// the bundle) keeps what it already loaded. Such a child calls [refresh]
/// once it has drawn its final look.
class TextSnapshot extends StatefulWidget {
  const TextSnapshot({
    super.key,
    required this.content,
    required this.bleed,
    required this.child,
  });

  final Object content;
  final double bleed;
  final Widget child;

  /// Retakes the image of the snapshot around [context], if there is one.
  static void refresh(BuildContext context) => context
      .getInheritedWidgetOfExactType<_SnapshotScope>()
      ?.controller
      .clear();

  @override
  State<TextSnapshot> createState() => _TextSnapshotState();
}

class _TextSnapshotState extends State<TextSnapshot> {
  final _controller = SnapshotController(allowSnapshotting: true);

  @override
  void didUpdateWidget(TextSnapshot old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content) _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Bleed(
    bleed: widget.bleed,
    child: SnapshotWidget(
      controller: _controller,
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: _SnapshotScope(
        controller: _controller,
        child: Padding(
          padding: EdgeInsets.all(widget.bleed),
          child: widget.child,
        ),
      ),
    ),
  );
}

class _SnapshotScope extends InheritedWidget {
  const _SnapshotScope({required this.controller, required super.child});
  final SnapshotController controller;

  @override
  bool updateShouldNotify(_SnapshotScope old) => false;
}

/// Lays out and paints its child as if [bleed] of margin on every side
/// were not there.
class _Bleed extends SingleChildRenderObjectWidget {
  const _Bleed({required this.bleed, super.child});
  final double bleed;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBleed(bleed);

  @override
  void updateRenderObject(BuildContext context, _RenderBleed renderObject) =>
      renderObject.bleed = bleed;
}

class _RenderBleed extends RenderShiftedBox {
  _RenderBleed(this._bleed) : super(null);

  double _bleed;
  set bleed(double value) {
    if (value == _bleed) return;
    _bleed = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final margin = _bleed * 2;
    child.layout(
      BoxConstraints(
        minWidth: constraints.minWidth + margin,
        maxWidth: constraints.maxWidth + margin,
        minHeight: constraints.minHeight + margin,
        maxHeight: constraints.maxHeight + margin,
      ),
      parentUsesSize: true,
    );
    size = constraints.constrain(
      Size(child.size.width - margin, child.size.height - margin),
    );
    (child.parentData! as BoxParentData).offset = Offset(-_bleed, -_bleed);
  }
}

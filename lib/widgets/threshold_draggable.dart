import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A [Draggable] that starts only once the pointer has moved a few pixels,
/// like Windows' drag threshold. Flutter starts a mouse drag after a single
/// pixel, so the hand's jitter during a click or double click picked the item
/// up, and the click dropped it somewhere else.
class ThresholdDraggable<T extends Object> extends Draggable<T> {
  const ThresholdDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragEnd,
    super.onDraggableCanceled,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(GestureMultiDragStartCallback onStart) =>
      _ThresholdDragRecognizer()..onStart = onStart;
}

class _ThresholdDragRecognizer extends MultiDragGestureRecognizer {
  _ThresholdDragRecognizer() : super(debugOwner: null);

  /// Pixels the pointer must travel before a drag begins.
  static const double threshold = 6;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _ThresholdPointerState(event.position, event.kind, gestureSettings);

  @override
  String get debugDescription => 'threshold drag';
}

class _ThresholdPointerState extends MultiDragPointerState {
  _ThresholdPointerState(super.initialPosition, super.kind, super.deviceGestureSettings);

  /// Set when the arena gave us the pointer before it had moved far enough:
  /// on a plain row we are the arena's only member, and a lone member wins
  /// the moment the button goes down. Starting the drag right then is what
  /// turned every click into a drag.
  GestureMultiDragStartCallback? _starter;

  bool get _farEnough => pendingDelta!.distance > _ThresholdDragRecognizer.threshold;

  @override
  void checkForResolutionAfterMove() {
    if (!_farEnough) return;
    final starter = _starter;
    if (starter != null) {
      _starter = null;
      starter(initialPosition);
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    if (_farEnough) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void dispose() {
    _starter = null;
    super.dispose();
  }
}

import 'dart:math';

const _step = pi / 4;
const _margin = 5 * pi / 180;

/// The 45° step, from 0 to 7, that raster tiles bake their labels right side
/// up for, given the map [rotation] in radians and the [previous] step.
///
/// Every step change renders the visible tiles again, so a new step is only
/// taken once the rotation is a few degrees past the halfway point between
/// two steps. A map held near a boundary would otherwise go back and forth.
int uprightStep(double rotation, int previous) {
  var delta = (rotation - previous * _step) % (2 * pi);
  if (delta > pi) delta -= 2 * pi;
  if (delta.abs() <= _step / 2 + _margin) {
    return previous;
  }
  return (rotation / _step).round() % 8;
}

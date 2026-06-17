/// 2-state Kalman filter for angle estimation from gyro + accelerometer.
/// State: [angle (rad), gyro_bias (rad/s)]
class KalmanFilter {
  final double dt;
  final double qAngle;    // process noise: angle (rad²/s)
  final double qBias;     // process noise: bias  (rad²/s³)
  final double rMeasure;  // measurement noise: accel angle (rad²)

  double _angle = 0.0;
  double _bias  = 0.0;

  // Covariance matrix
  double _p00 = 0.0, _p01 = 0.0, _p10 = 0.0, _p11 = 0.0;

  bool _initialized = false;

  KalmanFilter({
    required this.dt,
    this.qAngle   = 0.001,
    this.qBias    = 0.003,
    this.rMeasure = 0.03,
  });

  /// [omega]      — gyro angular rate (rad/s) on the pitch axis
  /// [accelAngle] — pitch angle derived from accelerometer (rad), e.g. atan2(ay, az)
  /// Returns estimated angle (rad).
  double update(double omega, double accelAngle) {
    if (!_initialized) {
      _angle       = accelAngle;
      _initialized = true;
      return _angle;
    }

    // ── Predict ────────────────────────────────────────────────────────────
    _angle += dt * (omega - _bias);

    _p00 += dt * (dt * _p11 - _p01 - _p10 + qAngle);
    _p01 -= dt * _p11;
    _p10 -= dt * _p11;
    _p11 += qBias * dt;

    // ── Update ─────────────────────────────────────────────────────────────
    final s      = _p00 + rMeasure;
    final k0     = _p00 / s;
    final k1     = _p10 / s;
    final y      = accelAngle - _angle;

    _angle += k0 * y;
    _bias  += k1 * y;

    // (I − K·H)·P  — save originals to avoid overwrite ordering issues
    final origP00 = _p00, origP01 = _p01;
    _p00 -= k0 * origP00;
    _p01 -= k0 * origP01;
    _p10 -= k1 * origP00;
    _p11 -= k1 * origP01;

    return _angle;
  }

  void reset() {
    _angle       = 0.0;
    _bias        = 0.0;
    _p00 = _p01 = _p10 = _p11 = 0.0;
    _initialized = false;
  }
}

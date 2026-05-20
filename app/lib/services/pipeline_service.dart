import 'dart:math' as math;
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/services/mahony_filter.dart';

// ── Median filter ─────────────────────────────────────────────────────────────

class _MedianFilter {
  final int _window;
  final List<double> _buf = [];

  _MedianFilter(this._window);

  double update(double value) {
    _buf.add(value);
    if (_buf.length > _window) _buf.removeAt(0);
    final sorted = List.of(_buf)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  void reset() => _buf.clear();
}

// ── Butterworth LP filter (4th order, 10 Hz @ 100 Hz, SOS) ───────────────────
// Coefficients computed via bilinear transform:
//   Section 0: b=[0.07796, 0.15591, 0.07796], a=[1, -1.3208, 0.6327]
//   Section 1: b=[0.06189, 0.12378, 0.06189], a=[1, -1.0485, 0.2961]

class _ButterworthFilter {
  double _s0z1 = 0, _s0z2 = 0;
  double _s1z1 = 0, _s1z2 = 0;

  double update(double x) {
    // Section 0
    final w0 = x + 1.3208 * _s0z1 - 0.6327 * _s0z2;
    final y0 = 0.07796 * w0 + 0.15591 * _s0z1 + 0.07796 * _s0z2;
    _s0z2 = _s0z1;
    _s0z1 = w0;
    // Section 1
    final w1 = y0 + 1.0485 * _s1z1 - 0.2961 * _s1z2;
    final y1 = 0.06189 * w1 + 0.12378 * _s1z1 + 0.06189 * _s1z2;
    _s1z2 = _s1z1;
    _s1z1 = w1;
    return y1;
  }

  void reset() => _s0z1 = _s0z2 = _s1z1 = _s1z2 = 0;
}

// ── Pipeline service ──────────────────────────────────────────────────────────

class _StaticSample {
  final double accelNorm;
  final double theta;
  _StaticSample(this.accelNorm, this.theta);
}

class PipelineService {
  static const double accelScale = 1.0 / 8192.0;
  static const double gyroScale  = (math.pi / 180.0) / 65.5;

  // Hard limits (algorithm failure, not biology)
  static const double _tauStHardMax      = 98.0;   // %
  static const double _strideTimeHardMin =  0.3;   // s
  static const double _madK              =  6.0;
  static const int    _madWindow         = 20;

  final int    gyroAxis;
  final double swingEntryOmega;
  final double swingExitRatio;
  final int    minSwingSamples;
  final double accelSwingThresh;
  final int    stridesPerReturn;
  final int    calibStrides;
  final int    staticCalibSamples;

  late final MahonyFilter      _filter;
  late final _ButterworthFilter _butter;
  late final List<_MedianFilter> _med;  // 6 channels: ax ay az gx gy gz

  // Phase 0: static gravity calibration
  bool   _staticPhase          = true;
  final List<_StaticSample> _staticBuf = [];
  double _gravityMagnitude     = 1.0;
  double _accelSwingDynThresh  = 0.15;

  // Phase 1: dynamic calibration
  bool   _calibrated    = false;
  int    _calibCount    = 0;
  double _thetaRef      = 0.0;         // degrees
  final List<List<double>> _calibData = [];
  List<double> _baselineMean = [0, 0, 0];
  List<double> _baselineStd  = [1, 1, 1];

  // Stride state machine
  bool   _inSwing      = false;
  double _swingStartTs = 0.0;
  double? _prevIcTs;
  List<double> _omegaBuf = [];
  int    _swingSamples  = 0;

  // Recent strides for adaptive MAD
  final List<double> _recentOmega = [];
  final List<double> _recentTau   = [];

  // Return aggregation
  final List<Map<String, double>> _returnStrideBuf = [];
  int _returnIndex = 0;
  int _strideNum   = 0;

  PipelineService({
    int sampleRate         = 100,
    this.gyroAxis          = 1,
    this.swingEntryOmega   = 0.35,
    this.swingExitRatio    = 0.6,
    this.minSwingSamples   = 10,
    this.accelSwingThresh  = 0.15,
    this.stridesPerReturn  = 6,
    this.calibStrides      = 40,
    this.staticCalibSamples = 200,
  }) {
    _filter = MahonyFilter(dt: 1.0 / sampleRate);
    _butter = _ButterworthFilter();
    _med    = List.generate(6, (_) => _MedianFilter(5));
  }

  PipelineResult process(
    double ts,
    int ax0, int ay0, int az0,
    int gx0, int gy0, int gz0,
    int ax1, int ay1, int az1,
    int gx1, int gy1, int gz1,
  ) {
    // Scale raw values
    final rawAx = ax0 * accelScale, rawAy = ay0 * accelScale, rawAz = az0 * accelScale;
    final rawGx = gx0 * gyroScale,  rawGy = gy0 * gyroScale,  rawGz = gz0 * gyroScale;

    // Median filter on raw signals
    final fAx = _med[0].update(rawAx);
    final fAy = _med[1].update(rawAy);
    final fAz = _med[2].update(rawAz);
    final fGx = _med[3].update(rawGx);
    final fGy = _med[4].update(rawGy);
    final fGz = _med[5].update(rawGz);

    // Mahony sensor fusion → pitch angle (rad)
    final thetaRaw = _filter.update(fAx, fAy, fAz, fGx, fGy, fGz);

    // Butterworth LP on angle
    final theta = _butter.update(thetaRaw);

    final omega     = [fGx, fGy, fGz][gyroAxis];
    final accelNorm = math.sqrt(fAx*fAx + fAy*fAy + fAz*fAz);

    // ── Phase 0: static gravity calibration ──────────────────────────────
    if (_staticPhase) {
      _staticBuf.add(_StaticSample(accelNorm, theta));
      final progress = (_staticBuf.length / staticCalibSamples).clamp(0.0, 1.0);
      if (_staticBuf.length >= staticCalibSamples) _finishStaticCalibration();
      return PipelineResult.staticCalib(
        calibProgress: progress,
        message: 'Stand still — gravity calibration',
      );
    }

    // ── Phase 1: dynamic calibration (walking) ────────────────────────────
    if (!_calibrated) {
      final stride = _segment(ts, theta, omega, accelNorm);
      if (stride != null) {
        _calibData.add([stride['omega_pico']!, stride['tau_st_pct']!, stride['alpha_atq']!]);
        _calibCount++;
        if (_calibCount >= calibStrides) _finishDynamicCalibration();
      }
      return PipelineResult.calibrating(
        calibProgress: (_calibCount / calibStrides).clamp(0.0, 1.0),
        thetaDeg: _toDeg(theta),
      );
    }

    // ── Phase 2: live ─────────────────────────────────────────────────────
    final stride = _segment(ts, theta, omega, accelNorm);
    ReturnData? returnData;

    if (stride != null) {
      _strideNum++;
      _returnStrideBuf.add({
        'omega_pico': stride['omega_pico']!,
        'tau_st_pct': stride['tau_st_pct']!,
        'alpha_atq':  stride['alpha_atq']!,
      });
      if (_returnStrideBuf.length >= stridesPerReturn) {
        returnData = _aggregateReturn();
      }
    }

    return PipelineResult.live(
      ts:        ts,
      theta:     _toDeg(theta),
      omega:     _toDeg(omega),
      accelNorm: accelNorm,
      stride: stride != null ? StrideData(
        omegaPico: stride['omega_pico']!,
        tauStPct:  stride['tau_st_pct']!,
        alphaAtq:  stride['alpha_atq']!,
        strideNum: _strideNum,
        elapsedS:  ts,
      ) : null,
      returnData: returnData,
    );
  }

  void _finishStaticCalibration() {
    final half   = _staticBuf.length ~/ 2;
    final stable = _staticBuf.sublist(half);

    final gravVals = stable.map((s) => s.accelNorm).toList();
    _gravityMagnitude = gravVals.reduce((a, b) => a + b) / gravVals.length;

    final variance = gravVals
        .map((v) => math.pow(v - _gravityMagnitude, 2).toDouble())
        .reduce((a, b) => a + b) / gravVals.length;
    final accelStd = math.sqrt(variance);
    _accelSwingDynThresh = math.max(3.0 * accelStd, 0.05);

    final thetaVals = stable.map((s) => s.theta).toList();
    _thetaRef = _toDeg(thetaVals.reduce((a, b) => a + b) / thetaVals.length);

    _staticPhase = false;
  }

  void _finishDynamicCalibration() {
    _baselineMean = _colMeans(_calibData);
    final std = _colStds(_calibData, _baselineMean);
    _baselineStd = std.map((s) => s < 1e-6 ? 1e-6 : s).toList();
    _calibrated  = true;
  }

  bool _isSwingEntry(double omega, double accelNorm) {
    final gyroCrit  = omega.abs() > swingEntryOmega;
    final accelDev  = (accelNorm - _gravityMagnitude).abs();
    final accelCrit = accelDev > _accelSwingDynThresh;
    return gyroCrit || accelCrit;
  }

  bool _isSwingExit(double omega, double accelNorm) {
    final exitThresh   = swingEntryOmega * swingExitRatio;
    final gyroSettled  = omega.abs() < exitThresh;
    final accelSettled = (accelNorm - _gravityMagnitude).abs() < _accelSwingDynThresh * 0.7;
    return gyroSettled && accelSettled;
  }

  Map<String, double>? _segment(double ts, double theta, double omega, double accelNorm) {
    if (!_inSwing && _isSwingEntry(omega, accelNorm)) {
      _inSwing      = true;
      _swingStartTs = ts;
      _omegaBuf     = [];
      _swingSamples = 0;
    }

    if (_inSwing) {
      _omegaBuf.add(omega.abs());
      _swingSamples++;

      if (_isSwingExit(omega, accelNorm) && _swingSamples > minSwingSamples) {
        final omegaPicoDeg = _toDeg(_omegaBuf.reduce(math.max));
        final swingTime    = ts - _swingStartTs;
        final prevIc       = _prevIcTs;
        _inSwing   = false;
        _prevIcTs  = ts;

        if (prevIc == null || (ts - prevIc) < 1e-6) return null;

        final strideTime = ts - prevIc;
        final stanceTime = (strideTime - swingTime).clamp(0.0, strideTime);
        final tauStPct   = (stanceTime / strideTime * 100.0).clamp(0.0, 100.0);
        final alphaAtq   = _toDeg(theta) - _thetaRef;

        if (!_isValidStride(omegaPicoDeg, tauStPct, strideTime)) return null;

        _registerStride(omegaPicoDeg, tauStPct);

        return {
          'omega_pico': double.parse(omegaPicoDeg.toStringAsFixed(2)),
          'tau_st_pct': double.parse(tauStPct.toStringAsFixed(2)),
          'alpha_atq':  double.parse(alphaAtq.toStringAsFixed(2)),
        };
      }
    }
    return null;
  }

  bool _isValidStride(double omegaPico, double tauStPct, double strideTime) {
    // Layer A: hard limits
    if (tauStPct > _tauStHardMax)      return false;
    if (strideTime < _strideTimeHardMin) return false;

    // Layer B: adaptive MAD (need ≥5 reference strides)
    if (_recentOmega.length >= 5) {
      if (!_madOk(omegaPico, _recentOmega)) return false;
      if (!_madOk(tauStPct,  _recentTau))   return false;
    }
    return true;
  }

  bool _madOk(double value, List<double> buf) {
    final sorted = List.of(buf)..sort();
    final mid    = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
    final diffs = buf.map((v) => (v - median).abs()).toList()..sort();
    final dMid  = diffs.length ~/ 2;
    final mad   = diffs.length.isOdd
        ? diffs[dMid]
        : (diffs[dMid - 1] + diffs[dMid]) / 2.0;
    if (mad < 1e-6) return true;
    return (value - median).abs() <= _madK * mad;
  }

  void _registerStride(double omegaPico, double tauStPct) {
    _recentOmega.add(omegaPico);
    _recentTau.add(tauStPct);
    if (_recentOmega.length > _madWindow) _recentOmega.removeAt(0);
    if (_recentTau.length   > _madWindow) _recentTau.removeAt(0);
  }

  ReturnData _aggregateReturn() {
    final data = _returnStrideBuf.map((s) =>
      [s['omega_pico']!, s['tau_st_pct']!, s['alpha_atq']!]
    ).toList();

    final medianVec = _colMedians(data);
    _returnStrideBuf.clear();
    _returnIndex++;

    List<double>? deviations;
    bool alert = false;

    if (_calibrated) {
      deviations = [
        -(medianVec[0] - _baselineMean[0]) / _baselineStd[0],
         (medianVec[1] - _baselineMean[1]) / _baselineStd[1],
        -(medianVec[2] - _baselineMean[2]) / _baselineStd[2],
      ];
      alert = deviations.where((d) => d.abs() > 2.0).length >= 2;
    }

    return ReturnData(
      n:          _returnIndex,
      omegaPico:  double.parse(medianVec[0].toStringAsFixed(2)),
      tauStPct:   double.parse(medianVec[1].toStringAsFixed(2)),
      alphaAtq:   double.parse(medianVec[2].toStringAsFixed(2)),
      deviations: deviations,
      alert:      alert,
    );
  }

  static double _toDeg(double rad) => rad * 180.0 / math.pi;

  static List<double> _colMeans(List<List<double>> m) {
    final n    = m.length;
    final cols = m[0].length;
    return List.generate(cols, (c) {
      double s = 0;
      for (final row in m) s += row[c];
      return s / n;
    });
  }

  static List<double> _colMedians(List<List<double>> m) {
    final cols = m[0].length;
    return List.generate(cols, (c) {
      final vals = m.map((row) => row[c]).toList()..sort();
      final mid  = vals.length ~/ 2;
      return vals.length.isOdd ? vals[mid] : (vals[mid - 1] + vals[mid]) / 2.0;
    });
  }

  static List<double> _colStds(List<List<double>> m, List<double> means) {
    final n = m.length;
    return List.generate(means.length, (c) {
      double s = 0;
      for (final row in m) s += math.pow(row[c] - means[c], 2);
      return math.sqrt(s / n);
    });
  }

  void reset() {
    _filter.reset();
    _butter.reset();
    for (final f in _med) f.reset();

    _staticPhase         = true;
    _staticBuf.clear();
    _gravityMagnitude    = 1.0;
    _accelSwingDynThresh = 0.15;

    _calibrated   = false;
    _calibCount   = 0;
    _calibData.clear();
    _thetaRef     = 0.0;
    _baselineMean = [0, 0, 0];
    _baselineStd  = [1, 1, 1];

    _inSwing      = false;
    _prevIcTs     = null;
    _omegaBuf     = [];
    _swingSamples = 0;

    _recentOmega.clear();
    _recentTau.clear();
    _returnStrideBuf.clear();
    _returnIndex  = 0;
    _strideNum    = 0;
  }
}

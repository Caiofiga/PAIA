import 'dart:math' as math;
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/services/mahony_filter.dart';

class PipelineService {
  static const double accelScale = 1.0 / 8192.0;
  static const double gyroScale  = (math.pi / 180.0) / 65.5;

  final double dt;
  final int    gyroAxis;
  final double swingEntryOmega;
  final double swingExitRatio;
  final int    minSwingSamples;
  final int    stridesPerReturn;
  final int    nWindow;
  final int    calibStrides;

  final MahonyFilter _filter;

  bool   _calibrated    = false;
  int    _calibCount    = 0;
  double _thetaRef      = 0.0;
  final List<List<double>> _calibData = [];
  List<double> _baselineMean = [0, 0, 0];
  List<double> _baselineStd  = [1, 1, 1];
  List<double> _slopeStd     = [1, 1, 1];

  bool   _inSwing       = false;
  double _swingStartTs  = 0.0;
  double? _prevIcTs;
  List<double> _omegaBuf = [];
  int    _swingSamples  = 0;

  final List<Map<String, double>> _returnStrideBuf = [];
  final List<List<double>> _returns = [];
  int _returnIndex = 0;
  int _strideNum   = 0;

  PipelineService({
    int sampleRate = 100,
    this.gyroAxis = 1,
    this.swingEntryOmega = 0.35,
    this.swingExitRatio  = 0.7,
    this.minSwingSamples = 10,
    this.stridesPerReturn = 6,
    this.nWindow = 4,
    this.calibStrides = 40,
  })  : dt = 1.0 / sampleRate,
        _filter = MahonyFilter(dt: 1.0 / sampleRate);

  PipelineResult process(
    double ts,
    int ax0, int ay0, int az0,
    int gx0, int gy0, int gz0,
    int ax1, int ay1, int az1,
    int gx1, int gy1, int gz1,
  ) {
    final ax = ax0 * accelScale;
    final ay = ay0 * accelScale;
    final az = az0 * accelScale;
    final gxyz = [gx0 * gyroScale, gy0 * gyroScale, gz0 * gyroScale];

    final theta = _filter.update(ax, ay, az, gxyz[0], gxyz[1], gxyz[2]);
    final omega  = gxyz[gyroAxis];

    if (!_calibrated) {
      final stride = _segment(ts, theta, omega);
      if (stride != null) {
        _calibData.add([stride['omega_pico']!, stride['tau_st_pct']!, stride['_theta_ic']!]);
        _calibCount++;
        if (_calibCount >= calibStrides) _finishCalibration();
      }
      return PipelineResult.calibrating(
        calibProgress: (_calibCount / calibStrides).clamp(0.0, 1.0),
        thetaDeg: _toDeg(theta),
      );
    }

    final stride = _segment(ts, theta, omega);
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
      ts:    ts,
      theta: _toDeg(theta),
      omega: _toDeg(omega),
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

  void _finishCalibration() {
    double sumTheta = 0;
    for (final d in _calibData) sumTheta += d[2];
    _thetaRef = sumTheta / _calibData.length;

    final params = _calibData.map((d) =>
      [d[0], d[1], _toDeg(d[2] - _thetaRef)]
    ).toList();

    _baselineMean = _colMeans(params);
    final std = _colStds(params, _baselineMean);
    _baselineStd = std.map((s) => s < 1e-6 ? 1e-6 : s).toList();
    _slopeStd    = List.of(_baselineStd);
    _calibrated  = true;
  }

  void forceCalibrated({
    required double thetaRef,
    required List<double> baselineMean,
    required List<double> baselineStd,
  }) {
    _thetaRef     = thetaRef;
    _baselineMean = baselineMean;
    _baselineStd  = baselineStd;
    _slopeStd     = List.of(baselineStd);
    _calibrated   = true;
  }

  Map<String, double>? _segment(double ts, double theta, double omega) {
    final exitThresh = swingEntryOmega * swingExitRatio;

    if (!_inSwing && omega.abs() > swingEntryOmega) {
      _inSwing      = true;
      _swingStartTs = ts;
      _omegaBuf     = [];
      _swingSamples = 0;
    }

    if (_inSwing) {
      _omegaBuf.add(omega.abs());
      _swingSamples++;

      if (omega.abs() < exitThresh && _swingSamples > minSwingSamples) {
        final omegaPicoDeg = _toDeg(_omegaBuf.reduce(math.max));
        final swingTime    = ts - _swingStartTs;
        final prevIc       = _prevIcTs;
        _inSwing   = false;
        _prevIcTs  = ts;

        if (prevIc == null || (ts - prevIc) < 1e-6) return null;

        final strideTime = ts - prevIc;
        final stanceTime = (strideTime - swingTime).clamp(0.0, strideTime);
        final tauStPct   = (stanceTime / strideTime * 100.0).clamp(0.0, 100.0);
        final alphaAtq   = _toDeg(theta - _thetaRef);

        return {
          'omega_pico':  double.parse(omegaPicoDeg.toStringAsFixed(2)),
          'tau_st_pct':  double.parse(tauStPct.toStringAsFixed(2)),
          'alpha_atq':   double.parse(alphaAtq.toStringAsFixed(2)),
          '_theta_ic':   theta,
        };
      }
    }
    return null;
  }

  ReturnData _aggregateReturn() {
    final data = _returnStrideBuf.map((s) =>
      [s['omega_pico']!, s['tau_st_pct']!, s['alpha_atq']!]
    ).toList();

    final meanVec = _colMeans(data);
    _returns.add(meanVec);
    _returnStrideBuf.clear();
    _returnIndex++;

    double? it;
    List<double>? normSlopes;
    bool alert = false;

    if (_returns.length >= 2) {
      final trend = _computeTrend();
      it         = trend['IT'];
      normSlopes = [trend['ns0']!, trend['ns1']!, trend['ns2']!];
      alert      = normSlopes.where((s) => s.abs() > 2.0).length >= 2;
    }

    return ReturnData(
      n:          _returnIndex,
      omegaPico:  double.parse(meanVec[0].toStringAsFixed(2)),
      tauStPct:   double.parse(meanVec[1].toStringAsFixed(2)),
      alphaAtq:   double.parse(meanVec[2].toStringAsFixed(2)),
      it:         it,
      normSlopes: normSlopes,
      alert:      alert,
    );
  }

  Map<String, double> _computeTrend() {
    final window = _returns.length > nWindow
        ? _returns.sublist(_returns.length - nWindow)
        : List.of(_returns);
    final m = window.length;
    final xBar = (m - 1) / 2.0;
    double denom = 0;
    for (int i = 0; i < m; i++) denom += (i - xBar) * (i - xBar);
    denom += 1e-12;

    final slopes = List.generate(3, (col) {
      double yBar = 0;
      for (int i = 0; i < m; i++) yBar += window[i][col];
      yBar /= m;
      double num = 0;
      for (int i = 0; i < m; i++) num += (i - xBar) * (window[i][col] - yBar);
      return num / denom;
    });

    final signed = [-slopes[0], slopes[1], -slopes[2]];
    final norm   = List.generate(3, (i) => signed[i] / _slopeStd[i]);
    final it     = norm.reduce((a, b) => a + b) / 3.0;

    return {
      'IT':  double.parse(it.toStringAsFixed(3)),
      'ns0': double.parse(norm[0].toStringAsFixed(3)),
      'ns1': double.parse(norm[1].toStringAsFixed(3)),
      'ns2': double.parse(norm[2].toStringAsFixed(3)),
    };
  }

  static double _toDeg(double rad) => rad * 180.0 / math.pi;

  static List<double> _colMeans(List<List<double>> m) {
    final n    = m.length;
    final cols = m[0].length;
    return List.generate(cols, (c) {
      double s = 0; for (final row in m) s += row[c];
      return s / n;
    });
  }

  static List<double> _colStds(List<List<double>> m, List<double> means) {
    final n = m.length;
    return List.generate(means.length, (c) {
      double s = 0;
      for (final row in m) s += (row[c] - means[c]) * (row[c] - means[c]);
      return math.sqrt(s / n);
    });
  }

  void reset() {
    _filter.reset();
    _calibrated   = false;
    _calibCount   = 0;
    _calibData.clear();
    _inSwing      = false;
    _prevIcTs     = null;
    _omegaBuf     = [];
    _swingSamples = 0;
    _returnStrideBuf.clear();
    _returns.clear();
    _returnIndex  = 0;
    _strideNum    = 0;
  }
}

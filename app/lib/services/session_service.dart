import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/models/sensor_packet.dart';
import 'package:paia/models/session_record.dart';

/// Manages four CSV files per training session:
///
///   _calib.csv   — calibration baseline (one row, written once)
///   _raw.csv     — continuous raw IMU packets at ~100 Hz, col: mode
///   _strides.csv — all computed strides (corrida + retorno), col: mode
///   _returns.csv — only return-window strides (subset), col: bateria
///
/// Mode column values: "corrida" | "retorno"
///
/// Return detection:
///   - START: automatic — cadence drops below [returnCadenceThresh] for
///            [returnConfirmStrides] consecutive strides.
///   - END:   explicit — caller invokes [endReturn()] (tied to "Nova Bateria"
///            button press).  Also ends automatically if cadence rises back
///            above the running threshold for [runningConfirmStrides] strides.
class SessionService {
  // ── Config ────────────────────────────────────────────────────────────────

  /// Strides per minute below which we consider the athlete is walking back.
  final double returnCadenceThresh;

  /// How many consecutive low-cadence strides before activating return mode.
  final int returnConfirmStrides;

  /// How many consecutive high-cadence strides before auto-ending return mode.
  final int runningConfirmStrides;

  SessionService({
    this.returnCadenceThresh   = 130.0,  // steps/min — walking < ~130
    this.returnConfirmStrides  = 4,
    this.runningConfirmStrides = 3,
  });

  // ── File sinks ────────────────────────────────────────────────────────────

  IOSink? _calibSink;
  IOSink? _rawSink;
  IOSink? _stridesSink;
  IOSink? _returnsSink;

  // ── State ─────────────────────────────────────────────────────────────────

  bool   _active       = false;
  bool   _calibWritten = false;
  int    _strideCount  = 0;
  int    _returnStrideCount = 0;
  String _label        = '';

  // Return detection
  bool   _inReturn          = false;
  int    _currentBateria    = 0;   // increments each time endReturn() is called
  double _lastStrideTs      = 0;
  int    _lowCadenceCount   = 0;
  int    _highCadenceCount  = 0;

  // Last athlete name — persisted across "Nova Bateria" flows
  String _lastAthleteName = '';

  // Raw packet subscription (set once via attachRawStream)
  StreamSubscription<({double timeS, SensorPacket pkt})>? _rawSub;

  final _newSessionCtrl = StreamController<void>.broadcast();
  final _strideCtrl     = StreamController<StrideData>.broadcast();
  final _returnModeCtrl = StreamController<bool>.broadcast();

  // ── Public getters ────────────────────────────────────────────────────────

  bool   get isActive       => _active;
  int    get strideCount    => _strideCount;
  String get label          => _label;
  bool   get inReturn       => _inReturn;
  int    get currentBateria => _currentBateria;
  String get lastAthleteName => _lastAthleteName;

  Stream<void>       get onNewSession  => _newSessionCtrl.stream;
  Stream<StrideData> get strideStream  => _strideCtrl.stream;
  /// Emits true when return mode starts, false when it ends.
  Stream<bool>       get returnMode    => _returnModeCtrl.stream;

  bool isCurrentSession(String fileName) =>
      _active && (fileName.startsWith(_label) || _label.startsWith(fileName));

  // ── Attach raw packet stream (call once from main after services created) ─

  void attachRawStream(Stream<({double timeS, SensorPacket pkt})> stream) {
    _rawSub?.cancel();
    _rawSub = stream.listen(_onRawPacket);
  }

  void _onRawPacket(({double timeS, SensorPacket pkt}) rec) {
    if (!_active || _rawSink == null) return;
    final mode = _inReturn ? 'retorno' : 'corrida';
    final pkt  = rec.pkt;
    _rawSink!.writeln(
      '${rec.timeS.toStringAsFixed(4)},'
      '${pkt.ax0},${pkt.ay0},${pkt.az0},'
      '${pkt.gx0},${pkt.gy0},${pkt.gz0},'
      '${pkt.ax1},${pkt.ay1},${pkt.az1},'
      '${pkt.gx1},${pkt.gy1},${pkt.gz1},'
      '$mode',
    );
  }

  // ── Open a new training session (full onboarding) ─────────────────────────

  Future<void> newSession({SessionMetadata? meta}) async {
    await _closeFiles();

    if (meta != null) _lastAthleteName = meta.athleteName;

    final dir = await getApplicationDocumentsDirectory();
    final ts  = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;

    _label            = 'session_$ts';
    _strideCount      = 0;
    _returnStrideCount = 0;
    _calibWritten     = false;
    _inReturn         = false;
    _currentBateria   = 1;
    _lowCadenceCount  = 0;
    _highCadenceCount = 0;

    final base       = '${dir.path}/$_label';
    final metaLines  = _buildMetaHeader(meta);

    _calibSink   = File('${base}_calib.csv').openWrite();
    _rawSink     = File('${base}_raw.csv').openWrite();
    _stridesSink = File('${base}_strides.csv').openWrite();
    _returnsSink = File('${base}_returns.csv').openWrite();

    _calibSink!
      ..write(metaLines)
      ..writeln('omega_mean,tau_mean,alpha_mean,'
                'omega_std,tau_std,alpha_std,'
                'gravity_g,theta_ref_deg');

    _rawSink!
      ..write(metaLines)
      ..writeln('time_s,'
                'ax0,ay0,az0,gx0,gy0,gz0,'
                'ax1,ay1,az1,gx1,gy1,gz1,'
                'mode');

    _stridesSink!
      ..write(metaLines)
      ..writeln('stride,time_s,omega_pico_degs,tau_st_pct,alpha_atq_deg,mode');

    _returnsSink!
      ..write(metaLines)
      ..writeln('stride,time_s,omega_pico_degs,tau_st_pct,alpha_atq_deg,bateria');

    _active = true;

    await Future.wait([
      _calibSink!.flush(),
      _rawSink!.flush(),
      _stridesSink!.flush(),
      _returnsSink!.flush(),
    ]);

    _newSessionCtrl.add(null);
  }

  // ── Start a new battery (fast flow — PSE + spasticity only) ──────────────

  void newBateria({required int pse, required int spasticity}) {
    if (!_active) return;

    if (_inReturn) _setReturn(false);

    _currentBateria++;

    final marker = '# bateria: $_currentBateria  pse: $pse  spasticity: $spasticity';
    _stridesSink?.writeln(marker);
    _returnsSink?.writeln(marker);
    _rawSink?.writeln(marker);
  }

  // ── Calibration baseline ──────────────────────────────────────────────────

  void logCalibration({
    required List<double> baselineMean,
    required List<double> baselineStd,
    required double gravityG,
    required double thetaRefDeg,
  }) {
    if (!_active || _calibSink == null || _calibWritten) return;
    _calibWritten = true;
    _calibSink!.writeln(
      '${baselineMean[0].toStringAsFixed(4)},'
      '${baselineMean[1].toStringAsFixed(4)},'
      '${baselineMean[2].toStringAsFixed(4)},'
      '${baselineStd[0].toStringAsFixed(4)},'
      '${baselineStd[1].toStringAsFixed(4)},'
      '${baselineStd[2].toStringAsFixed(4)},'
      '${gravityG.toStringAsFixed(6)},'
      '${thetaRefDeg.toStringAsFixed(4)}',
    );
  }

  // ── Computed stride ───────────────────────────────────────────────────────

  void logStride(StrideData s) {
    if (!_active || _stridesSink == null) return;

    _updateReturnDetection(s);

    final mode = _inReturn ? 'retorno' : 'corrida';

    _strideCount++;
    _stridesSink!.writeln(
      '$_strideCount,${s.elapsedS.toStringAsFixed(3)},'
      '${s.omegaPico},${s.tauStPct},${s.alphaAtq},'
      '$mode',
    );

    if (_inReturn && _returnsSink != null) {
      _returnStrideCount++;
      _returnsSink!.writeln(
        '$_returnStrideCount,${s.elapsedS.toStringAsFixed(3)},'
        '${s.omegaPico},${s.tauStPct},${s.alphaAtq},'
        '$_currentBateria',
      );
    }

    _strideCtrl.add(s);
  }

  // ── Explicit end of return (called by "Nova Bateria" button) ─────────────

  void endReturn() {
    if (_inReturn) _setReturn(false);
  }

  // ── Return detection ──────────────────────────────────────────────────────

  void _updateReturnDetection(StrideData s) {
    final strideTime = (_lastStrideTs > 0)
        ? (s.elapsedS - _lastStrideTs)
        : null;
    _lastStrideTs = s.elapsedS;

    if (strideTime == null || strideTime <= 0) return;

    // Convert stride time to cadence: one stride = 2 steps
    final cadence = (2 / strideTime) * 60.0; // steps/min

    if (!_inReturn) {
      if (cadence < returnCadenceThresh) {
        _lowCadenceCount++;
        _highCadenceCount = 0;
        if (_lowCadenceCount >= returnConfirmStrides) {
          _setReturn(true);
        }
      } else {
        _lowCadenceCount = 0;
      }
    } else {
      if (cadence >= returnCadenceThresh) {
        _highCadenceCount++;
        _lowCadenceCount = 0;
        if (_highCadenceCount >= runningConfirmStrides) {
          _setReturn(false);
        }
      } else {
        _highCadenceCount = 0;
      }
    }
  }

  void _setReturn(bool active) {
    if (_inReturn == active) return;
    _inReturn = active;
    _lowCadenceCount  = 0;
    _highCadenceCount = 0;
    _returnModeCtrl.add(active);
  }

  // ── Close ─────────────────────────────────────────────────────────────────

  Future<void> close() async {
    _active = false;
    await _closeFiles();
  }

  Future<void> _closeFiles() async {
    await Future.wait([
      if (_calibSink   != null) _calibSink!.flush().then((_) => _calibSink!.close()),
      if (_rawSink     != null) _rawSink!.flush().then((_) => _rawSink!.close()),
      if (_stridesSink != null) _stridesSink!.flush().then((_) => _stridesSink!.close()),
      if (_returnsSink != null) _returnsSink!.flush().then((_) => _returnsSink!.close()),
    ]);
    _calibSink   = null;
    _rawSink     = null;
    _stridesSink = null;
    _returnsSink = null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _buildMetaHeader(SessionMetadata? meta) {
    if (meta == null) return '';
    return '# athlete: ${meta.athleteName}\n'
           '# pse: ${meta.pse}\n'
           '# spasticity: ${meta.spasticity}\n';
  }
}

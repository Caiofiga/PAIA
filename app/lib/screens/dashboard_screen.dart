import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/services/pipeline_service.dart';
import 'package:paia/services/session_service.dart';
import 'package:paia/services/udp_service.dart';
import 'package:paia/widgets/live_chart.dart';
import 'package:paia/widgets/readout_card.dart';
import 'package:paia/widgets/return_table.dart';

const int _maxPts = 300;

class DashboardScreen extends StatefulWidget {
  final UdpService      udp;
  final SessionService  session;
  final PipelineService pipeline;

  const DashboardScreen({
    super.key,
    required this.udp,
    required this.session,
    required this.pipeline,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  StreamSubscription<PipelineResult>? _sub;
  bool _connected = false;

  bool   _started          = false;
  bool   _staticCalibDone  = false;
  bool   _calibrated       = false;
  double _calibProgress    = 0.0;
  double _calibTheta       = 0.0;
  String _staticMsg        = 'Stand still — gravity calibration';

  double _theta = 0, _omega = 0, _accelNorm = 0;
  double _wPico = 0, _tau   = 0, _aAtq = 0;

  final List<FlSpot> _thetaPts = [];
  final List<FlSpot> _omegaPts = [];

  int    _returnCount = 0;
  double _retWPico = 0, _retTau = 0, _retAAtq = 0;
  List<double>? _retDeviations;
  bool   _alert = false;
  final List<ReturnData> _returnRows = [];

  @override
  void initState() {
    super.initState();
    _startUdp();
  }

  Future<void> _startUdp() async {
    try {
      await widget.udp.start();
      setState(() => _connected = true);
      _sub = widget.udp.results.listen(_onResult);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('UDP error: $e')));
      }
    }
  }

  void _onResult(PipelineResult r) {
    if (!mounted) return;
    setState(() {
      if (r.type == PipelineType.staticCalib) {
        _calibProgress = r.calibProgress;
        _staticMsg     = r.message;
        return;
      }

      if (r.type == PipelineType.calibrating) {
        _staticCalibDone = true;
        _calibProgress   = r.calibProgress;
        _calibTheta      = r.thetaDeg;
        return;
      }

      _calibrated = true;
      _theta      = r.theta;
      _omega      = r.omega;
      _accelNorm  = r.accelNorm;

      _push(_thetaPts, r.ts, r.theta);
      _push(_omegaPts, r.ts, r.omega);

      if (r.stride != null) {
        final s = r.stride!;
        _wPico = s.omegaPico;
        _tau   = s.tauStPct;
        _aAtq  = s.alphaAtq;
        if (widget.session.isActive) widget.session.logStride(s);
      }

      if (r.returnData != null) {
        final rd = r.returnData!;
        _returnCount  = rd.n;
        _retWPico     = rd.omegaPico;
        _retTau       = rd.tauStPct;
        _retAAtq      = rd.alphaAtq;
        _retDeviations = rd.deviations;
        _alert        = rd.alert;
        _returnRows.add(rd);
        if (_returnRows.length > 100) _returnRows.removeAt(0);
      }
    });
  }

  void _push(List<FlSpot> pts, double x, double y) {
    pts.add(FlSpot(x, y));
    if (pts.length > _maxPts) pts.removeAt(0);
  }

  Future<void> _newSession() async {
    await widget.session.newSession();
    widget.pipeline.reset();
    setState(() {
      _staticCalibDone  = false;
      _calibrated       = false;
      _calibProgress    = 0.0;
      _calibTheta       = 0.0;
      _thetaPts.clear();
      _omegaPts.clear();
      _returnCount = 0;
      _retWPico = 0; _retTau = 0; _retAAtq = 0;
      _retDeviations = null; _alert = false;
      _returnRows.clear();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.udp.dispose();
    // ignore: discarded_futures
    widget.session.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTopBar(),
                  const SizedBox(height: 10),
                  if (_alert) _buildAlertBanner(),
                  if (_alert) const SizedBox(height: 10),
                  _buildReadouts(),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: LiveChart(
                      spots: List.of(_thetaPts),
                      lineColor: const Color(0xFF42A5F5),
                      title: 'TIBIA ANGLE θ (°)',
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: LiveChart(
                      spots: List.of(_omegaPts),
                      lineColor: const Color(0xFF66BB6A),
                      title: 'ANGULAR VELOCITY ω (°/s)',
                    )),
                  ]),
                  const SizedBox(height: 10),
                  _buildReturnStats(),
                  const SizedBox(height: 10),
                  ReturnTable(rows: List.of(_returnRows)),
                ],
              ),
            ),
          ),
          if (!_started) _buildIntroOverlay()
          else if (!_staticCalibDone) _buildStaticCalibOverlay()
          else if (!_calibrated) _buildCalibOverlay(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _chip(
          _connected ? '● Connected' : '● Connecting',
          _connected ? const Color(0xFF1B5E20) : const Color(0xFF263238),
          _connected ? const Color(0xFFA5D6A7) : const Color(0xFF90A4AE),
        ),
        const SizedBox(width: 8),
        _alertChip(),
        const Spacer(),
        if (widget.session.isActive)
          Text(widget.session.label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF546E7A))),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _newSession,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          child: Text(widget.session.isActive ? '⊕ New Session' : '⊕ Start',
            style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  Widget _alertChip() {
    if (_retDeviations == null) {
      return _chip('—', const Color(0xFF263238), const Color(0xFF90A4AE));
    }
    if (_alert) return _chip('⚠ ALERT', const Color(0xFFB71C1C), const Color(0xFFFFCDD2));
    return _chip('OK', const Color(0xFF1B5E20), const Color(0xFFA5D6A7));
  }

  Widget _chip(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: fg)),
  );

  Widget _buildAlertBanner() => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFFB71C1C),
      borderRadius: BorderRadius.circular(4),
    ),
    child: const Text('⚠ DETERIORATION DETECTED — ≥2 params beyond 2σ',
      style: TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _buildReadouts() => Wrap(
    spacing: 8, runSpacing: 8,
    children: [
      ReadoutCard(label: 'θ TIBIA ANGLE',     value: _theta.toStringAsFixed(1),     unit: '°'),
      ReadoutCard(label: 'ω ANG. VELOCITY',   value: _omega.toStringAsFixed(1),     unit: '°/s'),
      ReadoutCard(label: '|a| ACCEL NORM',    value: _accelNorm.toStringAsFixed(3), unit: 'g'),
      ReadoutCard(label: 'ωpico LAST STRIDE', value: _wPico.toStringAsFixed(1),     unit: '°/s'),
      ReadoutCard(label: 'τst% LAST STRIDE',  value: _tau.toStringAsFixed(1),       unit: '%'),
      ReadoutCard(label: 'αatq LAST STRIDE',  value: _aAtq.toStringAsFixed(1),      unit: '°'),
    ],
  );

  Widget _buildReturnStats() {
    final devs = _retDeviations;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: const Color(0xFF2C2C2C)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LAST RETURN SUMMARY',
            style: TextStyle(fontSize: 11, color: Color(0xFF78909C), letterSpacing: 1.0)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _statBox('Returns', '$_returnCount'),
            _statBox('ωpico',   _retWPico != 0 ? '${_retWPico.toStringAsFixed(1)} °/s' : '—'),
            _statBox('τst%',    _retTau   != 0 ? '${_retTau.toStringAsFixed(1)} %'     : '—'),
            _statBox('αatq',    _retAAtq  != 0 ? '${_retAAtq.toStringAsFixed(1)} °'    : '—'),
            _statBox('Δω',      devs != null ? devs[0].toStringAsFixed(2) : '—'),
            _statBox('Δτ',      devs != null ? devs[1].toStringAsFixed(2) : '—'),
            _statBox('Δα',      devs != null ? devs[2].toStringAsFixed(2) : '—'),
          ]),
        ],
      ),
    );
  }

  Widget _statBox(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFF161616),
      border: Border.all(color: const Color(0xFF222222)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF546E7A))),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
        color: Color(0xFFCFD8DC))),
    ]),
  );

  Widget _buildIntroOverlay() => Positioned.fill(
    child: Container(
      color: Colors.black87,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('PAIA',
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold,
              color: Color(0xFF42A5F5), letterSpacing: 4)),
          const SizedBox(height: 8),
          const Text('Biomechanical Running Monitor',
            style: TextStyle(fontSize: 14, color: Color(0xFF78909C))),
          const SizedBox(height: 52),
          ElevatedButton(
            onPressed: () async {
              await widget.session.newSession();
              widget.pipeline.reset();
              setState(() {
                _started          = true;
                _staticCalibDone  = false;
                _calibrated       = false;
                _calibProgress    = 0.0;
                _calibTheta       = 0.0;
                _thetaPts.clear();
                _omegaPts.clear();
                _returnCount = 0;
                _retWPico = 0; _retTau = 0; _retAAtq = 0;
                _retDeviations = null; _alert = false;
                _returnRows.clear();
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text('START',
              style: TextStyle(fontSize: 20, letterSpacing: 3, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 28),
          Text(
            _connected ? '● Sensor connected' : '● Waiting for sensor…',
            style: TextStyle(fontSize: 12,
              color: _connected ? const Color(0xFFA5D6A7) : const Color(0xFF546E7A)),
          ),
        ],
      ),
    ),
  );

  Widget _buildStaticCalibOverlay() => Positioned.fill(
    child: Container(
      color: Colors.black87,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Phase 1 — Gravity Calibration',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_staticMsg,
            style: const TextStyle(fontSize: 13, color: Color(0xFF78909C)),
            textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: LinearProgressIndicator(
              value: _calibProgress,
              backgroundColor: const Color(0xFF333333),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF66BB6A)),
              minHeight: 12,
            ),
          ),
          const SizedBox(height: 12),
          Text('${(_calibProgress * 100).toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 13, color: Color(0xFF78909C))),
        ],
      ),
    ),
  );

  Widget _buildCalibOverlay() => Positioned.fill(
    child: Container(
      color: Colors.black87,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Phase 2 — Walk Calibration',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('Athlete walk to track (~40 strides)',
            style: TextStyle(fontSize: 13, color: Color(0xFF78909C)),
            textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: LinearProgressIndicator(
              value: _calibProgress,
              backgroundColor: const Color(0xFF333333),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF42A5F5)),
              minHeight: 12,
            ),
          ),
          const SizedBox(height: 12),
          Text('θ = ${_calibTheta.toStringAsFixed(1)}°',
            style: const TextStyle(fontSize: 13, color: Color(0xFF78909C))),
        ],
      ),
    ),
  );
}

import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/models/session_record.dart';
import 'package:paia/services/pipeline_service.dart';
import 'package:paia/services/session_service.dart';
import 'package:paia/services/udp_service.dart';
import 'package:paia/widgets/live_chart.dart';
import 'package:paia/widgets/readout_card.dart';
import 'package:paia/widgets/return_table.dart';

const int _maxPts = 300;

enum _OnboardStep { name, placement, questionnaire }

// ── PSE helpers ───────────────────────────────────────────────────────────────

Color _pseColor(int v) {
  if (v <= 1) return const Color(0xFF42A5F5);
  if (v <= 3) return const Color(0xFF26C6DA);
  if (v <= 6) return const Color(0xFF66BB6A);
  if (v <= 8) return const Color(0xFFFFEE58);
  if (v == 9) return const Color(0xFFFFA726);
  return const Color(0xFFEF5350);
}

String _pseLabel(int v) => switch (v) {
  1     => 'Atividade Muito Leve',
  2     => 'Atividade Leve',
  3     => 'Atividade Leve',
  4     => 'Atividade Moderada',
  5     => 'Atividade Moderada',
  6     => 'Atividade Moderada',
  7     => 'Atividade Vigorosa',
  8     => 'Atividade Vigorosa',
  9     => 'Atividade Muito Difícil',
  10    => 'Esforço Máximo',
  _     => '',
};

// ── Spasticity helpers ────────────────────────────────────────────────────────

String _spasticityEmoji(int v) {
  if (v <= 1) return '😄';
  if (v <= 3) return '🙂';
  if (v <= 5) return '😐';
  if (v <= 7) return '😟';
  if (v <= 9) return '😢';
  return '😭';
}

Color _spasticityColor(int v) {
  if (v <= 2) return const Color(0xFF66BB6A);
  if (v <= 4) return const Color(0xFFA5D6A7);
  if (v <= 6) return const Color(0xFFFFEE58);
  if (v <= 8) return const Color(0xFFFFA726);
  return const Color(0xFFEF5350);
}

// ── Dashboard screen ──────────────────────────────────────────────────────────

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
  Timer? _connTimer;
  DateTime? _lastPacketTime;
  bool _connected = false;

  // ── App-level state ───────────────────────────────────────────────────────
  bool           _started        = false;
  _OnboardStep?  _onboardStep;   // null = not onboarding

  // Onboarding values
  final _nameCtrl = TextEditingController();
  int _pse         = 5;
  int _spasticity  = 5;

  // Calibration state
  bool   _staticCalibDone = false;
  bool   _calibrated      = false;
  double _calibProgress   = 0.0;
  double _calibTheta      = 0.0;
  String _staticMsg       = 'Stand still — gravity calibration';

  // Live telemetry
  double _theta = 0, _omega = 0, _accelNorm = 0;
  double _wPico = 0, _tau   = 0, _aAtq      = 0;

  final List<FlSpot> _thetaPts = [];
  final List<FlSpot> _omegaPts = [];

  // Return aggregation
  int    _returnCount    = 0;
  double _retWPico = 0, _retTau = 0, _retAAtq = 0;
  List<double>? _retDeviations;
  bool   _alert = false;
  final List<ReturnData> _returnRows = [];

  @override
  void initState() {
    super.initState();
    _startUdp();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _connTimer?.cancel();
    _sub?.cancel();
    widget.udp.dispose();
    // ignore: discarded_futures
    widget.session.close();
    super.dispose();
  }

  Future<void> _startUdp() async {
    try {
      await widget.udp.start();
      _sub = widget.udp.results.listen(_onResult);
      // Poll connection status: connected = packet received within last 3 s
      _connTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!mounted) return;
        final isConnected = _lastPacketTime != null &&
            DateTime.now().difference(_lastPacketTime!) <
                const Duration(seconds: 3);
        if (isConnected != _connected) setState(() => _connected = isConnected);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('UDP error: $e')));
      }
    }
  }

  void _onResult(PipelineResult r) {
    if (!mounted) return;
    _lastPacketTime = DateTime.now();
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
        _returnCount   = rd.n;
        _retWPico      = rd.omegaPico;
        _retTau        = rd.tauStPct;
        _retAAtq       = rd.alphaAtq;
        _retDeviations = rd.deviations;
        _alert         = rd.alert;
        _returnRows.add(rd);
        if (_returnRows.length > 100) _returnRows.removeAt(0);
      }
    });
  }

  void _push(List<FlSpot> pts, double x, double y) {
    pts.add(FlSpot(x, y));
    if (pts.length > _maxPts) pts.removeAt(0);
  }

  // ── Onboarding: entry points ──────────────────────────────────────────────

  /// Called by intro START button.
  void _beginOnboarding() {
    setState(() {
      _started     = true;
      _onboardStep = _OnboardStep.name;
    });
  }

  /// Called by "⊕ New Session" / "⊕ Start" button.
  void _newSession() {
    setState(() {
      _onboardStep = _OnboardStep.name;
    });
  }

  /// Called when user confirms the questionnaire — actually starts session.
  Future<void> _commitSession() async {
    final meta = SessionMetadata(
      athleteName: _nameCtrl.text.trim().isEmpty ? 'Atleta' : _nameCtrl.text.trim(),
      pse:         _pse,
      spasticity:  _spasticity,
    );
    await widget.session.newSession(meta: meta);
    widget.pipeline.reset();
    if (!mounted) return;
    setState(() {
      _onboardStep     = null;
      _staticCalibDone = false;
      _calibrated      = false;
      _calibProgress   = 0.0;
      _calibTheta      = 0.0;
      _thetaPts.clear();
      _omegaPts.clear();
      _returnCount = 0;
      _retWPico = 0; _retTau = 0; _retAAtq = 0;
      _retDeviations = null;
      _alert = false;
      _returnRows.clear();
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
          // Overlay stack (mutually exclusive)
          if (!_started)
            _buildIntroOverlay()
          else if (_onboardStep == _OnboardStep.name)
            _buildNameScreen()
          else if (_onboardStep == _OnboardStep.placement)
            _buildPlacementScreen()
          else if (_onboardStep == _OnboardStep.questionnaire)
            _buildQuestionnaireScreen()
          else if (!_staticCalibDone)
            _buildStaticCalibOverlay()
          else if (!_calibrated)
            _buildCalibOverlay(),
        ],
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

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
    child: Text(label,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: fg)),
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
            _statBox('ωpico', _retWPico != 0 ? '${_retWPico.toStringAsFixed(1)} °/s' : '—'),
            _statBox('τst%',  _retTau   != 0 ? '${_retTau.toStringAsFixed(1)} %'     : '—'),
            _statBox('αatq',  _retAAtq  != 0 ? '${_retAAtq.toStringAsFixed(1)} °'    : '—'),
            _statBox('Δω',    devs != null ? devs[0].toStringAsFixed(2) : '—'),
            _statBox('Δτ',    devs != null ? devs[1].toStringAsFixed(2) : '—'),
            _statBox('Δα',    devs != null ? devs[2].toStringAsFixed(2) : '—'),
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

  // ── Overlays ──────────────────────────────────────────────────────────────

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
            onPressed: _beginOnboarding,
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

  // ── Onboarding: Step 1 — Athlete Name ─────────────────────────────────────

  Widget _buildNameScreen() => Positioned.fill(
    child: Container(
      color: Colors.black87,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _onboardHeader('1 / 3', 'Atleta'),
              const SizedBox(height: 32),
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(fontSize: 20, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Nome do atleta',
                  hintStyle: const TextStyle(color: Color(0xFF546E7A)),
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF42A5F5)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF42A5F5), width: 2),
                  ),
                ),
                onSubmitted: (_) => _goPlacement(),
              ),
              const SizedBox(height: 32),
              _nextButton('PRÓXIMO →', _goPlacement),
            ],
          ),
        ),
      ),
    ),
  );

  void _goPlacement() => setState(() => _onboardStep = _OnboardStep.placement);

  // ── Onboarding: Step 2 — Sensor Placement ─────────────────────────────────

  Widget _buildPlacementScreen() => Positioned.fill(
    child: Container(
      color: Colors.black87,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _onboardHeader('2 / 3', 'Posicionamento do Sensor'),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  border: Border.all(color: const Color(0xFF2C2C2C)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.accessibility_new,
                      size: 80, color: Color(0xFF42A5F5)),
                    const SizedBox(height: 16),
                    const Text('Fixe o sensor na tíbia',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                        color: Color(0xFFCFD8DC)),
                      textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    const Text(
                      'Coloque o sensor na face anterior da tíbia,\n'
                      'aproximadamente a 5 cm abaixo do joelho.\n'
                      'Certifique-se de que está bem fixo.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF90A4AE),
                        height: 1.6),
                      textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D2137),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('Eixo Y do giroscópio = plano sagital',
                        style: TextStyle(fontSize: 11, color: Color(0xFF42A5F5),
                          fontFamily: 'monospace')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              _nextButton('PRÓXIMO →', _goQuestionnaire),
            ],
          ),
        ),
      ),
    ),
  );

  void _goQuestionnaire() => setState(() => _onboardStep = _OnboardStep.questionnaire);

  // ── Onboarding: Step 3 — Fatigue Questionnaire ────────────────────────────

  Widget _buildQuestionnaireScreen() => Positioned.fill(
    child: Container(
      color: Colors.black87,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _onboardHeader('3 / 3', 'Como está se sentindo hoje?'),
              const SizedBox(height: 28),

              // ── PSE section ──────────────────────────────────────────────
              _sectionLabel('Escala PSE — Percepção Subjetiva do Esforço'),
              const SizedBox(height: 4),
              Text(_pseLabel(_pse),
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                  color: _pseColor(_pse)),
                textAlign: TextAlign.center),
              const SizedBox(height: 10),
              _scaleSelector(
                count: 10,
                startAt: 1,
                selected: _pse,
                colorFn: _pseColor,
                onTap: (v) => setState(() => _pse = v),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text('Muito Leve', style: TextStyle(fontSize: 10, color: Color(0xFF78909C))),
                  Text('Máximo',     style: TextStyle(fontSize: 10, color: Color(0xFF78909C))),
                ],
              ),

              const SizedBox(height: 28),

              // ── Spasticity section ───────────────────────────────────────
              _sectionLabel('Espasticidade / Rigidez Percebida'),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_spasticityEmoji(_spasticity),
                    style: const TextStyle(fontSize: 28)),
                  const SizedBox(width: 8),
                  Text(
                    _spasticity == 0
                      ? 'Nenhuma rigidez'
                      : _spasticity <= 3 ? 'Rigidez leve'
                      : _spasticity <= 6 ? 'Rigidez moderada'
                      : _spasticity <= 8 ? 'Rigidez severa'
                      : 'Pior rigidez possível',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                      color: _spasticityColor(_spasticity)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _scaleSelector(
                count: 11,
                startAt: 0,
                selected: _spasticity,
                colorFn: _spasticityColor,
                onTap: (v) => setState(() => _spasticity = v),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text('Nenhuma', style: TextStyle(fontSize: 10, color: Color(0xFF78909C))),
                  Text('Pior',   style: TextStyle(fontSize: 10, color: Color(0xFF78909C))),
                ],
              ),

              const SizedBox(height: 36),
              _nextButton('INICIAR SESSÃO →', _commitSession),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    ),
  );

  // ── Onboarding shared widgets ─────────────────────────────────────────────

  Widget _onboardHeader(String step, String title) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(step,
        style: const TextStyle(fontSize: 11, color: Color(0xFF546E7A),
          letterSpacing: 1.5)),
      const SizedBox(height: 4),
      Text(title,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
          color: Color(0xFFCFD8DC))),
    ],
  );

  Widget _sectionLabel(String text) => Text(text,
    style: const TextStyle(fontSize: 12, color: Color(0xFF78909C),
      letterSpacing: 0.8),
    textAlign: TextAlign.center);

  Widget _scaleSelector({
    required int count,
    required int startAt,
    required int selected,
    required Color Function(int) colorFn,
    required void Function(int) onTap,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(count, (i) {
        final val    = startAt + i;
        final isSel  = val == selected;
        final color  = colorFn(val);
        return Expanded(
          child: GestureDetector(
            onTap: () => onTap(val),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              height: 40,
              decoration: BoxDecoration(
                color: isSel ? color : color.withAlpha(50),
                border: Border.all(
                  color: isSel ? color : Colors.transparent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text('$val',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                  color: isSel ? Colors.black87 : color,
                )),
            ),
          ),
        );
      }),
    );
  }

  Widget _nextButton(String label, VoidCallback onPressed) => ElevatedButton(
    onPressed: onPressed,
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF1565C0),
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    child: Text(label,
      style: const TextStyle(fontSize: 16, letterSpacing: 1.5,
        fontWeight: FontWeight.bold)),
  );

  // ── Calibration overlays ──────────────────────────────────────────────────

  Widget _buildStaticCalibOverlay() => Positioned.fill(
    child: Container(
      color: Colors.black87,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Fase 1 — Calibração de Gravidade',
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
          const Text('Fase 2 — Calibração de Marcha',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('Atleta caminhe até a pista (~40 passadas)',
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

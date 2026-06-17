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

enum _OnboardStep { name, placement, pse, spasticity, bateriaQuick }

// ── PSE color ─────────────────────────────────────────────────────────────────

Color _pseColor(int v) {
  if (v <= 1) return const Color(0xFF42A5F5);
  if (v <= 3) return const Color(0xFF26C6DA);
  if (v <= 6) return const Color(0xFF66BB6A);
  if (v <= 8) return const Color(0xFFFFEE58);
  if (v == 9) return const Color(0xFFFFA726);
  return const Color(0xFFEF5350);
}

// ── Spasticity color ──────────────────────────────────────────────────────────

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
  String _staticMsg       = 'Fique imóvel — calibração de gravidade';

  // Live telemetry
  double _theta = 0, _omega = 0, _accelNorm = 0;
  double _wPico = 0, _tau   = 0, _dorsiflex = 0;

  final List<FlSpot> _thetaPts = [];
  final List<FlSpot> _omegaPts = [];

  // Return aggregation
  int    _returnCount    = 0;
  double _retWPico = 0, _retTau = 0, _retDorsiflex = 0;
  List<double>? _retDeviations;
  bool   _alert = false;
  final List<ReturnData> _returnRows = [];

  // Return mode
  bool _inReturn = false;
  StreamSubscription<bool>? _returnSub;

  // Nova Bateria
  int _bateriaPse        = 5;
  int _bateriaSpasticity = 5;
  int _bateriaStep       = 0; // 0 = pse, 1 = spasticity

  @override
  void initState() {
    super.initState();
    _startUdp();
    _returnSub = widget.session.returnMode.listen((v) {
      if (mounted) setState(() => _inReturn = v);
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _connTimer?.cancel();
    _sub?.cancel();
    _returnSub?.cancel();
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
          SnackBar(content: Text('Erro UDP: $e')));
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

      if (!_calibrated) {
        widget.session.logCalibration(
          baselineMean: widget.pipeline.baselineMean,
          baselineStd:  widget.pipeline.baselineStd,
          gravityG:     widget.pipeline.gravityMagnitude,
          thetaRefDeg:  widget.pipeline.thetaRefDeg,
        );
      }
      _calibrated = true;
      _theta      = r.theta;
      _omega      = r.omega;
      _accelNorm  = r.accelNorm;

      _push(_thetaPts, r.ts, r.theta);
      _push(_omegaPts, r.ts, r.omega);

      if (r.stride != null) {
        final s = r.stride!;
        _wPico     = s.omegaPico;
        _tau       = s.tauStPct;
        _dorsiflex = s.dorsiflex;
        if (widget.session.isActive) widget.session.logStride(s);
      }

      if (r.returnData != null) {
        final rd = r.returnData!;
        _returnCount    = rd.n;
        _retWPico       = rd.omegaPico;
        _retTau         = rd.tauStPct;
        _retDorsiflex   = rd.dorsiflex;
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

  void _beginOnboarding() {
    setState(() {
      _started     = true;
      _onboardStep = _OnboardStep.name;
    });
  }

  void _newSession() {
    setState(() {
      _onboardStep = _OnboardStep.name;
    });
  }

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
      _retWPico = 0; _retTau = 0; _retDorsiflex = 0;
      _retDeviations = null;
      _alert    = false;
      _inReturn = false;
      _returnRows.clear();
    });
  }

  void _newBateria() {
    setState(() {
      _bateriaPse        = 5;
      _bateriaSpasticity = 5;
      _bateriaStep       = 0;
      _onboardStep       = _OnboardStep.bateriaQuick;
    });
  }

  void _commitBateria() {
    widget.session.newBateria(pse: _bateriaPse, spasticity: _bateriaSpasticity);
    setState(() => _onboardStep = null);
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
                      title: 'ÂNGULO TÍBIA θ (°)',
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: LiveChart(
                      spots: List.of(_omegaPts),
                      lineColor: const Color(0xFF66BB6A),
                      title: 'VELOCIDADE ANGULAR ω (°/s)',
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
          else if (_onboardStep == _OnboardStep.pse)
            _buildPseScreen()
          else if (_onboardStep == _OnboardStep.spasticity)
            _buildSpasticityScreen()
          else if (_onboardStep == _OnboardStep.bateriaQuick)
            _buildBateriaQuickScreen()
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
          _connected ? '● Conectado' : '● A conectar...',
          _connected ? const Color(0xFF1B5E20) : const Color(0xFF263238),
          _connected ? const Color(0xFFA5D6A7) : const Color(0xFF90A4AE),
        ),
        const SizedBox(width: 8),
        _alertChip(),
        const SizedBox(width: 8),
        _returnChip(),
        const Spacer(),
        TextButton(
          onPressed: _newSession,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF0D47A1),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          child: const Text('Novo Treino', style: TextStyle(fontSize: 11)),
        ),
        if (widget.session.isActive) ...[
          const SizedBox(width: 6),
          TextButton(
            onPressed: _newBateria,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF1A237E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            child: const Text('Nova Bateria', style: TextStyle(fontSize: 11)),
          ),
        ],
      ],
    );
  }

  Widget _alertChip() {
    if (_retDeviations == null) {
      return _chip('—', const Color(0xFF263238), const Color(0xFF90A4AE));
    }
    if (_alert) return _chip('ALERTA', const Color(0xFFB71C1C), const Color(0xFFFFCDD2));
    return _chip('OK', const Color(0xFF1B5E20), const Color(0xFFA5D6A7));
  }

  Widget _returnChip() => _chip(
    _inReturn ? 'RETORNO' : 'CORRIDA',
    _inReturn ? const Color(0xFF0D2137) : const Color(0xFF1B3A1B),
    _inReturn ? const Color(0xFF90CAF9) : const Color(0xFFA5D6A7),
  );

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
    child: const Text('⚠ DETERIORAÇÃO DETETADA — ≥2 parâmetros além de 2σ',
      style: TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _buildReadouts() => Wrap(
    spacing: 8, runSpacing: 8,
    children: [
      ReadoutCard(label: 'θ ÂNGULO TÍBIA',     value: _theta.toStringAsFixed(1),      unit: '°'),
      ReadoutCard(label: 'ω VEL. ANGULAR',    value: _omega.toStringAsFixed(1),      unit: '°/s'),
      ReadoutCard(label: '|a| NORMA ACEL',    value: _accelNorm.toStringAsFixed(3),  unit: 'g'),
      ReadoutCard(label: 'ωpico ÚLT. PASSADA', value: _wPico.toStringAsFixed(1),    unit: '°/s'),
      ReadoutCard(label: 'τst% ÚLT. PASSADA', value: _tau.toStringAsFixed(1),       unit: '%'),
      ReadoutCard(label: 'δDF ÚLT. PASSADA',  value: _dorsiflex.toStringAsFixed(1), unit: '°'),
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
          const Text('ÚLTIMO RETORNO',
            style: TextStyle(fontSize: 11, color: Color(0xFF78909C), letterSpacing: 1.0)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _statBox('Retornos', '$_returnCount'),
            _statBox('ωpico', _retWPico     != 0 ? '${_retWPico.toStringAsFixed(1)} °/s'      : '—'),
            _statBox('τst%',  _retTau       != 0 ? '${_retTau.toStringAsFixed(1)} %'          : '—'),
            _statBox('δDF',   _retDorsiflex != 0 ? '${_retDorsiflex.toStringAsFixed(1)} °'    : '—'),
            _statBox('Δω',    devs != null ? devs[0].toStringAsFixed(2) : '—'),
            _statBox('Δτ',    devs != null ? devs[1].toStringAsFixed(2) : '—'),
            _statBox('ΔDF',   devs != null ? devs[2].toStringAsFixed(2) : '—'),
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
          const Text('Monitor Biomecânico de Corrida',
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
            child: const Text('INICIAR',
              style: TextStyle(fontSize: 20, letterSpacing: 3, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 28),
          Text(
            _connected ? '● Sensor conectado' : '● Aguardando sensor...',
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _onboardHeader('1 / 4', 'Atleta'),
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
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 16),
              child: _nextButton('PROXIMO', _goPlacement),
            ),
          ],
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _onboardHeader('2 / 4', 'Posicionamento do Sensor'),
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
                          ColorFiltered(
                            colorFilter: const ColorFilter.matrix([
                              -0.141, 0,      0,      0, 66,
                               0,    -0.529,  0,      0, 165,
                               0,     0,     -0.843,  0, 245,
                               0,     0,      0,      1, 0,
                            ]),
                            child: Image.asset(
                              'assets/images/sensor_placement.png',
                              height: 180,
                            ),
                          ),
                          const SizedBox(height: 12),
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
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 16),
              child: _nextButton('PROXIMO', _goPse),
            ),
          ],
        ),
      ),
    ),
  );

  void _goPse() => setState(() => _onboardStep = _OnboardStep.pse);

  // ── Onboarding: Step 3 — PSE ───────────────────────────────────────────────

  Widget _buildPseScreen() {
    final options = [
      (v: 1,  color: _pseColor(1),  label: 'ATIVIDADE MUITO LEVE',
        desc: 'Quase nenhum esforço, mas mais do que dormir, ver TV, etc.'),
      (v: 2,  color: _pseColor(2),  label: 'ATIVIDADE LEVE',
        desc: 'Parece que podemos manter durante horas. Fácil de respirar e manter uma conversa.'),
      (v: 3,  color: _pseColor(3),  label: 'ATIVIDADE LEVE',
        desc: 'Parece que podemos manter durante horas. Fácil de respirar e manter uma conversa.'),
      (v: 4,  color: _pseColor(4),  label: 'ATIVIDADE MODERADA',
        desc: 'Respirar profundo, posso manter uma conversa curta. Ainda um pouco confortável, mas cada vez mais desafiador.'),
      (v: 5,  color: _pseColor(5),  label: 'ATIVIDADE MODERADA',
        desc: 'Respirar profundo, posso manter uma conversa curta. Ainda um pouco confortável, mas cada vez mais desafiador.'),
      (v: 6,  color: _pseColor(6),  label: 'ATIVIDADE MODERADA',
        desc: 'Respirar profundo, posso manter uma conversa curta. Ainda um pouco confortável, mas cada vez mais desafiador.'),
      (v: 7,  color: _pseColor(7),  label: 'ATIVIDADE VIGOROSA',
        desc: 'No limite do desconfortável. Falta de ar, consigo falar uma frase.'),
      (v: 8,  color: _pseColor(8),  label: 'ATIVIDADE VIGOROSA',
        desc: 'No limite do desconfortável. Falta de ar, consigo falar uma frase.'),
      (v: 9,  color: _pseColor(9),  label: 'ATIVIDADE MUITO DIFÍCIL',
        desc: 'Muito difícil manter a intensidade do exercício. Mal consigo respirar e falar apenas algumas palavras.'),
      (v: 10, color: _pseColor(10), label: 'ATIVIDADE DE ESFORÇO MÁXIMO',
        desc: 'É quase impossível continuar. Completamente sem fôlego, incapaz de falar. Não é possível manter por mais tempo.'),
    ];
    return _buildScaleScreen(
      step:        '3 / 4',
      title:       'Escala PSE',
      subtitle:    'Percepção Subjetiva do Esforço — como foi a última atividade?',
      options:     options.map((o) => (v: o.v, color: o.color, label: o.label, desc: o.desc)).toList(),
      selected:    _pse,
      onSelect:    (v) => setState(() => _pse = v),
      buttonLabel: 'PRÓXIMO →',
      onNext:      _goSpasticity,
    );
  }

  void _goSpasticity() => setState(() => _onboardStep = _OnboardStep.spasticity);

  // ── Onboarding: Step 4 — Spasticity ───────────────────────────────────────

  Widget _buildSpasticityScreen() {
    final options = [
      (v: 0,  color: _spasticityColor(0),  label: 'SEM ESPASTICIDADE',
        desc: 'Nenhuma rigidez ou resistência ao movimento.'),
      (v: 1,  color: _spasticityColor(1),  label: 'ESPASTICIDADE MÍNIMA',
        desc: 'Ligeira resistência ao movimento. Quase imperceptível.'),
      (v: 2,  color: _spasticityColor(2),  label: 'ESPASTICIDADE MÍNIMA',
        desc: 'Ligeira resistência ao movimento. Quase imperceptível.'),
      (v: 3,  color: _spasticityColor(3),  label: 'ESPASTICIDADE LEVE',
        desc: 'Resistência notável, mas não interfere significativamente nas atividades.'),
      (v: 4,  color: _spasticityColor(4),  label: 'ESPASTICIDADE LEVE',
        desc: 'Resistência notável, mas não interfere significativamente nas atividades.'),
      (v: 5,  color: _spasticityColor(5),  label: 'ESPASTICIDADE MODERADA',
        desc: 'Resistência moderada ao movimento. Pode causar algum desconforto.'),
      (v: 6,  color: _spasticityColor(6),  label: 'ESPASTICIDADE MODERADA',
        desc: 'Resistência moderada ao movimento. Pode causar algum desconforto.'),
      (v: 7,  color: _spasticityColor(7),  label: 'ESPASTICIDADE SEVERA',
        desc: 'Resistência forte. Movimento significativamente limitado.'),
      (v: 8,  color: _spasticityColor(8),  label: 'ESPASTICIDADE SEVERA',
        desc: 'Resistência forte. Movimento significativamente limitado.'),
      (v: 9,  color: _spasticityColor(9),  label: 'ESPASTICIDADE MUITO SEVERA',
        desc: 'Resistência extrema. Movimento muito difícil.'),
      (v: 10, color: _spasticityColor(10), label: 'ESPASTICIDADE MUITO SEVERA',
        desc: 'Resistência extrema. Movimento muito difícil ou impossível.'),
    ];
    return _buildScaleScreen(
      step:        '4 / 4',
      title:       'Espasticidade',
      subtitle:    'Rigidez percebida hoje — selecione o nível que melhor descreve.',
      options:     options.map((o) => (v: o.v, color: o.color, label: o.label, desc: o.desc)).toList(),
      selected:    _spasticity,
      onSelect:    (v) => setState(() => _spasticity = v),
      buttonLabel: 'INICIAR SESSÃO →',
      onNext:      _commitSession,
    );
  }

  // ── Nova Bateria: quick 2-step flow ───────────────────────────────────────

  Widget _buildBateriaQuickScreen() {
    if (_bateriaStep == 0) {
      final options = [
        (v: 1,  color: _pseColor(1),  label: 'ATIVIDADE MUITO LEVE',
          desc: 'Quase nenhum esforço, mas mais do que dormir, ver TV, etc.'),
        (v: 2,  color: _pseColor(2),  label: 'ATIVIDADE LEVE',
          desc: 'Parece que podemos manter durante horas. Fácil de respirar e manter uma conversa.'),
        (v: 3,  color: _pseColor(3),  label: 'ATIVIDADE LEVE',
          desc: 'Parece que podemos manter durante horas. Fácil de respirar e manter uma conversa.'),
        (v: 4,  color: _pseColor(4),  label: 'ATIVIDADE MODERADA',
          desc: 'Respirar profundo, posso manter uma conversa curta. Ainda um pouco confortável, mas cada vez mais desafiador.'),
        (v: 5,  color: _pseColor(5),  label: 'ATIVIDADE MODERADA',
          desc: 'Respirar profundo, posso manter uma conversa curta. Ainda um pouco confortável, mas cada vez mais desafiador.'),
        (v: 6,  color: _pseColor(6),  label: 'ATIVIDADE MODERADA',
          desc: 'Respirar profundo, posso manter uma conversa curta. Ainda um pouco confortável, mas cada vez mais desafiador.'),
        (v: 7,  color: _pseColor(7),  label: 'ATIVIDADE VIGOROSA',
          desc: 'No limite do desconfortável. Falta de ar, consigo falar uma frase.'),
        (v: 8,  color: _pseColor(8),  label: 'ATIVIDADE VIGOROSA',
          desc: 'No limite do desconfortável. Falta de ar, consigo falar uma frase.'),
        (v: 9,  color: _pseColor(9),  label: 'ATIVIDADE MUITO DIFÍCIL',
          desc: 'Muito difícil manter a intensidade do exercício. Mal consigo respirar e falar apenas algumas palavras.'),
        (v: 10, color: _pseColor(10), label: 'ATIVIDADE DE ESFORÇO MÁXIMO',
          desc: 'É quase impossível continuar. Completamente sem fôlego, incapaz de falar. Não é possível manter por mais tempo.'),
      ];
      return _buildScaleScreen(
        step:        '1 / 2',
        title:       'PSE — Nova Bateria',
        subtitle:    'Percepção Subjetiva do Esforço da bateria anterior.',
        options:     options,
        selected:    _bateriaPse,
        onSelect:    (v) => setState(() => _bateriaPse = v),
        buttonLabel: 'PROXIMO',
        onNext:      () => setState(() => _bateriaStep = 1),
      );
    }
    final options = [
      (v: 0,  color: _spasticityColor(0),  label: 'SEM ESPASTICIDADE',
        desc: 'Nenhuma rigidez ou resistência ao movimento.'),
      (v: 1,  color: _spasticityColor(1),  label: 'ESPASTICIDADE MÍNIMA',
        desc: 'Ligeira resistência ao movimento. Quase imperceptível.'),
      (v: 2,  color: _spasticityColor(2),  label: 'ESPASTICIDADE MÍNIMA',
        desc: 'Ligeira resistência ao movimento. Quase imperceptível.'),
      (v: 3,  color: _spasticityColor(3),  label: 'ESPASTICIDADE LEVE',
        desc: 'Resistência notável, mas não interfere significativamente nas atividades.'),
      (v: 4,  color: _spasticityColor(4),  label: 'ESPASTICIDADE LEVE',
        desc: 'Resistência notável, mas não interfere significativamente nas atividades.'),
      (v: 5,  color: _spasticityColor(5),  label: 'ESPASTICIDADE MODERADA',
        desc: 'Resistência moderada ao movimento. Pode causar algum desconforto.'),
      (v: 6,  color: _spasticityColor(6),  label: 'ESPASTICIDADE MODERADA',
        desc: 'Resistência moderada ao movimento. Pode causar algum desconforto.'),
      (v: 7,  color: _spasticityColor(7),  label: 'ESPASTICIDADE SEVERA',
        desc: 'Resistência forte. Movimento significativamente limitado.'),
      (v: 8,  color: _spasticityColor(8),  label: 'ESPASTICIDADE SEVERA',
        desc: 'Resistência forte. Movimento significativamente limitado.'),
      (v: 9,  color: _spasticityColor(9),  label: 'ESPASTICIDADE MUITO SEVERA',
        desc: 'Resistência extrema. Movimento muito difícil.'),
      (v: 10, color: _spasticityColor(10), label: 'ESPASTICIDADE MUITO SEVERA',
        desc: 'Resistência extrema. Movimento muito difícil ou impossível.'),
    ];
    return _buildScaleScreen(
      step:        '2 / 2',
      title:       'Espasticidade — Nova Bateria',
      subtitle:    'Rigidez percebida nesta bateria.',
      options:     options,
      selected:    _bateriaSpasticity,
      onSelect:    (v) => setState(() => _bateriaSpasticity = v),
      buttonLabel: 'INICIAR BATERIA',
      onNext:      _commitBateria,
    );
  }

  // ── Shared scale-list screen ───────────────────────────────────────────────

  Widget _buildScaleScreen({
    required String step,
    required String title,
    required String subtitle,
    required List<({int v, Color color, String label, String desc})> options,
    required int selected,
    required void Function(int) onSelect,
    required String buttonLabel,
    required VoidCallback onNext,
  }) {
    return Positioned.fill(
      child: Container(
        color: Colors.black87,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _onboardHeader(step, title),
                    const SizedBox(height: 6),
                    Text(subtitle,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF78909C))),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: options.map((opt) {
                    final isSel = opt.v == selected;
                    return GestureDetector(
                      onTap: () => onSelect(opt.v),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSel
                              ? opt.color.withAlpha(35)
                              : const Color(0xFF1A1A1A),
                          border: Border.all(
                            color: isSel ? opt.color : const Color(0xFF2C2C2C),
                            width: isSel ? 2 : 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                color: isSel
                                    ? opt.color
                                    : opt.color.withAlpha(55),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              alignment: Alignment.center,
                              child: Text('${opt.v}',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                  color: isSel ? Colors.black87 : opt.color,
                                )),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(opt.label,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isSel
                                          ? opt.color
                                          : const Color(0xFFCFD8DC),
                                    )),
                                  const SizedBox(height: 2),
                                  Text(opt.desc,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF78909C),
                                      height: 1.4,
                                    )),
                                ],
                              ),
                            ),
                            if (isSel) ...[
                              const SizedBox(width: 8),
                              Icon(Icons.check_circle,
                                color: opt.color, size: 20),
                            ],
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: _nextButton(buttonLabel, onNext),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
          const Text('Atleta caminhe até à pista (~40 passadas)',
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

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:paia/models/pipeline_result.dart';
import 'package:paia/models/session_record.dart';
import 'package:paia/services/session_service.dart';
import 'package:paia/services/sessions_repository.dart';
import 'package:paia/widgets/return_table.dart';

// ── Sessions list screen ───────────────────────────────────────────────────

class SessionsScreen extends StatefulWidget {
  final SessionService session;
  const SessionsScreen({super.key, required this.session});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<SessionRecord> _sessions  = [];
  bool                _loading   = true;
  final Set<String>   _selected  = {};
  bool                _selecting = false;
  StreamSubscription<void>? _sub;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    _sub    = widget.session.onNewSession.listen((_) => _load());
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) => _silentLoad());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final s = await SessionsRepository.loadAll();
    if (mounted) setState(() { _sessions = s; _loading = false; });
  }

  Future<void> _silentLoad() async {
    final s = await SessionsRepository.loadAll();
    if (mounted) setState(() => _sessions = s);
  }

  void _toggleSelect(String fileName) {
    setState(() {
      if (_selected.contains(fileName)) {
        _selected.remove(fileName);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(fileName);
      }
    });
  }

  void _enterSelect(String fileName) {
    setState(() { _selecting = true; _selected.add(fileName); });
  }

  void _exitSelect() {
    setState(() { _selecting = false; _selected.clear(); });
  }

  Future<void> _exportSelected() async {
    final files = _sessions
      .where((s) => _selected.contains(s.fileName))
      .map((s) => XFile(s.filePath))
      .toList();
    if (files.isEmpty) return;
    await Share.shareXFiles(files, subject: 'PAIA3 sessions');
    _exitSelect();
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Delete sessions',
          style: TextStyle(color: Color(0xFFCFD8DC))),
        content: Text('Delete $count session${count > 1 ? 's' : ''}? This cannot be undone.',
          style: const TextStyle(color: Color(0xFF90A4AE))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF9A9A)),
            child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    for (final s in _sessions.where((s) => _selected.contains(s.fileName))) {
      try { await File(s.filePath).delete(); } catch (_) {}
    }
    _exitSelect();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: _selecting
          ? AppBar(
              backgroundColor: const Color(0xFF1E1E1E),
              leading: IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF78909C)),
                onPressed: _exitSelect,
              ),
              title: Text('${_selected.length} selected',
                style: const TextStyle(fontSize: 15, color: Color(0xFFCFD8DC))),
              actions: [
                IconButton(
                  icon: const Icon(Icons.select_all, color: Color(0xFF78909C)),
                  tooltip: 'Select all',
                  onPressed: () => setState(() {
                    _selected.addAll(_sessions.map((s) => s.fileName));
                  }),
                ),
              ],
            )
          : AppBar(
              backgroundColor: const Color(0xFF1E1E1E),
              title: const Text('Sessions',
                style: TextStyle(fontSize: 16, color: Color(0xFF90CAF9))),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh, color: Color(0xFF78909C)),
                  onPressed: _load,
                ),
              ],
            ),
      bottomNavigationBar: _selecting
          ? SafeArea(
              child: Container(
                color: const Color(0xFF1E1E1E),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Export'),
                      onPressed: _selected.isEmpty ? null : _exportSelected,
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFF42A5F5)),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                      onPressed: _selected.isEmpty ? null : _deleteSelected,
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF9A9A)),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? const Center(child: Text('No sessions saved yet.',
                  style: TextStyle(color: Color(0xFF546E7A))))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _sessions.length,
                  itemBuilder: (_, i) {
                    final s = _sessions[i];
                    return _SessionCard(
                      session:    s,
                      service:    widget.session,
                      selecting:  _selecting,
                      selected:   _selected.contains(s.fileName),
                      onTap:      _selecting
                          ? () => _toggleSelect(s.fileName)
                          : () => Navigator.push(context, MaterialPageRoute(
                              builder: (_) => SessionDetailScreen(
                                record:  s,
                                service: widget.session))),
                      onLongPress: () => _enterSelect(s.fileName),
                    );
                  },
                ),
    );
  }
}

// ── Session card ───────────────────────────────────────────────────────────

class _SessionCard extends StatelessWidget {
  final SessionRecord session;
  final SessionService service;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _SessionCard({
    required this.session,
    required this.service,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = service.isCurrentSession(session.fileName);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1A2A3A) : const Color(0xFF1E1E1E),
          border: Border.all(
            color: selected
                ? const Color(0xFF42A5F5)
                : isActive
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFF2C2C2C),
            width: selected || isActive ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
              child: Row(
                children: [
                  if (selecting)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Icon(
                        selected ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 20,
                        color: selected
                            ? const Color(0xFF42A5F5)
                            : const Color(0xFF546E7A),
                      ),
                    ),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(session.displayLabel,
                          style: const TextStyle(fontSize: 14,
                            fontWeight: FontWeight.bold, color: Color(0xFFCFD8DC))),
                        if (isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1B5E20),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text('● REC',
                              style: TextStyle(fontSize: 9,
                                color: Color(0xFFA5D6A7), fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text('${session.strideCount} strides',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF78909C))),
                    ],
                  )),
                  if (!selecting)
                    IconButton(
                      icon: const Icon(Icons.share, size: 20, color: Color(0xFF78909C)),
                      tooltip: 'Export CSV',
                      onPressed: () => Share.shareXFiles(
                        [XFile(session.filePath)], subject: session.fileName),
                    ),
                ],
              ),
            ),
            if (session.strides.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SizedBox(
                  height: 56,
                  child: LineChart(LineChartData(
                    lineBarsData: [LineChartBarData(
                      spots: session.strides
                        .map((s) => FlSpot(s.stride.toDouble(), s.omegaPico))
                        .toList(),
                      isCurved: true,
                      color: const Color(0xFF42A5F5),
                      barWidth: 1.5,
                      dotData: const FlDotData(show: false),
                    )],
                    gridData:  const FlGridData(show: false),
                    titlesData: const FlTitlesData(
                      leftTitles:   AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles:    AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles:  AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: false),
                  )),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Detail screen ──────────────────────────────────────────────────────────

class SessionDetailScreen extends StatefulWidget {
  final SessionRecord  record;
  final SessionService service;

  const SessionDetailScreen({
    super.key,
    required this.record,
    required this.service,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  late List<StrideRow> _strides;
  StreamSubscription<StrideData>? _sub;

  @override
  void initState() {
    super.initState();
    _strides = List.of(widget.record.strides);
    if (widget.service.isCurrentSession(widget.record.fileName)) {
      _sub = widget.service.strideStream.listen((s) {
        if (!mounted) return;
        setState(() => _strides.add(StrideRow(
          stride:    _strides.length + 1,
          timeS:     s.elapsedS,
          omegaPico: s.omegaPico,
          tauStPct:  s.tauStPct,
          alphaAtq:  s.alphaAtq,
        )));
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  static const int _stridesPerReturn = 6;

  static double _median(List<double> vals) {
    final sorted = List.of(vals)..sort();
    final mid    = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  List<ReturnData> _computeReturns(List<StrideRow> strides) {
    // Group strides into chunks of _stridesPerReturn
    final groups = <List<StrideRow>>[];
    for (int i = 0; i + _stridesPerReturn <= strides.length; i += _stridesPerReturn) {
      groups.add(strides.sublist(i, i + _stridesPerReturn));
    }
    if (groups.isEmpty) return [];

    // Median per group
    final medians = groups.map((g) => [
      _median(g.map((s) => s.omegaPico).toList()),
      _median(g.map((s) => s.tauStPct ).toList()),
      _median(g.map((s) => s.alphaAtq ).toList()),
    ]).toList();

    // Session-level baseline: mean and std of all return medians
    final bMean = List.generate(3, (c) {
      final vals = medians.map((m) => m[c]).toList();
      return vals.reduce((a, b) => a + b) / vals.length;
    });
    final bStd = List.generate(3, (c) {
      final vals = medians.map((m) => m[c]).toList();
      final variance = vals.map((v) => math.pow(v - bMean[c], 2).toDouble())
          .reduce((a, b) => a + b) / vals.length;
      final s = math.sqrt(variance);
      return s < 1e-6 ? 1e-6 : s;
    });

    return List.generate(medians.length, (i) {
      List<double>? devs;
      bool alert = false;
      if (medians.length >= 2) {
        devs = [
          -(medians[i][0] - bMean[0]) / bStd[0],
           (medians[i][1] - bMean[1]) / bStd[1],
          -(medians[i][2] - bMean[2]) / bStd[2],
        ];
        alert = devs.where((d) => d.abs() > 2.0).length >= 2;
      }
      return ReturnData(
        n:         i + 1,
        omegaPico: double.parse(medians[i][0].toStringAsFixed(2)),
        tauStPct:  double.parse(medians[i][1].toStringAsFixed(2)),
        alphaAtq:  double.parse(medians[i][2].toStringAsFixed(2)),
        deviations: devs,
        alert:     alert,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final strides = _strides;
    final returns = _computeReturns(strides);
    final last    = strides.isNotEmpty ? strides.last : null;
    final isActive = widget.service.isCurrentSession(widget.record.fileName);

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Row(children: [
          Text(widget.record.displayLabel,
            style: const TextStyle(fontSize: 15, color: Color(0xFF90CAF9))),
          if (isActive) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1B5E20),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text('● REC',
                style: TextStyle(fontSize: 9,
                  color: Color(0xFFA5D6A7), fontWeight: FontWeight.bold)),
            ),
          ],
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Color(0xFF78909C)),
            onPressed: () => Share.shareXFiles(
              [XFile(widget.record.filePath)], subject: widget.record.fileName),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            _readout('STRIDES',    '${strides.length}',             ''),
            _readout('ωpico last', last != null ? last.omegaPico.toStringAsFixed(1) : '—', '°/s'),
            _readout('τst% last',  last != null ? last.tauStPct.toStringAsFixed(1)  : '—', '%'),
            _readout('αatq last',  last != null ? last.alphaAtq.toStringAsFixed(1)  : '—', '°'),
            _readout('RETURNS',    '${returns.length}', ''),
          ]),
          const SizedBox(height: 12),
          _chart('ωpico — PEAK ANGULAR VELOCITY (°/s)',
            strides.map((s) => FlSpot(s.stride.toDouble(), s.omegaPico)).toList(),
            const Color(0xFF42A5F5)),
          const SizedBox(height: 10),
          _chart('τst% — STANCE TIME (%)',
            strides.map((s) => FlSpot(s.stride.toDouble(), s.tauStPct)).toList(),
            const Color(0xFF66BB6A)),
          const SizedBox(height: 10),
          _chart('αatq — ATTACK ANGLE (°)',
            strides.map((s) => FlSpot(s.stride.toDouble(), s.alphaAtq)).toList(),
            const Color(0xFFFFA726)),
          const SizedBox(height: 12),
          if (returns.isNotEmpty) ReturnTable(rows: returns),
        ],
      ),
    );
  }

  Widget _readout(String label, String value, String unit) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFF1E1E1E),
      border: Border.all(color: const Color(0xFF2C2C2C)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF78909C),
        letterSpacing: 1.0), textAlign: TextAlign.center),
      const SizedBox(height: 4),
      RichText(text: TextSpan(children: [
        TextSpan(text: value, style: const TextStyle(fontSize: 20,
          fontWeight: FontWeight.bold, color: Colors.white)),
        if (unit.isNotEmpty) TextSpan(text: ' $unit',
          style: const TextStyle(fontSize: 11, color: Color(0xFF546E7A))),
      ])),
    ]),
  );

  Widget _chart(String title, List<FlSpot> spots, Color color) {
    if (spots.isEmpty) return const SizedBox.shrink();

    final minY  = spots.map((s) => s.y).reduce(math.min);
    final maxY  = spots.map((s) => s.y).reduce(math.max);
    final range = math.max(maxY - minY, 1e-6);
    // Use 4 intervals, rounded to a nice number
    final rawInt   = range / 4;
    final mag      = math.pow(10, (math.log(rawInt) / math.ln10).floor());
    final yInt     = ((rawInt / mag).ceil() * mag).toDouble();

    final minX  = spots.first.x;
    final maxX  = spots.last.x;
    final xInt  = math.max(1.0, (((maxX - minX) / 5) / 1).roundToDouble() * 1.0);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: const Color(0xFF2C2C2C)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 11,
          color: Color(0xFF78909C), letterSpacing: 1.0)),
        const SizedBox(height: 8),
        SizedBox(
          height: 140,
          child: LineChart(LineChartData(
            minY: minY - range * 0.12,
            maxY: maxY + range * 0.12,
            lineBarsData: [LineChartBarData(
              spots: spots,
              isCurved: false,
              color: color,
              barWidth: 1.5,
              dotData: FlDotData(
                show: spots.length < 60,
                getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                  radius: 2, color: color, strokeWidth: 0, strokeColor: color),
              ),
            )],
            gridData: const FlGridData(show: false),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: yInt,
                getTitlesWidget: (v, meta) {
                  // Skip min/max to avoid crowding at edges
                  if (v == meta.min || v == meta.max) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(v.toStringAsFixed(0),
                      style: const TextStyle(fontSize: 9, color: Color(0xFF78909C))),
                  );
                },
              )),
              bottomTitles: AxisTitles(sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 18,
                interval: xInt,
                getTitlesWidget: (v, meta) {
                  if (v == meta.min || v == meta.max) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text('${v.toInt()}',
                      style: const TextStyle(fontSize: 9, color: Color(0xFF78909C))),
                  );
                },
              )),
              topTitles:   const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            borderData: FlBorderData(show: false),
          )),
        ),
      ]),
    );
  }
}

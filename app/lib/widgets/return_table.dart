import 'package:flutter/material.dart';
import 'package:paia/models/pipeline_result.dart';

class ReturnTable extends StatelessWidget {
  final List<ReturnData> rows;

  const ReturnTable({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: const Color(0xFF2C2C2C)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text('RETURN LOG',
              style: TextStyle(fontSize: 11, color: Color(0xFF78909C),
                letterSpacing: 1.0)),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 32,
              dataRowMinHeight: 28,
              dataRowMaxHeight: 28,
              columnSpacing: 16,
              headingTextStyle: const TextStyle(
                fontSize: 11, color: Color(0xFF78909C)),
              dataTextStyle: const TextStyle(
                fontSize: 11, color: Color(0xFFCFD8DC),
                fontFamily: 'monospace'),
              columns: const [
                DataColumn(label: Text('#')),
                DataColumn(label: Text('ωpico')),
                DataColumn(label: Text('τst%')),
                DataColumn(label: Text('δDF')),
                DataColumn(label: Text('Δω')),
                DataColumn(label: Text('Δτ')),
                DataColumn(label: Text('ΔDF')),
                DataColumn(label: Text('Alert')),
              ],
              rows: rows.reversed.take(30).map((r) {
                final devs = r.deviations;

                Color _devColor(double? d) {
                  if (d == null) return const Color(0xFFCFD8DC);
                  if (d.abs() > 2.0) return const Color(0xFFEF9A9A);
                  if (d.abs() > 1.0) return const Color(0xFFFFE082);
                  return const Color(0xFFA5D6A7);
                }

                String _devStr(List<double>? ds, int i) =>
                    ds != null ? ds[i].toStringAsFixed(2) : '—';

                return DataRow(cells: [
                  DataCell(Text('${r.n}')),
                  DataCell(Text(r.omegaPico.toStringAsFixed(1))),
                  DataCell(Text(r.tauStPct.toStringAsFixed(1))),
                  DataCell(Text(r.dorsiflex.toStringAsFixed(1))),
                  DataCell(Text(_devStr(devs, 0),
                    style: TextStyle(color: _devColor(devs?[0])))),
                  DataCell(Text(_devStr(devs, 1),
                    style: TextStyle(color: _devColor(devs?[1])))),
                  DataCell(Text(_devStr(devs, 2),
                    style: TextStyle(color: _devColor(devs?[2])))),
                  DataCell(Text(r.alert ? '⚠ YES' : 'ok',
                    style: TextStyle(
                      color: r.alert
                          ? const Color(0xFFEF9A9A)
                          : const Color(0xFFA5D6A7)))),
                ]);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

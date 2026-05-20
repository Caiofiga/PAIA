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
                DataColumn(label: Text('αatq')),
                DataColumn(label: Text('IT')),
                DataColumn(label: Text('ω σ')),
                DataColumn(label: Text('τ σ')),
                DataColumn(label: Text('α σ')),
                DataColumn(label: Text('Alert')),
              ],
              rows: rows.reversed.take(30).map((r) {
                final itColor = r.it == null ? Colors.white
                  : r.alert ? const Color(0xFFEF9A9A)
                  : (r.it! > 1) ? const Color(0xFFFFE082)
                  : const Color(0xFFA5D6A7);
                final ns = r.normSlopes;
                return DataRow(cells: [
                  DataCell(Text('${r.n}')),
                  DataCell(Text(r.omegaPico.toStringAsFixed(1))),
                  DataCell(Text(r.tauStPct.toStringAsFixed(1))),
                  DataCell(Text(r.alphaAtq.toStringAsFixed(1))),
                  DataCell(Text(r.it != null ? r.it!.toStringAsFixed(3) : '—',
                    style: TextStyle(color: itColor))),
                  DataCell(Text(ns != null ? ns[0].toStringAsFixed(2) : '—')),
                  DataCell(Text(ns != null ? ns[1].toStringAsFixed(2) : '—')),
                  DataCell(Text(ns != null ? ns[2].toStringAsFixed(2) : '—')),
                  DataCell(Text(r.alert ? '⚠ YES' : 'ok',
                    style: TextStyle(
                      color: r.alert ? const Color(0xFFEF9A9A) : const Color(0xFFA5D6A7)))),
                ]);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

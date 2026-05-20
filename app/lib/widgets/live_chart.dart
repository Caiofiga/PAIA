import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class LiveChart extends StatelessWidget {
  final List<FlSpot> spots;
  final Color lineColor;
  final String title;

  const LiveChart({
    super.key,
    required this.spots,
    required this.lineColor,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
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
          Text(title, style: const TextStyle(fontSize: 11,
            color: Color(0xFF78909C), letterSpacing: 1.0)),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: spots.isEmpty
              ? const Center(child: Text('—',
                  style: TextStyle(color: Color(0xFF546E7A))))
              : LineChart(LineChartData(
                  lineBarsData: [LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: lineColor,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  )],
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 36,
                        getTitlesWidget: _leftTitle)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                    topTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                )),
          ),
        ],
      ),
    );
  }

  static Widget _leftTitle(double v, TitleMeta m) =>
    Text(v.toStringAsFixed(0),
      style: const TextStyle(fontSize: 9, color: Color(0xFF78909C)));
}

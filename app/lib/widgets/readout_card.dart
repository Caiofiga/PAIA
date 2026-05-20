import 'package:flutter/material.dart';

class ReadoutCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const ReadoutCard({
    super.key,
    required this.label,
    required this.value,
    this.unit = '',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: const Color(0xFF2C2C2C)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF78909C),
              letterSpacing: 1.0),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          RichText(text: TextSpan(
            children: [
              TextSpan(text: value,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                  color: Colors.white)),
              TextSpan(text: ' $unit',
                style: const TextStyle(fontSize: 12, color: Color(0xFF546E7A))),
            ],
          )),
        ],
      ),
    );
  }
}

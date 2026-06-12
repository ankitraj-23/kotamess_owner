import 'package:flutter/material.dart';

/// Small pill showing an extraction confidence as a colour-coded percentage.
class ConfidenceBadge extends StatelessWidget {
  final double confidence;
  const ConfidenceBadge({super.key, required this.confidence});

  @override
  Widget build(BuildContext context) {
    final percent = (confidence.clamp(0.0, 1.0) * 100).round();
    final color = confidence >= 0.75
        ? Colors.green
        : (confidence >= 0.5 ? Colors.orange : Colors.red);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$percent%',
        style: TextStyle(
          color: color.shade700,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

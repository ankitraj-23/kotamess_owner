import 'meal_request.dart';

/// One extracted request returned by the `extract-requests` Edge Function,
/// before it is saved to Supabase. Field names match the function's JSON.
class ExtractedRequest {
  final String studentName;
  final String originalMessage;
  final String requestType;
  final String mealType;
  final String dateLabel;
  final String? requestDate;
  final double confidence;
  final String reason;

  ExtractedRequest({
    required this.studentName,
    required this.originalMessage,
    required this.requestType,
    required this.mealType,
    required this.dateLabel,
    required this.requestDate,
    required this.confidence,
    required this.reason,
  });

  factory ExtractedRequest.fromJson(Map<String, dynamic> json) {
    final type = json['requestType'] as String? ?? 'unclear';
    final meal = json['mealType'] as String? ?? 'none';
    final date = json['requestDate'];
    return ExtractedRequest(
      studentName: (json['studentName'] as String?)?.trim().isNotEmpty == true
          ? (json['studentName'] as String).trim()
          : 'Unknown',
      originalMessage: json['originalMessage'] as String? ?? '',
      requestType:
          MealRequestVocab.requestTypes.contains(type) ? type : 'unclear',
      mealType: MealRequestVocab.mealTypes.contains(meal) ? meal : 'none',
      dateLabel: (json['dateLabel'] as String?)?.trim().isNotEmpty == true
          ? (json['dateLabel'] as String).trim()
          : 'unspecified',
      requestDate: (date is String && date.isNotEmpty) ? date : null,
      confidence: ((json['confidence'] as num?)?.toDouble() ?? 0.0)
          .clamp(0.0, 1.0)
          .toDouble(),
      reason: json['reason'] as String? ?? '',
    );
  }

  String get requestTypeLabel => MealRequestVocab.typeLabel(requestType);
  String get mealTypeLabel => MealRequestVocab.mealLabel(mealType);
}

/// Full response from the Edge Function.
class ExtractionResult {
  final List<ExtractedRequest> requests;
  final List<String> warnings;

  ExtractionResult({required this.requests, required this.warnings});

  bool get usedFallback =>
      warnings.any((w) => w.toLowerCase().contains('fallback'));

  factory ExtractionResult.fromJson(Map<String, dynamic> json) {
    final rawRequests = (json['requests'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ExtractedRequest.fromJson)
        .where((r) => r.originalMessage.trim().isNotEmpty)
        .toList();
    final warnings = (json['warnings'] as List<dynamic>? ?? const [])
        .map((w) => w.toString())
        .toList();
    return ExtractionResult(requests: rawRequests, warnings: warnings);
  }
}

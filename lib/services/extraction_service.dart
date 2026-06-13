import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/extraction_result.dart';

/// User-facing extraction failure (network/backend). Safe to show in UI.
class ExtractionException implements Exception {
  final String message;
  ExtractionException(this.message);
  @override
  String toString() => message;
}

/// Calls the `extract-requests` Supabase Edge Function. The Supabase client
/// attaches the signed-in user's JWT automatically, so the function can
/// authenticate the request, run Gemini, and save the extracted requests
/// itself. Gemini is NEVER called from the app, and the app no longer inserts
/// `meal_requests` directly — the function does all of that server-side and
/// returns an [ImportSummary].
class ExtractionService {
  ExtractionService([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  static const _functionName = 'extract-requests';

  /// Sends the raw chat to the server, which parses it, extracts requests,
  /// saves them as pending `meal_requests`, and returns a summary of counts.
  Future<ImportSummary> importChat({
    required String chatText,
    required String source, // 'paste' | 'file'
    String? fileName,
    DateTime? today,
  }) async {
    final day = today ?? DateTime.now();
    final todayIso =
        '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

    try {
      final response = await _client.functions.invoke(
        _functionName,
        body: {
          'chatText': chatText,
          'source': source,
          if (fileName != null) 'fileName': fileName,
          'today': todayIso,
        },
      );

      final data = response.data;
      if (data is! Map) {
        throw ExtractionException('Unexpected response from the importer.');
      }
      final summary = ImportSummary.fromJson(Map<String, dynamic>.from(data));
      if (!summary.ok) {
        throw ExtractionException(summary.error ?? 'Import failed. Please try again.');
      }
      return summary;
    } on FunctionException catch (e) {
      if (e.status == 401) {
        throw ExtractionException(
            'Your session expired. Please sign out and sign in again.');
      }
      throw ExtractionException(
          'Import service failed (code ${e.status}). Please try again.');
    } catch (e) {
      if (e is ExtractionException) rethrow;
      throw ExtractionException(
          'Could not reach the import service. Check your connection.');
    }
  }
}

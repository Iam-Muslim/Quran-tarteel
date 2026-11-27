// lib/src/search/search_transport_web.dart
import 'fuzzy_matcher.dart';

class SearchWorkerTransport {
  String? _refPhNorm;

  bool get isReady => _refPhNorm != null;

  Future<void> start(String refPhNorm) async {
    _refPhNorm = refPhNorm;
  }

  Future<List<FuzzyMatch>> search(String query, int maxEdits) async {
    final ref = _refPhNorm;
    if (ref == null) {
      throw StateError('SearchWorkerTransport has not been started.');
    }
    return findNearMatches(query, ref, maxEdits);
  }

  void dispose() {
    _refPhNorm = null;
  }
}

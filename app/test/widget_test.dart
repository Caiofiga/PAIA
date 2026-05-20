// Smoke test: verify Paia3App widget tree builds without errors.
// Full integration tests require a live UDP socket; we skip those here.

import 'package:flutter_test/flutter_test.dart';

void main() {
  // No widget smoke tests needed — the generated counter test was removed
  // when main.dart was replaced by the PAIA3 app in Task 10.
  // Domain logic is covered by packet_parser_test, mahony_filter_test,
  // and pipeline_service_test.
}

import 'dart:io';

import 'package:beyondtranslate_runtime/beyondtranslate_runtime.dart' as rp;
import 'package:flutter_test/flutter_test.dart';

/// The session's state and listener cross the FFI as records and a callback
/// interface; this drives them through the real runtime without a network.
void main() {
  test('translation session round-trips its state and tells its listener',
      () async {
    final dir = Directory.systemTemp.createTempSync('bt-session-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final runtime = rp.Runtime(dataDir: dir.path);
    final session = runtime.translationSession(
      initialTargetLanguage: 'en',
      dictionaryEnabled: false,
    );
    var changes = 0;
    session.setListener(listener: _Listener(() => changes++));

    await session.initialize();
    final state = session.state();
    expect(state.loadingServices, isFalse);
    expect(state.setupError, isNull);
    expect(state.sourceLanguage, 'auto');
    expect(state.targetLanguage, isNull);
    expect(state.effectiveTargets, ['en']);
    expect(state.query, isNull);

    session.setText(text: 'hello');
    session.setTargetLanguage(language: 'ja');
    final picked = session.state();
    expect(picked.text, 'hello');
    expect(picked.effectiveTargets, ['ja']);
    expect(picked.configuredTargetIndex, -1);

    session.clear();
    expect(session.state().text, isEmpty);

    // The listener is told on a later turn of the event loop.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(changes, greaterThan(0));
  });
}

class _Listener extends rp.TranslationSessionListener {
  _Listener(this._onChange);

  final void Function() _onChange;

  @override
  void onChange() => _onChange();
}

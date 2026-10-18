import 'package:flutter/foundation.dart';

import '../features.dart';
import '../routes/settings/provider_meta.dart' show serviceDisplayName;
import '../utils/language_util.dart';
import 'runtime.dart';
import 'system_translation.dart' show SystemLanguageNotInstalled;

/// What one service made of one target. 自动匹配 can ask for several languages
/// at once, and each keeps its own text, error and in-flight flag.
///
/// A service is only asked when a request actually goes out — on submit for
/// the default service, when 对比 opens for the rest — so an output that was
/// never [asked] is idle, not pending. The runtime decides each flag; this
/// only reads them off its snapshot.
class TranslationOutput {
  const TranslationOutput(this._state);

  /// An output for a target the service was never keyed on — the results are
  /// re-keyed the moment 自动匹配 resolves, and the UI may ask a frame early.
  TranslationOutput.idle(String target)
      : _state = TranslationOutputState(
          target: target,
          asked: false,
          loading: false,
          text: '',
          translating: false,
          failed: false,
          missingLanguage: false,
        );

  final TranslationOutputState _state;

  String get target => _state.target;

  /// A request went out for this output.
  bool get asked => _state.asked;

  /// The request is still in flight.
  bool get loading => _state.loading;

  String get text => _state.text;
  String? get audioUrl => _state.audioUrl;

  /// Why the service came back empty, as it put it. An empty string means
  /// it answered with nothing and gave no reason.
  String? get error => _state.error;

  bool get hasText => text.trim().isNotEmpty;

  /// Asked, and nothing has come back yet — the block's spinner. An LLM that
  /// has started streaming has text, and shows it.
  bool get translating => _state.translating;

  /// Asked, settled, and nothing to show: the service gave a reason instead.
  bool get failed => _state.failed;

  /// 系统翻译 without this pair's language files — the one failure the UI can
  /// point at a fix for.
  SystemLanguageNotInstalled? get missingLanguage =>
      _state.missingLanguage ? SystemLanguageNotInstalled.of(error) : null;

  /// Why the service came back empty, as it put it. Empty when it said
  /// nothing; the UI substitutes its own wording then.
  String get reason => error?.trim() ?? '';
}

/// One service's outputs for one query, one per resolved target.
class TranslationServiceResult {
  TranslationServiceResult(this._state)
      : outputs = {
          for (final output in _state.outputs)
            output.target: TranslationOutput(output),
        };

  final TranslationServiceResultState _state;

  ServiceConfigEntry get service => _state.service;
  ProviderConfigEntry? get provider => _state.provider;

  /// One output per target, in the order the targets were resolved.
  final Map<String, TranslationOutput> outputs;

  TranslationOutput output(String target) =>
      outputs[target] ?? TranslationOutput.idle(target);

  bool get hasAnyText => outputs.values.any((output) => output.hasText);
}

/// A service that came back with a reason instead of a translation.
typedef TranslationFailure = ({
  TranslationServiceResult result,
  TranslationOutput output,
});

/// One submitted query: the text, the targets it resolved to, and what every
/// enabled translation service made of each — plus the dictionary's answer.
///
/// Both windows read their result blocks off this. What the block for a
/// target shows, which services the 对比 list holds, and whether the query
/// failed as a whole are decided in the runtime, once, and read here.
class TranslationQuery {
  TranslationQuery(this._state)
      : results = [
          for (final result in _state.results) TranslationServiceResult(result),
        ];

  final TranslationQueryState _state;

  /// The trimmed source text.
  String get text => _state.text;

  /// The languages translated into, in order. Never empty.
  List<String> get targets => _state.targets;

  /// Every enabled translation service, in 服务 order, asked or not.
  final List<TranslationServiceResult> results;

  /// The service 设置 › 服务 marks 默认, if it is among [results].
  String? get defaultServiceId => _state.defaultServiceId;

  /// The service a submit runs: the default, or with none marked, the first
  /// enabled one.
  String? get leadServiceId => _state.leadServiceId;

  /// 词典 — the first dictionary service's answer for the first target.
  LookUpResponse? get dictionary => _state.dictionary;

  TranslationServiceResult? resultFor(String? serviceId) {
    if (serviceId == null) return null;
    for (final result in results) {
      if (result.service.id == serviceId) return result;
    }
    return null;
  }

  TranslationBlockState? _block(String target) =>
      _state.blocks.where((block) => block.target == target).firstOrNull;

  /// The service a target's block speaks for: the default, whatever state it
  /// is in — its text, its failure, or its spinner. With no default, the
  /// first service that answered.
  TranslationServiceResult? blockResult(String target) =>
      resultFor(_block(target)?.serviceId);

  TranslationOutput? blockOutput(String target) =>
      blockResult(target)?.output(target);

  /// The translation [target]'s block shows, or null while it has none.
  String? preferredText(String target) => _block(target)?.preferredText;

  /// The first target that has a translation to show — what 复制 on the
  /// footer copies and what history records.
  String? get firstPreferredTarget => _state.firstPreferredTarget;

  /// The other services' results for [target] — the rows 对比 opens.
  List<TranslationServiceResult> others(String target) {
    final own = blockResult(target);
    return [
      for (final result in results)
        if (result != own) result,
    ];
  }

  bool get hasAnyText => results.any((result) => result.hasAnyText);

  /// Requests still in flight with nothing shown yet.
  int get pendingCount => _state.pendingCount;

  /// One entry per service that failed on any target, in 服务 order.
  List<TranslationFailure> get failures => [
        for (final serviceId in _state.failedServiceIds)
          if (resultFor(serviceId) case final result?)
            if (result.outputs.values
                    .where((output) => output.failed)
                    .firstOrNull
                case final output?)
              (result: result, output: output),
      ];

  /// 服务全部失效: nothing came back, nothing is pending, and something
  /// failed — unless what failed is 系统翻译 lacking the language files, which
  /// the target's own block reports, with the fix.
  bool get allFailed => _state.allFailed;

  /// 语言文件未下载 on every target: a failed query like 服务全部失效 — nothing
  /// to read, copy or star, and ⏎ is a retry.
  bool get allTargetsMissingLanguage => _state.allTargetsMissingLanguage;
}

/// The translation backend both windows run on, as a [ChangeNotifier].
///
/// The rules live in the Rust runtime's `RuntimeTranslationSession` — the
/// language pair, the query and its results, the 对比 requests, the
/// dictionary look-up and the history entry — so the Dart windows and the
/// Swift ones cannot drift apart on what a query means. This holds the latest
/// snapshot and re-reads it after every call it makes and every change the
/// runtime reports.
class TranslationController extends ChangeNotifier {
  TranslationController({RuntimeTranslationSession? session})
      : _session = session ??
            runtime.translationSession(
              initialTargetLanguage: defaultTargetLanguage,
              dictionaryEnabled: kDictionaryFeatureEnabled,
            ) {
    _state = _session.state();
    _session.setListener(listener: _SessionListener(this));
  }

  final RuntimeTranslationSession _session;
  late TranslationSessionState _state;
  TranslationQuery? _query;
  bool _disposed = false;

  /// Reads the runtime's snapshot and tells the listeners.
  void _sync() {
    if (_disposed) return;
    _state = _session.state();
    final query = _state.query;
    _query = query == null ? null : TranslationQuery(query);
    notifyListeners();
  }

  String get sourceLanguage => _state.sourceLanguage;

  /// The target the user picked, or null for 自动匹配 — the target menu's
  /// first item, which hands the choice to the configured translation targets.
  String? get targetLanguage => _state.targetLanguage;

  /// The configured target the menu picked as a pair, or -1. Picking a source
  /// or target on its own is a pair of the user's making and clears it.
  int get configuredTargetIndex => _state.configuredTargetIndex;

  /// The languages a submit actually translates into: the pick when there is
  /// one, otherwise whatever 自动匹配 resolved to last. Never empty.
  List<String> get effectiveTargetLanguages => _state.effectiveTargets;

  /// The first of [effectiveTargetLanguages] — the one history records and
  /// the single-target callers read.
  String get effectiveTargetLanguage => effectiveTargetLanguages.first;

  String? get detectedLanguage => _state.detectedLanguage;
  String get text => _state.text;
  bool get loadingServices => _state.loadingServices;
  bool get submitting => _state.submitting;
  String? get setupError => _state.setupError;

  /// Whether the query's history entry is 收藏.
  bool get starred => _state.starred;

  List<ProviderConfigEntry> get providers => _state.providers;
  List<ServiceConfigEntry> get services => _state.services;

  /// The last submitted query, or null before the first (and after 清空).
  TranslationQuery? get query => _query;

  /// Loads the roster. The capsule starts on 自动检测 ⇄ 自动匹配 in both
  /// windows; the first enabled configured target is what stands behind
  /// 自动匹配 until a query resolves it.
  Future<void> initialize() async {
    await _session.initialize();
    _sync();
    // The history entry carries the name the user saw, which is this side's
    // to say: the runtime names the built-in services in English.
    _session.setServiceNames(
      names: {
        for (final service in _state.services)
          service.id: serviceDisplayName(service),
      },
    );
  }

  void setText(String value) {
    _session.setText(text: value);
    _sync();
  }

  void setSourceLanguage(String value) {
    _session.setSourceLanguage(language: value);
    _sync();
  }

  void setTargetLanguage(String? value) {
    _session.setTargetLanguage(language: value);
    _sync();
  }

  /// Picks a configured target as the pair; an [index] out of range goes
  /// back to 自动检测 ⇄ 自动匹配.
  Future<void> selectConfiguredTarget(int index) async {
    await _session.selectConfiguredTarget(index: index);
    _sync();
  }

  /// 清空 — drops the text, the query and its history entry; in-flight
  /// requests land nowhere.
  void clear() {
    _session.clear();
    _sync();
  }

  /// Runs the query: detection, 自动匹配, the default service for every
  /// target, and the dictionary. The other services wait for [compare], so a
  /// query costs one translation per target however many services are
  /// configured. When it lands, history gets the first target's translation.
  Future<void> submit() async {
    await _session.submit();
    _sync();
  }

  /// 对比 — asks the services the submit skipped for [target]. Each is asked
  /// once per query: a second 对比 on the same target finds every service
  /// already holding an output and does nothing.
  Future<void> compare(String target) async {
    await _session.compare(target: target);
    _sync();
  }

  /// Records the query in history — the first target's translation, by the
  /// service whose block shows it. An [override] is the user's own edit of
  /// that translation; [edited] marks the entry as such.
  Future<void> saveHistory({String? override, bool edited = false}) async {
    await _session.saveHistory(overrideText: override, edited: edited);
    _sync();
  }

  /// 收藏 — saves the entry first if the query has none yet.
  Future<void> toggleFavorite({String? override, bool edited = false}) async {
    await _session.toggleFavorite(overrideText: override, edited: edited);
    _sync();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.dispose();
    super.dispose();
  }
}

/// What the runtime calls when the session's state changed.
class _SessionListener extends TranslationSessionListener {
  _SessionListener(this._controller);

  final TranslationController _controller;

  @override
  void onChange() => _controller._sync();
}

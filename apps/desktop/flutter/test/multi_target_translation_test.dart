import 'package:beyondtranslate_desktop/src/i18n/i18n.dart';
import 'package:beyondtranslate_desktop/src/routes/mini_translator/translation_input_view.dart';
import 'package:beyondtranslate_desktop/src/routes/mini_translator/translation_results_view.dart';
import 'package:beyondtranslate_desktop/src/services/system_translation.dart'
    show SystemLanguageNotInstalled;
import 'package:beyondtranslate_desktop/src/services/translation_controller.dart';
import 'package:beyondtranslate_desktop/src/utils/language_util.dart';
import 'package:beyondtranslate_desktop/src/utils/shortcut_util.dart';
import 'package:beyondtranslate_desktop/src/widgets/block_heading.dart';
import 'package:beyondtranslate_desktop/src/widgets/blocks.dart';
import 'package:beyondtranslate_desktop/src/widgets/candidate_row.dart';
import 'package:beyondtranslate_desktop/src/widgets/missing_language.dart';
import 'package:beyondtranslate_desktop/src/widgets/ui.dart'
    show Button, IconButton;
import 'package:beyondtranslate_runtime/beyondtranslate_runtime.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// 自动匹配 can resolve to several targets at once, and both windows stack one
/// result block per target: the first behind the accent rule, the rest behind
/// a hairline, each with its own 对比 list and its own 复制.
/// The heading is one line of rich text, so a part of it is matched inside
/// [BlockHeading] rather than as a `Text` of its own — and only there, since
/// a body sentence can carry the same word.
Finder headingContaining(String text) => find.descendant(
      of: find.byType(BlockHeading),
      matching: find.textContaining(text),
    );

void main() {
  Widget specimen(Widget child, {double width = 460}) {
    return appHarness(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    );
  }

  group('HighlightBlock', () {
    testWidgets('a further target joins on a hairline, not a second rule', (
      tester,
    ) async {
      await tester.pumpWidget(
        specimen(
          const HighlightBlock(
            rule: HighlightRule.none,
            hairline: true,
            label: Text('译文  日本語'),
            child: Text('自己注意機構は…'),
          ),
        ),
      );

      final decoration = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(HighlightBlock),
              matching: find.byType(Container),
            ),
          )
          .map((container) => container.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.border != null);
      final border = decoration.border! as Border;
      expect(border.top.width, lessThan(2));
      expect(border.top.width, greaterThan(0));
      expect(border.bottom.width, 0);
    });

    testWidgets('the compare tray sits inside the block, under the actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        specimen(
          HighlightBlock(
            rule: HighlightRule.top,
            metaControls: true,
            label: const Text('译文  简体中文'),
            meta: IconButton(
                semanticsLabel: '复制译文',
                icon: const Icon(FluentIcons.copy_20_regular),
                onPressed: () {}),
            actions: Row(
              children: [
                Button(onPressed: () {}, child: const Text('收藏')),
              ],
            ),
            expansion: [
              const CandidateRow(
                name: 'Claude',
                providerType: ProviderType.anthropic,
                child: Text('自注意力…'),
              ),
              const CandidateRow(
                name: 'DeepL',
                providerType: ProviderType.deepLApi,
                child: Text('等待翻译'),
              ),
            ],
            child: const Text('自注意力会衡量每个词元…'),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final block = tester.getRect(find.byType(HighlightBlock));
      final tray = tester.getRect(find.byType(CompareTray));
      final actions = tester.getRect(find.byType(Button).first);
      // Full-bleed inside the block, below the action row.
      expect(tray.left, block.left);
      expect(tray.right, block.right);
      expect(tray.bottom, block.bottom);
      // The tray's 4px margin is part of its box, so it starts where the
      // action row ends and its hairline sits just below.
      expect(tray.top, greaterThanOrEqualTo(actions.bottom));
      expect(find.byType(CandidateRow), findsNWidgets(2));
    });

    testWidgets('stretching with a tray keeps the tray at the foot', (
      tester,
    ) async {
      await tester.pumpWidget(
        specimen(
          SizedBox(
            height: 500,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: HighlightBlock(
                    rule: HighlightRule.top,
                    stretch: true,
                    label: const Text('内置模型'),
                    actions: Row(
                      children: [
                        Button(onPressed: () {}, child: const Text('收藏')),
                      ],
                    ),
                    expansion: const [
                      CandidateRow(
                        name: 'Claude',
                        providerType: ProviderType.anthropic,
                        child: Text('…'),
                      ),
                    ],
                    child: const Text('译文'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final block = tester.getRect(find.byType(HighlightBlock));
      final tray = tester.getRect(find.byType(CompareTray));
      expect(block.height, 500);
      expect(tray.bottom, block.bottom);
    });
  });

  group('MiniTranslatorTranslation', () {
    ServiceConfigEntry service(String id, String name) => ServiceConfigEntry(
          id: id,
          providerId: '$id-provider',
          type: ServiceType.translation,
          name: name,
          fields: const {},
        );
    final services = [service('builtin', '内置模型'), service('claude', 'Claude')];

    /// A query over both services, one block per `(target, texts)`: a service
    /// absent from `texts` was never asked, `null` is still in flight, and
    /// `ERR:` is the reason it gave.
    ///
    /// The runtime derives the block and failure fields; the view only reads
    /// them, so the fixture fills them in by the same rules the Rust session
    /// tests pin.
    TranslationQuery query(
      List<(String, Map<String, String?>)> blocks, {
      String? defaultServiceId = 'builtin',
    }) {
      final targets = [for (final block in blocks) block.$1];

      TranslationOutputState outputFor(String serviceId, String target) {
        final texts = blocks.firstWhere((block) => block.$1 == target).$2;
        final asked = texts.containsKey(serviceId);
        final value = texts[serviceId];
        final loading = asked && value == null;
        final isError = value != null && value.startsWith('ERR:');
        final text = value != null && !isError ? value : '';
        final error = isError ? value.substring(4) : null;
        final failed = asked && !loading && text.isEmpty;
        return TranslationOutputState(
          target: target,
          asked: asked,
          loading: loading,
          text: text,
          error: error,
          translating: asked && loading,
          failed: failed,
          missingLanguage: failed &&
              (error ?? '').contains(SystemLanguageNotInstalled.marker),
        );
      }

      final results = [
        for (final service in services)
          TranslationServiceResultState(
            service: service,
            outputs: [
              for (final target in targets) outputFor(service.id, target)
            ],
          ),
      ];
      TranslationOutputState outputOf(
        TranslationServiceResultState result,
        String target,
      ) =>
          result.outputs.firstWhere((output) => output.target == target);
      TranslationServiceResultState? blockFor(String target) {
        if (defaultServiceId != null) {
          return results
              .where((result) => result.service.id == defaultServiceId)
              .firstOrNull;
        }
        return results
                .where((result) => outputOf(result, target).text.isNotEmpty)
                .firstOrNull ??
            results
                .where((result) => outputOf(result, target).asked)
                .firstOrNull ??
            results.firstOrNull;
      }

      TranslationOutputState? blockOutput(String target) {
        final result = blockFor(target);
        return result == null ? null : outputOf(result, target);
      }

      final blockStates = [
        for (final target in targets)
          TranslationBlockState(
            target: target,
            serviceId: blockFor(target)?.service.id,
            preferredText: (blockOutput(target)?.text.isNotEmpty ?? false)
                ? blockOutput(target)!.text
                : null,
          ),
      ];
      final failedServiceIds = [
        for (final result in results)
          if (result.outputs.any((output) => output.failed)) result.service.id,
      ];
      final anyText = results.any(
        (result) => result.outputs.any((output) => output.text.isNotEmpty),
      );
      final pending = results
          .expand((result) => result.outputs)
          .where((output) => output.translating)
          .length;
      final anyMissingFailure = results.any(
        (result) =>
            result.outputs
                .where((output) => output.failed)
                .firstOrNull
                ?.missingLanguage ==
            true,
      );
      return TranslationQuery(
        TranslationQueryState(
          text: 'Self-attention…',
          targets: targets,
          results: results,
          defaultServiceId: defaultServiceId,
          leadServiceId: defaultServiceId ?? services.first.id,
          blocks: blockStates,
          firstPreferredTarget: blockStates
              .where((block) => block.preferredText != null)
              .firstOrNull
              ?.target,
          pendingCount: pending,
          failedServiceIds: failedServiceIds,
          allFailed: !anyText &&
              pending == 0 &&
              failedServiceIds.isNotEmpty &&
              !anyMissingFailure,
          allTargetsMissingLanguage: targets.every(
            (target) => blockOutput(target)?.missingLanguage == true,
          ),
        ),
      );
    }

    final toggled = <String>[];
    final copied = <String>[];

    Widget view({
      required List<(String, Map<String, String?>)> blocks,
      Set<String> open = const {},
      String? copiedTarget,
      String? preferredServiceId = 'builtin',
    }) {
      return specimen(
        width: 396,
        MiniTranslatorTranslation(
          query: query(blocks, defaultServiceId: preferredServiceId),
          inputSubmitMode: InputSubmitMode.enter,
          compareOpenTargets: open,
          copiedTarget: copiedTarget,
          onToggleCompare: toggled.add,
          onCopyTarget: copied.add,
          onRequery: () {},
        ),
      );
    }

    setUp(() {
      toggled.clear();
      copied.clear();
    });

    testWidgets('two targets stack two blocks, each with its own controls', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          blocks: [
            ('zh-Hans', {'builtin': '自注意力…', 'claude': '自注意力机制…'}),
            ('ja', {'builtin': '自己注意機構は…', 'claude': '自己注意は…'}),
          ],
        ),
      );
      expect(tester.takeException(), isNull);

      // One heading per target — one line of rich text each, so the role and
      // the language are read out of the same widget. The role word leads on
      // both; the language is what tells them apart.
      expect(
        headingContaining(t.workbench.translation.target),
        findsNWidgets(2),
      );
      expect(headingContaining(getLanguageName('zh-Hans')), findsOneWidget);
      expect(headingContaining(getLanguageName('ja')), findsOneWidget);

      // 复制 rides on each block's attribution row and acts on that language.
      final copyLabel = t.mini_translator.button.copy;
      expect(find.bySemanticsLabel(copyLabel), findsNWidgets(2));
      await tester.tap(find.bySemanticsLabel(copyLabel).last);
      expect(copied, ['ja']);

      // 对比 opens per target; nothing is listed until it does. The toggle
      // is a glyph with the count on its corner, so it answers to its name
      // rather than printing it.
      expect(find.byType(CandidateRow), findsNothing);
      // Two services in the comparison per target, one of them the block's
      // own — so the button announces 2 and the badge counts the 1 row the
      // list would open.
      final compare = t.mini_translator.result.compare_services(count: 2);
      expect(find.bySemanticsLabel(compare), findsNWidgets(2));
      expect(find.text('1'), findsNWidgets(2));
      await tester.tap(find.bySemanticsLabel(compare).first);
      expect(toggled, ['zh-Hans']);
    });

    testWidgets('an open target lists only that language\'s candidates', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          blocks: [
            ('zh-Hans', {'builtin': '自注意力…', 'claude': '自注意力机制…'}),
            ('ja', {'builtin': '自己注意機構は…', 'claude': '自己注意は…'}),
          ],
          open: const {'ja'},
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.byType(CandidateRow), findsOneWidget);
      expect(find.text('自己注意は…'), findsOneWidget);
      expect(find.text('自注意力机制…'), findsNothing);
      // The list is there to be read: no 设为首选 on the attribution row and
      // no ⌥n hint beside it.
      expect(find.text('⌥1'), findsNothing);
      expect(find.text('⌥2'), findsNothing);
      expect(find.bySemanticsLabel(t.mini_translator.result.collapse_compare),
          findsOneWidget);
    });

    testWidgets('one target keeps the footer\'s copy and shows no icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(blocks: [
          ('zh-Hans', {'builtin': '自注意力…'})
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(
          find.bySemanticsLabel(t.mini_translator.button.copy), findsNothing);
      // A lone service has nothing to compare against.
      expect(find.byType(CandidateRow), findsNothing);
    });

    const notInstalled =
        'ERR:network error: language pair not installed: en -> zh-Hans';

    testWidgets(
        'the preferred service lacking the language files takes the slot', (
      tester,
    ) async {
      final blocks = [
        ('zh-Hans', {'builtin': notInstalled, 'claude': '自注意力机制…'}),
      ];
      await tester.pumpWidget(view(blocks: blocks, open: const {'zh-Hans'}));
      expect(tester.takeException(), isNull);

      // The danger key, with the pair named and the fix as a link. The
      // heading names the target and the service only — the reason is
      // already said by the body in the translation's slot.
      expect(headingContaining(t.workbench.translation.target), findsOneWidget);
      expect(headingContaining(getLanguageName('zh-Hans')), findsOneWidget);
      expect(
        find.textContaining(t.mini_translator.result.language_missing_flag),
        findsNothing,
      );
      expect(find.byType(SystemSettingsLink), findsOneWidget);
      // Nothing to copy; the other service still lists in 对比.
      expect(
          find.bySemanticsLabel(t.mini_translator.button.copy), findsNothing);
      expect(find.text('自注意力机制…'), findsOneWidget);
      // And the footer hears it is a failed query.
      expect(
        query(blocks, defaultServiceId: 'builtin').allTargetsMissingLanguage,
        isTrue,
      );
      expect(
        query(blocks, defaultServiceId: 'claude').allTargetsMissingLanguage,
        isFalse,
      );
    });

    testWidgets(
        'a service that answered keeps the slot; the missing one explains itself in 对比',
        (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          blocks: [
            ('zh-Hans', {'builtin': notInstalled, 'claude': '自注意力机制…'}),
          ],
          preferredServiceId: null,
          open: const {'zh-Hans'},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('自注意力机制…'), findsNWidgets(1));
      expect(find.byType(MissingLanguageNote), findsOneWidget);
      expect(find.byType(SystemSettingsLink), findsOneWidget);
    });

    testWidgets(
        'only the missing service, no preference: still the missing block, not 未返回结果',
        (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          blocks: [
            ('zh-Hans', {'builtin': notInstalled})
          ],
          preferredServiceId: null,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(t.mini_translator.result.no_result_body), findsNothing);
      expect(find.byType(SystemSettingsLink), findsOneWidget);
    });

    testWidgets('a target still in flight shows its spinner in its own block', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(
          blocks: [
            ('zh-Hans', {'builtin': '自注意力…'}),
            ('ja', {'builtin': null}),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(t.mini_translator.result.translating), findsOneWidget);
      expect(headingContaining(getLanguageName('ja')), findsOneWidget);
      // No 复制 on a block with nothing to copy yet.
      expect(
          find.bySemanticsLabel(t.mini_translator.button.copy), findsOneWidget);
    });

    /// 原文已修改 is about the relation between the two blocks — the
    /// translation below no longer answers the text above — so it belongs to
    /// neither. It used to be a quiet button nested inside the has-text
    /// branch of the last target's block, where it vanished whenever that
    /// block was still in flight or had come back without language files;
    /// with several targets that is the ordinary case. Now it is one
    /// full-width strip at the seam, the whole of it the retry.
    testWidgets('原文已修改 is a strip at the seam, the whole of it the retry', (
      tester,
    ) async {
      var retries = 0;
      await tester.pumpWidget(
        specimen(
          width: 396,
          MiniTranslatorStaleNotice(
            inputSubmitMode: InputSubmitMode.enter,
            onRequery: () => retries++,
          ),
        ),
      );

      final result = t.mini_translator.result;
      expect(find.text(result.stale_notice), findsOneWidget);
      expect(
        find.text(
          result.stale_retry(
            key: inputSubmitShortcutGlyphs(InputSubmitMode.enter),
          ),
        ),
        findsOneWidget,
      );

      // The strip is the button, not a control parked inside it: a tap
      // anywhere along it retries.
      await tester.tapAt(tester.getCenter(find.text(result.stale_notice)));
      await tester.pump();
      await tester.tapAt(
        tester.getTopLeft(find.byType(MiniTranslatorStaleNotice)) +
            const Offset(200, 12),
      );
      await tester.pump();
      expect(retries, 2);
    });
  });
}

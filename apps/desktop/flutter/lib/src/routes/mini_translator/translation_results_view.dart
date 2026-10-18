import 'package:beyondtranslate_runtime/beyondtranslate_runtime.dart'
    show InputSubmitMode, LookUpResponse;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/widgets.dart';

import '../../features.dart';
import '../../i18n/i18n.dart';
import '../../services/system_translation.dart';
import '../../services/translation_controller.dart';
import '../../theme/product_tokens.dart'
    show ProductPalette, ProductTokens, ProductTokensContext, ProductTypography;
import '../../utils/language_util.dart';
import '../../utils/shortcut_util.dart';
import '../../widgets/block_heading.dart';
import '../../widgets/blocks.dart' show CompareTray;
import '../../widgets/candidate_row.dart' show CandidateRow;
import '../../widgets/compare_toggle.dart';
import '../../widgets/data_display.dart' show DetailBlock;
import '../../widgets/missing_language.dart';
import '../../widgets/translation_text.dart';
import '../../widgets/ui.dart'
    show
        Button,
        ButtonVariant,
        IconButton,
        IconButtonTint,
        IconButtonVariant,
        SectionLabel,
        Spinner,
        ThemeDataBuildContextProps,
        WidgetSize;
import '../settings/provider_meta.dart' show serviceDisplayName;

/// The preferred block plus the on-demand service comparison, mirroring the
/// deck's MiniTranslator: one preferred translation as the visual protagonist,
/// its service attribution below, candidates behind a 对比 N 个服务 toggle.
///
/// 自动匹配 can resolve to more than one target — a specific rule and the
/// 自动检测 fallback both apply — and the core translates into each, so the
/// blocks stack one per target: the first behind the 2px accent rule, a
/// further one behind a neutral hairline. Each target's 对比 opens its own
/// list, and 复制 rides on each block's attribution row.
class MiniTranslatorTranslation extends StatelessWidget {
  const MiniTranslatorTranslation({
    super.key,
    required this.query,
    this.matchedAutomatically = true,
    required this.inputSubmitMode,
    required this.compareOpenTargets,
    required this.copiedTarget,
    required this.onToggleCompare,
    required this.onCopyTarget,
    required this.onRequery,
  });

  /// The submitted query, or null before the first — the backend both windows
  /// share decides what each target's block shows; this only draws it.
  final TranslationQuery? query;

  /// Whether the capsule is on 自动匹配. Only then does the heading name the
  /// target: a language the user picked is already in the capsule.
  final bool matchedAutomatically;

  /// Only so 原文已修改 names the key that actually re-runs the query —
  /// 提交方式 decides which one that is.
  final InputSubmitMode inputSubmitMode;

  /// The source was edited after this result came back — offer 重新翻译.

  /// Targets whose 对比 list is open — or, with no result, whether the
  /// 失效清单 is (keyed by [kFailureListKey]).
  final Set<String> compareOpenTargets;

  /// Which target's 复制 just fired — its icon reads 已复制 for a beat.
  final String? copiedTarget;
  final ValueChanged<String> onToggleCompare;
  final ValueChanged<String> onCopyTarget;
  final VoidCallback onRequery;

  /// What the 失效清单 toggle is keyed under in [compareOpenTargets].
  static const String kFailureListKey = '';

  /// The heading over a translation block. The default service is never
  /// named — the language alone is enough when the answer came from the one
  /// you would expect; a promoted service trails as a qualifier.
  BlockHeadingParts _heading(
    TranslationQuery query,
    TranslationServiceResult? result,
    String target,
  ) {
    return translationHeading(
      target: target,
      serviceName: result == null || result.service.id == query.defaultServiceId
          ? null
          : serviceDisplayName(result.service),
      matched: matchedAutomatically,
    );
  }

  _ServiceFailure _failureOf(TranslationFailure failure) {
    final reason = failure.output.reason;
    return _ServiceFailure(
      name: serviceDisplayName(failure.result.service),
      reason: reason.isEmpty ? t.mini_translator.result.unknown_error : reason,
      notInstalled: failure.output.missingLanguage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final vars = context.vars;
    final query = this.query;

    if (query == null || query.targets.isEmpty) {
      return const SizedBox.shrink();
    }

    // 服务全部失效 — the failures are kept, not just counted: the list prints
    // one card per service with the reason it gave.
    if (query.allFailed) {
      final failures = query.failures.map(_failureOf).toList(growable: false);
      final open = compareOpenTargets.contains(kFailureListKey);
      final targetList = query.targets
          .map(getLanguageName)
          .join(t.workbench.translation.target_separator);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 服务全部失效 keeps the result block's shape — body, then the
          // attribution row with the compare toggle — in the danger key,
          // the way the main window's 翻译 pane does.
          Container(
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 15),
            decoration: BoxDecoration(
              color: vars.dangerSurface,
              border: Border(
                top: BorderSide(
                  color: vars.dangerHairline,
                  width: ProductTokens.highlightRule,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.mini_translator.result.no_result_body,
                  style: vars.miniTranslationStyle(
                    color: vars.colorContentSubtle,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    // No glow: the glow marks the one that answered.
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: vars.danger,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    // The heading takes the rest of the row, so the toggle
                    // sits at the right edge and the label is cut only when
                    // there is genuinely no room left.
                    Expanded(
                      child: DefaultTextStyle(
                        style: vars.labelStyle(color: vars.dangerFg),
                        // A failed query keeps the plain heading — the body
                        // already says the translation did not arrive, and a
                        // status on the label would say it twice.
                        child: BlockHeading(
                          _heading(
                            query,
                            query.blockResult(query.targets.first),
                            targetList,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CompareToggle(
                      expanded: open,
                      count: failures.length,
                      label: open
                          ? t.mini_translator.result.collapse_reasons
                          : t.mini_translator.result.show_reasons(
                              count: failures.length,
                            ),
                      onPressed: () => onToggleCompare(kFailureListKey),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 失效清单 — the same cards as the compare list, folded away by the
          // same toggle, so a service looks the same whether it answered or
          // not: name where it always is, the ⌥n hint still live, the body a
          // reason instead of a translation, and the foot the fix instead of
          // 设为首选.
          if (open)
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: vars.colorSurfaceRaised,
                border: Border(
                  top: BorderSide(
                    color: vars.colorBorder,
                    width: context.hairlineWidth,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < failures.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _FailureCard(failure: failures[i], onRetry: onRequery),
                  ],
                ],
              ),
            ),
        ],
      );
    }

    final targets = query.targets;
    final stacked = targets.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < targets.length; i++)
          _buildTargetBlock(
            context,
            query,
            targets[i],
            first: i == 0,
            last: i == targets.length - 1,
            stacked: stacked,
          ),
      ],
    );
  }

  /// One target's block: the preferred service's text, then the attribution
  /// row with the per-target controls, then — folded out — the other
  /// services' renderings into this language.
  Widget _buildTargetBlock(
    BuildContext context,
    TranslationQuery query,
    String targetCode, {
    required bool first,
    required bool last,
    required bool stacked,
  }) {
    final vars = context.vars;
    // The resolved target rides on the attribution label, as in the main
    // window's 首选译文 block; the capsule stays on 自动检测 ⇄ 自动匹配.
    final targetName = getLanguageName(targetCode);
    // The block belongs to one service — the default — and shows whatever
    // that service did with this target.
    final own = query.blockResult(targetCode);
    final ownOutput = own?.output(targetCode);
    // 系统翻译 without this pair's language files: reason + fix, no text.
    final missing = ownOutput?.missingLanguage;
    final preferredText =
        missing != null ? null : query.preferredText(targetCode);
    // The default came back with a reason instead of a translation. It takes
    // the block the way the missing-language notice does: another service
    // answering is not this service answering.
    final failure = missing == null &&
            preferredText == null &&
            ownOutput != null &&
            ownOutput.failed
        ? ownOutput
        : null;
    final failed = missing != null || failure != null;
    final translating = !failed && preferredText == null;
    final open = compareOpenTargets.contains(targetCode);
    final copied = copiedTarget == targetCode;
    // The list is keyed by service, not by what came back: opening it is what
    // asks the other services, so one not yet asked is a row too — it just
    // holds a spinner until it answers.
    final rows = [
      for (final result in query.others(targetCode))
        _buildCompareRow(context, result, result.output(targetCode)),
    ];
    // 对比 counts the services being compared, this block's own included —
    // it is the size of the comparison, not of the list that folds out.
    final compareCount = rows.length + (own == null ? 0 : 1);
    final showList = open && rows.isNotEmpty;
    // 复制 on the attribution row is a 24px button beside an 18px toggle;
    // the deck pulls it in with negative margins, so the gap above and the
    // inset below give up the difference here to keep the block's rhythm.
    final controls = stacked && !translating && !failed;

    return Container(
      decoration: BoxDecoration(
        // A default service that could not answer — no language files, or any
        // other reason — is a failed translation, so the block takes the
        // danger key the way 未返回结果 does.
        color: failed ? vars.dangerSurface : vars.accentSurface,
        // The 2px accent rule marks where the output starts; a further target
        // shares the surface behind a neutral 1px hairline — a second accent
        // line would read as a second output rather than a section of this one.
        border: Border(
          top: first
              ? BorderSide(
                  color: failed ? vars.dangerHairline : vars.accentHairline,
                  width: ProductTokens.highlightRule,
                )
              : BorderSide(
                  color: vars.colorBorder,
                  width: context.hairlineWidth,
                ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (translating)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Spinner(size: WidgetSize.small),
                        const SizedBox(width: 10),
                        Text(
                          t.mini_translator.result.translating,
                          style: vars.sansStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1,
                            color: vars.accentText,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (missing != null)
                  // The block keeps the result shape — body, then the
                  // attribution row — in the danger key, at the same type
                  // scale as 未返回结果: the failure sits in the translation's
                  // slot, so it is set like one. The fix rides inside the
                  // sentence as a short link; the full settings path stays
                  // on the main window.
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${MissingLanguageText.sentence(missing)}'
                              '${t.mini_translator.result.language_missing_mini_before}',
                        ),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: SystemSettingsLink(
                            label: t.mini_translator.result
                                .language_missing_mini_link,
                            bold: false,
                            style: vars.miniTranslationStyle(),
                          ),
                        ),
                        TextSpan(
                          text: t.mini_translator.result
                              .language_missing_mini_after(
                            key: inputSubmitShortcutGlyphs(inputSubmitMode),
                          ),
                        ),
                      ],
                    ),
                    style: vars.miniTranslationStyle(
                      color: vars.colorContentSubtle,
                    ),
                  )
                else if (failure != null)
                  // The reason sits where the translation would have been, at
                  // the same type scale: the block reports what the service
                  // you configured said, and 对比 is there to ask the others.
                  Text(
                    failure.reason.isEmpty
                        ? t.mini_translator.result.unknown_error
                        : failure.reason,
                    style: vars.miniTranslationStyle(color: vars.dangerFg),
                  )
                else
                  TranslationText(
                    preferredText!,
                    style: vars.miniTranslationStyle(
                      color: vars.colorContent,
                    ),
                  ),
              ],
            ),
          ),
          // 服务署名与对比开关 — under the translation, so the text stays the
          // visual protagonist of the block. 对比按目标各开各的：比的是其他服务
          // 译到这一种语言的结果.
          //
          // The row hangs 6px past the text column on the right: its trailing
          // control is a filled chip, and at the text's own 15px inset it
          // reads as drifting away from the card's edge. 9px is the compare
          // tray's inset, so the chip lines up with the rows it opens.
          Padding(
            padding: EdgeInsets.fromLTRB(
              15,
              controls ? 9 : 12,
              9,
              showList
                  ? 0
                  : controls
                      ? 12
                      : 15,
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: failed ? vars.danger : vars.accentText,
                    shape: BoxShape.circle,
                    // No glow: the glow marks the one that answered.
                    boxShadow: failed ? null : context.product.highlightGlow,
                  ),
                ),
                const SizedBox(width: 7),
                // The heading takes the rest of the row: 复制 and 对比
                // ride at the right edge, and 译文 语言 服务名 gets every
                // pixel between them and the dot.
                Expanded(
                  child: DefaultTextStyle(
                    style: vars.labelStyle(
                      color: failed ? vars.dangerFg : vars.accentText,
                    ),
                    // 语言文件未下载 is already said by the body in the
                    // translation's slot; the heading does not repeat it.
                    child: BlockHeading(_heading(query, own, targetName)),
                  ),
                ),
                const SizedBox(width: 8),
                if (controls) ...[
                  IconButton(
                      semanticsLabel: copied
                          ? t.mini_translator.button.copied
                          : t.mini_translator.button.copy,
                      // Copied is a confirmation that clears itself,
                      // not a state the button is held in, so it takes the
                      // success recipe rather than a toggle's latch.
                      tint: copied ? IconButtonTint.success : null,
                      variant: copied ? IconButtonVariant.plain : null,
                      icon: Icon(
                        copied
                            ? FluentIcons.checkmark_20_regular
                            : FluentIcons.copy_20_regular,
                      ),
                      onPressed: () => onCopyTarget(targetCode)),
                  const SizedBox(width: 8),
                ],
                if (rows.isNotEmpty)
                  CompareToggle(
                    expanded: open,
                    // The badge counts the rows the list would open; the name
                    // it answers to counts the comparison, this block's own
                    // service included.
                    count: rows.length,
                    label: open
                        ? t.mini_translator.result.collapse_compare
                        : t.mini_translator.result.compare_services(
                            count: compareCount,
                          ),
                    onPressed: () => onToggleCompare(targetCode),
                  ),
              ],
            ),
          ),
          // 展开对比 — the other services, listed in this target's own block
          // on the same tinted surface; a separate grey band would cut the
          // result area into strips.
          if (showList)
            CompareTray(
              margin: const EdgeInsets.only(top: 2),
              // 6px short of the block's 15px inset: each row's attribution
              // chip hangs that far past the text column.
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
              color: vars.colorSurfaceRaised,
              children: rows,
            ),
        ],
      ),
    );
  }

  /// One other service's row. Opening the list is what asks these services, so
  /// a row starts as a spinner and settles into the translation that came
  /// back, or the reason it did not.
  Widget _buildCompareRow(
    BuildContext context,
    TranslationServiceResult result,
    TranslationOutput output,
  ) {
    final vars = context.vars;
    final bodyStyle = vars.cjkStyle(
      fontSize: 13,
      height: 1.7,
      color: vars.colorContentSecondary,
    );
    final failure =
        output.failed ? _failureOf((result: result, output: output)) : null;

    final Widget child;
    if (output.hasText) {
      child = TranslationText(output.text, style: bodyStyle);
    } else if (failure != null) {
      // The install notice or the reason the service gave, where its
      // translation would have been.
      child = failure.notInstalled != null
          ? MissingLanguageNote(missing: failure.notInstalled!)
          : Text(
              failure.reason,
              style: bodyStyle.copyWith(color: vars.dangerFg),
            );
    } else {
      child = const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Spinner(size: WidgetSize.small),
        ),
      );
    }

    return CandidateRow(
      name: serviceDisplayName(result.service),
      providerType: result.provider?.type,
      child: child,
    );
  }
}

/// Why one service came back empty — a blanket "failed" gives the user nothing
/// to act on, and the block's job in this state is to point at the fix.
class _ServiceFailure {
  const _ServiceFailure({
    required this.name,
    required this.reason,
    this.notInstalled,
  });

  final String name;
  final String reason;

  /// Set when the system translator lacks the language files for the pair —
  /// the one failure the card can point at a fix for.
  final SystemLanguageNotInstalled? notInstalled;
}

/// One failed service: the same card the compare list draws, with the reason
/// where the translation would be and 重试 under it.
class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.failure, required this.onRetry});

  final _ServiceFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final vars = context.vars;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: vars.colorSurfaceSubtle,
        borderRadius: BorderRadius.circular(vars.radiusLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionLabel(failure.name),
          const SizedBox(height: 5),
          Text(
            failure.notInstalled != null
                ? MissingLanguageText.sentence(failure.notInstalled!)
                : failure.reason,
            style: vars.sansStyle(
              fontSize: 12,
              height: 1.7,
              color: vars.colorContentSecondary,
            ),
          ),
          const SizedBox(height: 7),
          if (failure.notInstalled != null)
            Button(
                variant: ButtonVariant.plain,
                onPressed: openTranslationLanguagesSettings,
                child: Text(t.mini_translator.result.open_system_settings))
          else
            Button(
                variant: ButtonVariant.plain,
                onPressed: onRetry,
                child: Text(t.mini_translator.result.retry)),
        ],
      ),
    );
  }
}

class MiniTranslatorWordDefinition extends StatelessWidget {
  const MiniTranslatorWordDefinition({super.key, required this.lookUp});

  /// 词典 — the query's dictionary answer, if a dictionary service ran.
  final LookUpResponse? lookUp;

  @override
  Widget build(BuildContext context) {
    final lookup = lookUp;
    if (lookup == null || !kDictionaryFeatureEnabled) {
      return const SizedBox.shrink();
    }

    final word = lookup.word;
    final pronunciations = lookup.pronunciations;
    final phonetic = pronunciations == null || pronunciations.isEmpty
        ? null
        : pronunciations.first.phoneticSymbol;
    final definitions = lookup.definitions;
    final values = definitions == null || definitions.isEmpty
        ? null
        : definitions.first.values;
    final definition = values == null || values.isEmpty ? null : values.first;

    if (word == null && definition == null) return const SizedBox.shrink();

    return DetailBlock(
      title: Text(word ?? ''),
      subtitle: phonetic == null ? null : Text(phonetic),
      child: Text(definition ?? ''),
    );
  }
}

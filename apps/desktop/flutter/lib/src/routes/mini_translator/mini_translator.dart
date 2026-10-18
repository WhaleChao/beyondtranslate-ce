// ignore_for_file: deprecated_member_use, unused_element

import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:nativeapi_flutter/nativeapi_flutter.dart' as nativeapi;

import '../../extensions/window_controller.dart';
import '../../i18n/i18n.dart';
import '../../routes/settings/services.dart' show ServicesSettingsPage;
import '../../services/app_windows.dart'
    show
        handOffToWorkbench,
        hideMiniTranslatorWindow,
        miniTranslatorPositionAtCursorScreenTopRight,
        miniTranslatorWindowController,
        showMiniTranslatorWindow,
        showSettingsWindow;
import '../../services/runtime.dart';
import '../../services/settings_store.dart';
import '../../services/shortcut_service/shortcut_service.dart';
import '../../services/translation_controller.dart';
import '../../utils/language_util.dart';
import '../../utils/platform_util.dart';
import '../../widgets/block_heading.dart';
import '../../widgets/popover_panel.dart' show PopoverPanel;
import '../../widgets/toast_host.dart' show showToast;
import '../../widgets/ui.dart' show ThemeDataBuildContextProps, ToastTint;
import 'limited_functionality_banner.dart';
import 'translation_input_view.dart';
import 'translation_results_view.dart';
import 'translation_target_select_view.dart';

/// The tray's own inset (`--bt-mini-tray-pad`): the top bar, the panel card and
/// the action bar all float this far inside the window edge.
const double _kTrayInset = 8;

/// The same inset on the sides, widened. The window is narrow, so the cards
/// run nearly its full width; at 8px the 原文/译文 blocks read as pressed
/// against the window edge rather than floating on the tray.
const double _kTrayInsetX = 12;

/// What the footer's 复制 is keyed under — it copies the first target's text.
const String _kCopiedAll = '*';

class MiniTranslatorPage extends StatefulWidget {
  const MiniTranslatorPage({super.key});

  @override
  State<StatefulWidget> createState() => _MiniTranslatorPageState();
}

class _MiniTranslatorPageState extends State<MiniTranslatorPage>
    with WidgetsBindingObserver, ShortcutListener {
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _textEditingController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final GlobalKey _bannersViewKey = GlobalKey();
  final GlobalKey _contentViewKey = GlobalKey();
  final GlobalKey _toolbarViewKey = GlobalKey();

  Brightness _brightness = Brightness.light;

  Offset _lastShownPosition = Offset.zero;

  // The mini-translator grows with its content but caps at this height, after
  // which the results area scrolls.
  static const double _maxWindowHeight = 800;

  bool _isAlwaysOnTop = false;

  bool _isAllowedScreenCaptureAccess = true;
  bool _isAllowedScreenSelectionAccess = true;

  /// The translation backend, shared with the main window: the language
  /// pair, the query, 对比, the dictionary and the history entry all live
  /// there, so the two windows cannot drift apart on what a query means.
  final TranslationController _controller = TranslationController();

  String get _text => _controller.text;
  bool get _querySubmitted => _controller.query != null;

  /// 对比 — per target: the candidates are the other services' renderings
  /// into that language, so each target's block folds out its own list.
  final Set<String> _compareOpen = {};

  /// The source was edited after the last query — arms ⏎ 重新翻译.
  bool _resultStale = false;

  /// Which target's 复制 just fired — a block's, or [_kCopiedAll] for the
  /// footer's.
  String? _copiedTarget;
  Timer? _copiedTimer;

  Timer? _resizeSettledTimer;
  bool _isWindowResizeScheduled = false;
  bool _pendingWindowResizeAnimate = true;
  bool _pendingWindowResizeSettle = false;
  int? _windowFocusedListenerId;
  int? _windowBlurredListenerId;
  int? _windowMovedListenerId;

  nativeapi.Window get _window => miniTranslatorWindowController.window;

  @override
  void initState() {
    settingsStore.addListener(_handleChanged);
    _controller.addListener(_handleChanged);
    _controller.initialize();
    WidgetsBinding.instance.addObserver(this);
    if (kIsLinux || kIsMacOS || kIsWindows) {
      ShortcutService.instance.setListener(this);
      _registerWindowEvents();
      _init();
    }
    super.initState();
    _scheduleWindowResize(animate: false, settle: true);
  }

  @override
  void dispose() {
    settingsStore.removeListener(_handleChanged);
    _controller
      ..removeListener(_handleChanged)
      ..dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (kIsLinux || kIsMacOS || kIsWindows) {
      ShortcutService.instance.setListener(null);
      _unregisterWindowEvents();
    }
    _resizeSettledTimer?.cancel();
    _copiedTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    Brightness newBrightness =
        WidgetsBinding.instance.window.platformBrightness;

    if (newBrightness != _brightness) {
      _setStateAndScheduleWindowResize(() {
        _brightness = newBrightness;
      });
    }
  }

  /// Re-reads both system permissions and lets the 功能受限 banner follow.
  ///
  /// It used to be asked once, in [initState], and the mini translator's page
  /// is registered on its first show and then merely hidden and shown — so
  /// that was once per app run, and the only other way to ask was the banner's
  /// own 重新检查 button, which does not exist while the banner is hidden.
  /// Revoking a permission on a running app therefore never surfaced.
  ///
  /// macOS answers `AXIsProcessTrusted()` live, but
  /// `CGPreflightScreenCaptureAccess()` is cached for the life of the process:
  /// a screen-recording grant or revocation made while the app runs is
  /// invisible here until it restarts. So this catches up with the
  /// accessibility half in-session, and the 重新检查 feedback says as much
  /// when the other half will not move.
  Future<void> _refreshPermissions() async {
    if (!kIsMacOS) return;
    final permission = runtime.permission();
    final screenCapture = await permission.isScreenRecordingPermissionGranted();
    final screenSelection = await permission.isAccessibilityPermissionGranted();
    if (!mounted) return;
    if (screenCapture == _isAllowedScreenCaptureAccess &&
        screenSelection == _isAllowedScreenSelectionAccess) {
      return;
    }
    _setStateAndScheduleWindowResize(() {
      _isAllowedScreenCaptureAccess = screenCapture;
      _isAllowedScreenSelectionAccess = screenSelection;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from System Settings is the moment the answer may have
    // changed — and the trip there is how it is changed at all.
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  void _handleChanged() {
    _setStateAndScheduleWindowResize(() {});
  }

  void _setStateAndScheduleWindowResize(
    VoidCallback fn, {
    bool animate = true,
  }) {
    if (!mounted) return;
    setState(fn);
    _scheduleWindowResize(animate: animate);
  }

  void _init() async {
    await _refreshPermissions();

    await Future.delayed(const Duration(milliseconds: 100));
    // This page is only built as part of the window's first show, which has
    // already placed the window (tray anchor, or the default in
    // showMiniTranslatorWindow) — moving it here would yank it away from
    // that anchor. Only seed the remembered position if nothing has yet.
    if (_lastShownPosition == Offset.zero) {
      if (kIsLinux || kIsWindows) {
        final primaryDisplay = nativeapi.DisplayManager.instance.getPrimary();
        if (primaryDisplay != null) {
          final windowSize = _window.size;
          _lastShownPosition = Offset(
            primaryDisplay.size.width - windowSize.width - 50,
            50,
          );
        }
      } else if (kIsMacOS) {
        final position = miniTranslatorPositionAtCursorScreenTopRight(
          windowSize: _window.size.toSize(),
        );
        if (position != null) {
          _lastShownPosition = position;
        }
      }
    }
    _setStateAndScheduleWindowResize(() {});
  }

  void _registerWindowEvents() {
    _windowFocusedListenerId =
        nativeapi.WindowManager.instance.addListener((event) {
      if (event is! nativeapi.WindowFocusedEvent) return;
      if (event.windowId == _window.id) {
        _focusNode.requestFocus();
        // The window comes back to the front after a trip to System Settings.
        _refreshPermissions();
      }
    });
    _windowBlurredListenerId =
        nativeapi.WindowManager.instance.addListener((event) {
      if (event is! nativeapi.WindowBlurredEvent) return;
      if (event.windowId == _window.id) {
        _focusNode.unfocus();
        // The pin state, not the window level: on macOS the window is always
        // at the floating level (see `app_windows.dart`).
        if (!_isAlwaysOnTop) {
          hideMiniTranslatorWindow();
        }
      }
    });
    _windowMovedListenerId =
        nativeapi.WindowManager.instance.addListener((event) {
      if (event is! nativeapi.WindowMovedEvent) return;
      if (event.windowId == _window.id) {
        _lastShownPosition = event.newPosition.toOffset();
      }
    });
  }

  void _unregisterWindowEvents() {
    if (_windowFocusedListenerId != null) {
      nativeapi.WindowManager.instance
          .removeListener(_windowFocusedListenerId!);
      _windowFocusedListenerId = null;
    }
    if (_windowBlurredListenerId != null) {
      nativeapi.WindowManager.instance
          .removeListener(_windowBlurredListenerId!);
      _windowBlurredListenerId = null;
    }
    if (_windowMovedListenerId != null) {
      nativeapi.WindowManager.instance.removeListener(_windowMovedListenerId!);
      _windowMovedListenerId = null;
    }
  }

  Future<void> _windowShow() async {
    final isAlwaysOnTop = _window.isAlwaysOnTop;
    // final windowSize = _window.size;

    if (kIsLinux) {
      _window.position = _lastShownPosition.toNative();
    }

    // if (kIsMacOS && isShowBelowTray) {
    //   final trayIconBounds = _trayIcon?.bounds;
    //   if (trayIconBounds != null) {
    //     final trayIconSize = trayIconBounds.size;
    //     final trayIconPosition = trayIconBounds.topLeft;

    //     Offset newPosition = Offset(
    //       trayIconPosition.dx - ((windowSize.width - trayIconSize.width) / 2),
    //       trayIconPosition.dy,
    //     );

    //     if (!isAlwaysOnTop) {
    //       _window.setPosition(newPosition.dx, newPosition.dy);
    //     }
    //   }
    // }

    final isVisible = _window.isVisible;
    if (!isVisible) {
      // Through the window layer, which owns the placement.
      await showMiniTranslatorWindow();
    } else {
      _window.focus();
    }
    _scheduleWindowResize(animate: false, settle: true);

    if (kIsLinux && !isAlwaysOnTop) {
      _window.isAlwaysOnTop = true;
      await Future.delayed(const Duration(milliseconds: 10));
      _window.isAlwaysOnTop = false;
      await Future.delayed(const Duration(milliseconds: 10));
      _window.focus();
    }
  }

  Future<void> _windowHide() async {
    hideMiniTranslatorWindow();
  }

  void _scheduleWindowResize({bool animate = true, bool settle = false}) {
    if (!(kIsLinux || kIsMacOS || kIsWindows)) return;

    _pendingWindowResizeAnimate = _isWindowResizeScheduled
        ? _pendingWindowResizeAnimate && animate
        : animate;
    _pendingWindowResizeSettle = _pendingWindowResizeSettle || settle;
    if (_isWindowResizeScheduled) return;

    _isWindowResizeScheduled = true;
    WidgetsBinding.instance.endOfFrame.then((_) {
      _isWindowResizeScheduled = false;
      final pendingAnimate = _pendingWindowResizeAnimate;
      final pendingSettle = _pendingWindowResizeSettle;
      _pendingWindowResizeAnimate = true;
      _pendingWindowResizeSettle = false;

      if (!mounted) return;
      _windowResize(animate: pendingAnimate);
      if (pendingSettle) {
        _scheduleSettledWindowResize(animate: pendingAnimate);
      }
    });
  }

  void _windowResize({bool animate = true}) {
    if (context.canPop()) return;

    try {
      final oldSize = _window.size.toSize();
      final newHeight = _measureWindowHeight();
      final newSize = Size(oldSize.width, newHeight.clamp(0, _maxWindowHeight));
      if (oldSize.width == newSize.width && oldSize.height == newSize.height) {
        return;
      }
      _window.setSize(newSize.toNative(), animate);
    } catch (error) {
      // ignore
    }
  }

  double _measureWindowHeight() {
    final toolbarViewHeight = _renderBoxHeight(_toolbarViewKey);
    final contentViewHeight = _renderBoxHeight(_contentViewKey);

    // Both keys sit inside the tray inset, so it has to be added back on.
    return toolbarViewHeight +
        contentViewHeight +
        (_kTrayInset * 2) +
        (kIsWindows ? 5 : 0);
  }

  double _renderBoxHeight(GlobalKey key) {
    final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
    return renderBox?.size.height ?? 0;
  }

  void _scheduleSettledWindowResize({bool animate = true}) {
    _resizeSettledTimer?.cancel();
    _resizeSettledTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _windowResize(animate: animate);
      _resizeSettledTimer = null;
    });
  }

  Future<void> _queryData() async {
    setState(() {
      _resultStale = false;
      _copiedTarget = null;
      // A new query asks the default service and nothing else, so the lists
      // fold back up: leaving one open would leave it staring at services
      // this query never ran.
      _compareOpen.clear();
    });
    await _controller.submit();
  }

  void _handleSourceChanged(String newSource) {
    _controller.setSourceLanguage(newSource);
    if (_text.isNotEmpty) _handleButtonTappedTrans();
  }

  void _handleTargetLanguageChanged(String? targetCode) {
    _controller.setTargetLanguage(targetCode);
    if (_text.isNotEmpty) _handleButtonTappedTrans();
  }

  Future<void> _handleConfigTargetSelected(int index) async {
    await _controller.selectConfiguredTarget(index);
    if (_text.isNotEmpty) _handleButtonTappedTrans();
  }

  void _handleManageTargets() {
    showSettingsWindow();
  }

  void _handleManageCommonLanguages() {
    ServicesSettingsPage.pendingOpenCommonLanguages = true;
    showSettingsWindow();
  }

  void _handleAddTarget() {
    ServicesSettingsPage.pendingOpenAddTarget = true;
    showSettingsWindow();
  }

  void _handleTextChanged(String? newValue, {bool isRequery = false}) {
    final previousText = _text;
    var text = (newValue ?? '').trim();
    if (settingsStore.inputSubmitMode == InputSubmitMode.enter) {
      text = text.replaceAll('\n', ' ');
    }
    // 原文已修改 — arm ⏎ 重新翻译 on the result block.
    if (_querySubmitted && text != previousText) _resultStale = true;
    _controller.setText(text);
    if (isRequery) {
      _textEditingController.text = _text;
      _textEditingController.selection = TextSelection(
        baseOffset: _text.length,
        extentOffset: _text.length,
      );
      _handleButtonTappedTrans();
    }
  }

  void _handleExtractTextFromScreenSelection() async {
    String? text;
    try {
      text = await runtime.textExtractor().extractFromScreenSelection();
    } catch (_) {
      // extractFromScreenSelection may throw if no text is selected or
      // operation fails (e.g. accessibility not granted on macOS).
    }

    await _windowShow();
    await Future.delayed(const Duration(milliseconds: 10));

    _handleTextChanged(text, isRequery: true);
  }

  void _handleExtractTextFromScreenCapture() async {
    _handleButtonTappedClear();
    _focusNode.unfocus();

    await _windowHide();

    try {
      final text = await runtime.textExtractor().extractFromScreenCapture();
      await _windowShow();
      _handleTextChanged(text, isRequery: true);
    } catch (error) {
      await _windowShow();
      if (!mounted) return;
      _setStateAndScheduleWindowResize(() {});
      showToast(
        context,
        '${t.mini_translator.message.ocr_recognition_failed}: ${error.toString()}',
        tone: ToastTint.danger,
      );
    }
  }

  bool _isExtractingClipboard = false;

  void _handleExtractTextFromClipboard() async {
    if (_isExtractingClipboard) return;
    _isExtractingClipboard = true;
    try {
      // Also focus an already visible window when invoked from a global shortcut.
      await _windowShow();
      if (!mounted) return;
      final text = await runtime.textExtractor().extractFromClipboard();
      if (!mounted) return;
      _handleTextChanged(text, isRequery: true);
    } catch (error) {
      if (!mounted) return;
      showToast(
        context,
        '${t.mini_translator.message.ocr_recognition_failed}: $error',
        tone: ToastTint.danger,
      );
    } finally {
      _isExtractingClipboard = false;
    }
  }

  void _handleButtonTappedClear() {
    _setStateAndScheduleWindowResize(() {
      _resultStale = false;
      _copiedTarget = null;
      _compareOpen.clear();
    });
    _controller.clear();
    _textEditingController.clear();
    _focusNode.requestFocus();
  }

  void _handleButtonTappedCopy() {
    final query = _controller.query;
    final target = query?.firstPreferredTarget;
    if (query == null || target == null) return;
    _copy(query.preferredText(target)!, _kCopiedAll);
  }

  /// 复制 on one target's attribution row — that language's preferred text.
  void _handleCopyTarget(String target) {
    final text = _controller.query?.preferredText(target);
    if (text != null) _copy(text, target);
  }

  void _copy(String text, String key) {
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _copiedTarget = key);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copiedTarget = null);
    });
  }

  void _handleToggleCompare(String target) {
    final opening = !_compareOpen.contains(target);
    _setStateAndScheduleWindowResize(() {
      if (opening) {
        _compareOpen.add(target);
      } else {
        _compareOpen.remove(target);
      }
    });
    // 失效清单 opens over a query that already failed; it lists the reasons
    // it has rather than starting new work.
    if (!opening || target == MiniTranslatorTranslation.kFailureListKey) {
      return;
    }
    unawaited(_controller.compare(target));
  }

  void _handleButtonTappedTrans() async {
    if (_text.isEmpty) {
      showToast(context, t.mini_translator.message.please_enter_word_or_text);
      _focusNode.requestFocus();
      return;
    }
    await _queryData();
  }

  Widget _buildBannersView(BuildContext context) {
    bool isNoAllowedAllAccess =
        !(_isAllowedScreenCaptureAccess && _isAllowedScreenSelectionAccess);

    if (!isNoAllowedAllAccess) return const SizedBox.shrink();

    return SizedBox(
      key: _bannersViewKey,
      width: double.infinity,
      child: LimitedFunctionalityBanner(
        isAllowedScreenCaptureAccess: _isAllowedScreenCaptureAccess,
        isAllowedScreenSelectionAccess: _isAllowedScreenSelectionAccess,
        onTappedRecheckIsAllowedAllAccess: () async {
          await _refreshPermissions();
          if (!context.mounted) return;

          final feedback = t.mini_translator.limited_banner.feedback;
          if (_isAllowedScreenCaptureAccess &&
              _isAllowedScreenSelectionAccess) {
            showToast(context, feedback.enabled, tone: ToastTint.success);
          } else {
            showToast(
              context,
              // Screen recording is the one macOS will not re-answer in this
              // process, so say what actually has to happen next.
              _isAllowedScreenCaptureAccess
                  ? feedback.still_missing
                  : feedback.still_missing_screen_capture,
              tone: ToastTint.warning,
            );
          }
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final query = _controller.query;
    final hasTranslation = query?.firstPreferredTarget != null;
    final noResult = query?.allFailed ?? false;
    // Several targets: 复制 moves onto each block's attribution row, and the
    // footer keeps only the paragraph-level 收藏 and 翻译.
    final stacked = (query?.targets.length ?? 0) > 1;
    // 语言文件未下载 on every target is a failed query like 未返回结果: nothing
    // to copy or star, and ⏎ is a retry.
    final allMissing = query?.allTargetsMissingLanguage ?? false;

    return Column(
      key: _contentViewKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildBannersView(context),
        // The deck's MiniPanel: input, result and dictionary share one card
        // floating on the tray. It spans the tray inset edge to edge — the
        // top bar and action bar add their own inner padding on top of it.
        PopoverPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              MiniTranslatorInput(
                focusNode: _focusNode,
                controller: _textEditingController,
                inputSubmitMode: settingsStore.inputSubmitMode,
                targetLanguageName: _controller.targetLanguage == null
                    ? null
                    : getLanguageName(_controller.targetLanguage!),
                sourceHeadingParts: sourceHeading(
                  _text.isEmpty
                      ? null
                      : getSourceDisplayName(
                          _controller.detectedLanguage ??
                              _controller.sourceLanguage,
                        ),
                  detectedAutomatically:
                      isAutoSource(_controller.sourceLanguage),
                ),
                onChanged: (v) => _handleTextChanged(v),
                onSubmitted: _handleButtonTappedTrans,
              ),
              // 两块之间的接缝：译文不再回答上面的原文了。
              if (_resultStale && _querySubmitted)
                MiniTranslatorStaleNotice(
                  inputSubmitMode: settingsStore.inputSubmitMode,
                  onRequery: _handleButtonTappedTrans,
                ),
              MiniTranslatorTranslation(
                query: query,
                inputSubmitMode: settingsStore.inputSubmitMode,
                matchedAutomatically: _controller.targetLanguage == null,
                compareOpenTargets: _compareOpen,
                copiedTarget: _copiedTarget,
                onToggleCompare: _handleToggleCompare,
                onCopyTarget: _handleCopyTarget,
                onRequery: _handleButtonTappedTrans,
              ),
              MiniTranslatorWordDefinition(lookUp: query?.dictionary),
            ],
          ),
        ),
        MiniTranslatorActionButtons(
          inputSubmitMode: settingsStore.inputSubmitMode,
          hasContent: hasTranslation && !allMissing,
          copyVisible: !stacked,
          copied: _copiedTarget == _kCopiedAll,
          starred: _controller.starred,
          translateEnabled: _text.isNotEmpty,
          // 原文译文皆无 —— 开局还没输入 —— 清空无从谈起，整颗收起来。
          clearVisible: _text.isNotEmpty || _querySubmitted,
          retry: noResult || allMissing,
          onCopy: _handleButtonTappedCopy,
          onBookmark: _controller.toggleFavorite,
          onTranslate: _handleButtonTappedTrans,
          onClear: _handleButtonTappedClear,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // The window itself is the deck's MiniWindow tray: the top bar and the
    // action bar sit directly on it, the panel card floats between them.
    // A `Scaffold` used to paint this; all it was giving the window was its
    // ground, and the tray draws everything else itself.
    //
    // The tray is the paper. `colorSurfaceMuted` is the card sitting on it —
    // "the card, the panel, the toolbar", in the token's own words — and the
    // two were the other way round here, which held in every palette but
    // Bright: Bright's card steps *up* to white where Studio's steps down, so
    // it landed on the same white the tray had taken, and the panel vanished
    // into the window.
    return ColoredBox(
      color: context.vars.colorSurface,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(
          horizontal: _kTrayInsetX,
          vertical: _kTrayInset,
        ),
        // The window follows the content's laid-out height, not just this
        // page's own `setState`s: the kit's widgets, fonts and images settle
        // their size on later frames, and those changes never pass through
        // here.
        child: _SizeChangedObserver(
          onSizeChanged: () => _scheduleWindowResize(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MiniTranslatorTopBar(
                key: _toolbarViewKey,
                sourceLanguage: _controller.sourceLanguage,
                selectedTargetLanguage: _controller.targetLanguage,
                activeConfigIndex: _controller.configuredTargetIndex,
                persistentTargets: settingsStore.general.translationTargets,
                commonLanguageCodes:
                    settingsStore.general.commonLanguages.isNotEmpty
                        ? settingsStore.general.commonLanguages
                        : defaultCommonLanguages(),
                onSourceChanged: _handleSourceChanged,
                onTargetLanguageChanged: _handleTargetLanguageChanged,
                onConfigTargetSelected: _handleConfigTargetSelected,
                onManageCommonLanguages: _handleManageCommonLanguages,
                onAddTarget: _handleAddTarget,
                onManageTargets: _handleManageTargets,
                isAlwaysOnTop: _isAlwaysOnTop,
                onTogglePin: () {
                  setState(() {
                    _isAlwaysOnTop = !_isAlwaysOnTop;
                  });
                  // On macOS the panel lives at the floating level regardless;
                  // the pin only exempts it from closing on blur.
                  if (!kIsMacOS) _window.isAlwaysOnTop = _isAlwaysOnTop;
                },
                onExtractScreenCapture: _handleExtractTextFromScreenCapture,
                onExtractClipboard: _handleExtractTextFromClipboard,
                onOpenWorkbench: () => handOffToWorkbench(_text),
                onOpenSettings: showSettingsWindow,
              ),
              _buildBody(context),
            ],
          ),
        ),
      ),
    );
  }

  // TODO: Re-implement protocol URL handling when protocol_handler is restored
  // @override
  // void onProtocolUrlReceived(String url) async {
  //   Uri uri = Uri.parse(url);
  //   if (uri.scheme != 'beyondtranslate') return;
  //
  //   if (uri.authority == 'translate') {
  //     if (_text.isNotEmpty) _handleButtonTappedClear();
  //     String? text = uri.queryParameters['text'];
  //     if (text != null && text.isNotEmpty) {
  //       _handleTextChanged(text, isRequery: true);
  //     }
  //   }
  //   await _windowShow();
  // }

  @override
  void onShortcutKeyDownToggleMiniTranslator() async {
    final isVisible = _window.isVisible;
    if (isVisible) {
      _windowHide();
    } else {
      _windowShow();
    }
  }

  @override
  void onShortcutKeyDownExtractFromScreenSelection() {
    _handleExtractTextFromScreenSelection();
  }

  @override
  void onShortcutKeyDownExtractFromScreenCapture() {
    _handleExtractTextFromScreenCapture();
  }

  @override
  void onShortcutKeyDownExtractFromClipboard() {
    _handleExtractTextFromClipboard();
  }
}

/// Calls [onSizeChanged] after any frame that lays [child] out at a new size.
class _SizeChangedObserver extends SingleChildRenderObjectWidget {
  const _SizeChangedObserver({
    required this.onSizeChanged,
    required Widget super.child,
  });

  final VoidCallback onSizeChanged;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSizeChangedObserver(onSizeChanged);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeChangedObserver renderObject,
  ) {
    renderObject.onSizeChanged = onSizeChanged;
  }
}

class _RenderSizeChangedObserver extends RenderProxyBox {
  _RenderSizeChangedObserver(this.onSizeChanged);

  VoidCallback onSizeChanged;
  Size? _lastSize;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _lastSize) return;
    _lastSize = size;
    // Not during layout: the callback reads the window and may resize it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onSizeChanged();
    });
  }
}

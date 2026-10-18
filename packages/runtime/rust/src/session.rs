//! The translation backend both windows run on.
//!
//! A [`RuntimeTranslationSession`] holds the language pair, the query and what every
//! service made of it, the 对比 requests, the dictionary look-up and the
//! history entry — one set of rules, whichever window (or language binding)
//! asked. The windows draw a [`TranslationSessionState`] snapshot and are told
//! through a [`TranslationSessionListener`] when to read a fresh one.
//!
//! The rules, in short: a submit runs detection, resolves 自动匹配 through the
//! configured translation targets, asks the default translation service for
//! every target and the first dictionary for the first, and records the first
//! target's translation in history. The other services wait for
//! [`RuntimeTranslationSession::compare`], which asks each of them once per query. A
//! target's block belongs to the default service whatever it answered; with no
//! default, the first service that answered stands in.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use async_trait::async_trait;
use beyondtranslate_core::{
    DetectLanguageRequest, LookUpRequest, LookUpResponse, TranslateRequest, TranslateResponse,
    TranslationTarget,
};
use futures::future::join_all;

use crate::domain::history::{HistoryEntry, HistoryEntryInput};
use crate::domain::settings::{
    GeneralSettings, ProviderConfigEntry, ServiceConfigEntry, ServiceType, SYSTEM_PROVIDER_ID,
};
use crate::runtime::{Runtime, StreamCallback};

/// How the system translator reports a pair it has no language files for.
/// The app side parses the same marker to name the pair and point at the fix.
const MISSING_LANGUAGE_MARKER: &str = "language pair not installed:";

/// The field 服务 writes when a service is switched off.
const ENABLED_FIELD: &str = "enabled";

/// The suffixes the runtime appends when it synthesises a service from a
/// provider's capabilities.
const IMPLICIT_SERVICE_SUFFIXES: [&str; 3] = ["+translation", "+dictionary", "+ocr"];

/// What the session needs from the runtime, behind a trait so the rules can
/// be exercised without providers.
#[async_trait]
pub(crate) trait SessionBackend: Send + Sync {
    async fn list_providers(&self) -> Result<Vec<ProviderConfigEntry>, String>;

    async fn list_services(&self) -> Result<Vec<ServiceConfigEntry>, String>;

    async fn general(&self) -> GeneralSettings;

    /// Whether the service answers through an LLM and should be streamed.
    async fn service_streams(&self, service_id: &str) -> bool;

    async fn detect_language(&self, service_id: &str, text: &str)
        -> Result<Option<String>, String>;

    async fn translate(
        &self,
        service_id: &str,
        request: TranslateRequest,
    ) -> Result<TranslateResponse, String>;

    /// Streams a translation, handing each chunk to `on_chunk` as it arrives,
    /// and returns once the stream has finished.
    async fn translate_stream(
        &self,
        service_id: &str,
        source_language: &str,
        target_language: &str,
        text: &str,
        on_chunk: Arc<dyn Fn(String) + Send + Sync>,
    ) -> Result<(), String>;

    async fn lookup(
        &self,
        service_id: &str,
        request: LookUpRequest,
    ) -> Result<LookUpResponse, String>;

    async fn upsert_history(&self, input: HistoryEntryInput) -> Result<HistoryEntry, String>;

    async fn set_history_favorite(
        &self,
        entry_id: &str,
        favorite: bool,
    ) -> Result<Option<HistoryEntry>, String>;
}

/// The backend over a live [`Runtime`].
struct RuntimeBackend {
    runtime: Runtime,
}

impl RuntimeBackend {
    fn handle(&self) -> Arc<Runtime> {
        Arc::new(self.runtime.clone())
    }
}

#[async_trait]
impl SessionBackend for RuntimeBackend {
    async fn list_providers(&self) -> Result<Vec<ProviderConfigEntry>, String> {
        self.handle()
            .settings()
            .list_providers()
            .await
            .map_err(|error| error.to_string())
    }

    async fn list_services(&self) -> Result<Vec<ServiceConfigEntry>, String> {
        self.handle()
            .settings()
            .list_services()
            .await
            .map_err(|error| error.to_string())
    }

    async fn general(&self) -> GeneralSettings {
        self.handle()
            .settings()
            .get_general()
            .await
            .unwrap_or_default()
    }

    async fn service_streams(&self, service_id: &str) -> bool {
        self.runtime.service_streams(service_id).await
    }

    async fn detect_language(
        &self,
        service_id: &str,
        text: &str,
    ) -> Result<Option<String>, String> {
        let translation = self
            .handle()
            .translation(service_id.to_owned())
            .map_err(|error| error.to_string())?;
        let response = translation
            .detect_language(DetectLanguageRequest {
                texts: vec![text.to_owned()],
            })
            .await
            .map_err(|error| error.to_string())?;
        Ok(response
            .detections
            .and_then(|detections| detections.into_iter().next())
            .and_then(|detection| detection.detected_language))
    }

    async fn translate(
        &self,
        service_id: &str,
        request: TranslateRequest,
    ) -> Result<TranslateResponse, String> {
        self.handle()
            .translation(service_id.to_owned())
            .map_err(|error| error.to_string())?
            .translate(request)
            .await
            .map_err(|error| error.to_string())
    }

    async fn translate_stream(
        &self,
        service_id: &str,
        source_language: &str,
        target_language: &str,
        text: &str,
        on_chunk: Arc<dyn Fn(String) + Send + Sync>,
    ) -> Result<(), String> {
        let llm = self
            .handle()
            .llm(service_id.to_owned())
            .map_err(|error| error.to_string())?;
        let (sender, receiver) = tokio::sync::oneshot::channel();
        llm.translate_stream(
            source_language.to_owned(),
            target_language.to_owned(),
            text.to_owned(),
            Box::new(ForwardingCallback {
                on_chunk,
                done: Mutex::new(Some(sender)),
            }),
        );
        receiver
            .await
            .map_err(|_| "translation stream ended without finishing".to_owned())?
    }

    async fn lookup(
        &self,
        service_id: &str,
        request: LookUpRequest,
    ) -> Result<LookUpResponse, String> {
        self.handle()
            .dictionary(service_id.to_owned())
            .map_err(|error| error.to_string())?
            .lookup(request)
            .await
            .map_err(|error| error.to_string())
    }

    async fn upsert_history(&self, input: HistoryEntryInput) -> Result<HistoryEntry, String> {
        self.handle()
            .history()
            .upsert_entry(input)
            .await
            .map_err(|error| error.to_string())
    }

    async fn set_history_favorite(
        &self,
        entry_id: &str,
        favorite: bool,
    ) -> Result<Option<HistoryEntry>, String> {
        self.handle()
            .history()
            .set_favorite(entry_id.to_owned(), favorite)
            .await
            .map_err(|error| error.to_string())
    }
}

/// Turns the fire-and-forget [`StreamCallback`] into chunks plus a completion.
struct ForwardingCallback {
    on_chunk: Arc<dyn Fn(String) + Send + Sync>,
    done: Mutex<Option<tokio::sync::oneshot::Sender<Result<(), String>>>>,
}

impl ForwardingCallback {
    fn finish(&self, result: Result<(), String>) {
        if let Some(sender) = lock(&self.done).take() {
            let _ = sender.send(result);
        }
    }
}

impl StreamCallback for ForwardingCallback {
    fn on_chunk(&self, content: String) {
        (self.on_chunk)(content);
    }

    fn on_finish(&self, _finish_reason: String) {
        self.finish(Ok(()));
    }

    fn on_error(&self, error: String) {
        self.finish(Err(error));
    }
}

/// Told when the session's state changed; read [`RuntimeTranslationSession::state`]
/// for what it is now.
#[uniffi::export(callback_interface)]
pub trait TranslationSessionListener: Send + Sync {
    fn on_change(&self);
}

/// What one service made of one target. 自动匹配 can ask for several languages
/// at once, and each keeps its own text, error and in-flight flag.
///
/// A service is only asked when a request actually goes out — on submit for
/// the default service, when 对比 opens for the rest — so an output that was
/// never `asked` is idle, not pending.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TranslationOutputState {
    pub target: String,
    /// A request went out for this output.
    pub asked: bool,
    /// The request is still in flight.
    pub loading: bool,
    pub text: String,
    pub audio_url: Option<String>,
    /// Why the service came back empty, as it put it. An empty string means
    /// it answered with nothing and gave no reason.
    pub error: Option<String>,
    /// Asked, and nothing has come back yet — the block's spinner. An LLM
    /// that has started streaming has text, and shows it.
    pub translating: bool,
    /// Asked, settled, and nothing to show: the service gave a reason instead.
    pub failed: bool,
    /// 系统翻译 without this pair's language files — the one failure the UI
    /// can point at a fix for.
    pub missing_language: bool,
}

/// One service's outputs for one query, one per resolved target.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TranslationServiceResultState {
    pub service: ServiceConfigEntry,
    pub provider: Option<ProviderConfigEntry>,
    /// One output per target, in the order the targets were resolved.
    pub outputs: Vec<TranslationOutputState>,
}

/// What a target's block shows: which service it speaks for, and that
/// service's translation once it has one.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TranslationBlockState {
    pub target: String,
    pub service_id: Option<String>,
    pub preferred_text: Option<String>,
}

/// One submitted query: the text, the targets it resolved to, what every
/// enabled translation service made of each, the dictionary's answer — and
/// what the windows derive from that, decided here, once.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TranslationQueryState {
    /// The trimmed source text.
    pub text: String,
    /// The languages translated into, in order. Never empty.
    pub targets: Vec<String>,
    /// Every enabled translation service, in 服务 order, asked or not.
    pub results: Vec<TranslationServiceResultState>,
    /// The service 设置 › 服务 marks 默认, if it is among `results`.
    pub default_service_id: Option<String>,
    /// The service a submit runs: the default, or with none marked, the
    /// first enabled one.
    pub lead_service_id: Option<String>,
    /// 词典 — the first dictionary service's answer for the first target.
    pub dictionary: Option<LookUpResponse>,
    /// One per target, in `targets` order.
    pub blocks: Vec<TranslationBlockState>,
    /// The first target that has a translation to show — what 复制 on the
    /// footer copies and what history records.
    pub first_preferred_target: Option<String>,
    /// Requests still in flight with nothing shown yet.
    pub pending_count: u32,
    /// One entry per service that failed on any target, in 服务 order.
    pub failed_service_ids: Vec<String>,
    /// 服务全部失效: nothing came back, nothing is pending, and something
    /// failed — unless what failed is 系统翻译 lacking the language files,
    /// which the target's own block reports, with the fix.
    pub all_failed: bool,
    /// 语言文件未下载 on every target: a failed query like 服务全部失效 —
    /// nothing to read, copy or star, and ⏎ is a retry.
    pub all_targets_missing_language: bool,
}

/// Everything a window draws.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TranslationSessionState {
    pub source_language: String,
    /// The target the user picked, or null for 自动匹配 — the target menu's
    /// first item, which hands the choice to the configured translation
    /// targets.
    pub target_language: Option<String>,
    /// The configured target the menu picked as a pair, or -1.
    pub configured_target_index: i32,
    /// The languages a submit actually translates into: the pick when there
    /// is one, otherwise whatever 自动匹配 resolved to last. Never empty.
    pub effective_targets: Vec<String>,
    pub detected_language: Option<String>,
    pub text: String,
    pub loading_services: bool,
    pub submitting: bool,
    pub setup_error: Option<String>,
    /// Whether the query's history entry is 收藏.
    pub starred: bool,
    pub providers: Vec<ProviderConfigEntry>,
    pub services: Vec<ServiceConfigEntry>,
    /// The last submitted query, or null before the first (and after 清空).
    pub query: Option<TranslationQueryState>,
}

#[derive(Clone, Debug)]
struct Output {
    target: String,
    asked: bool,
    loading: bool,
    text: String,
    audio_url: Option<String>,
    error: Option<String>,
}

impl Output {
    fn new(target: &str) -> Self {
        Self {
            target: target.to_owned(),
            asked: false,
            loading: false,
            text: String::new(),
            audio_url: None,
            error: None,
        }
    }

    fn has_text(&self) -> bool {
        !self.text.trim().is_empty()
    }

    fn translating(&self) -> bool {
        self.asked && self.loading && !self.has_text()
    }

    fn failed(&self) -> bool {
        self.asked && !self.loading && !self.has_text()
    }

    fn missing_language(&self) -> bool {
        self.failed()
            && self
                .error
                .as_deref()
                .is_some_and(|error| error.contains(MISSING_LANGUAGE_MARKER))
    }

    fn state(&self) -> TranslationOutputState {
        TranslationOutputState {
            target: self.target.clone(),
            asked: self.asked,
            loading: self.loading,
            text: self.text.clone(),
            audio_url: self.audio_url.clone(),
            error: self.error.clone(),
            translating: self.translating(),
            failed: self.failed(),
            missing_language: self.missing_language(),
        }
    }
}

#[derive(Clone, Debug)]
struct ServiceResult {
    service: ServiceConfigEntry,
    provider: Option<ProviderConfigEntry>,
    /// Answers through an LLM, so it is asked to stream.
    streams: bool,
    outputs: Vec<Output>,
}

impl ServiceResult {
    fn output(&self, target: &str) -> Option<&Output> {
        self.outputs.iter().find(|output| output.target == target)
    }

    fn output_mut(&mut self, target: &str) -> Option<&mut Output> {
        self.outputs
            .iter_mut()
            .find(|output| output.target == target)
    }

    fn has_any_text(&self) -> bool {
        self.outputs.iter().any(Output::has_text)
    }

    /// The first target this service failed on, if any. A service that failed
    /// for every target is one failure, not one per target.
    fn first_failure(&self) -> Option<&Output> {
        self.outputs.iter().find(|output| output.failed())
    }

    fn reset_targets(&mut self, targets: &[String]) {
        self.outputs = targets.iter().map(|target| Output::new(target)).collect();
    }

    fn state(&self) -> TranslationServiceResultState {
        TranslationServiceResultState {
            service: self.service.clone(),
            provider: self.provider.clone(),
            outputs: self.outputs.iter().map(Output::state).collect(),
        }
    }
}

#[derive(Clone, Debug)]
struct Query {
    text: String,
    targets: Vec<String>,
    results: Vec<ServiceResult>,
    default_service_id: Option<String>,
    dictionary: Option<LookUpResponse>,
}

impl Query {
    fn lead_service_id(&self) -> Option<String> {
        self.default_service_id
            .clone()
            .or_else(|| self.results.first().map(|result| result.service.id.clone()))
    }

    fn result_index(&self, service_id: &str) -> Option<usize> {
        self.results
            .iter()
            .position(|result| result.service.id == service_id)
    }

    /// The service a target's block speaks for: the default, whatever state
    /// it is in — its text, its failure, or its spinner. The other services
    /// only ever appear in the compare list, so nothing they do can take this
    /// slot.
    ///
    /// With no default among the enabled services there is nothing to be
    /// faithful to: the block follows the first service that answered, and
    /// before any of them has, the first that was asked.
    fn block_index(&self, target: &str) -> Option<usize> {
        if let Some(default) = &self.default_service_id {
            return self.result_index(default);
        }
        let with_text = self.results.iter().position(|result| {
            result
                .output(target)
                .is_some_and(|output| output.has_text())
        });
        if with_text.is_some() {
            return with_text;
        }
        let asked = self
            .results
            .iter()
            .position(|result| result.output(target).is_some_and(|output| output.asked));
        if asked.is_some() {
            return asked;
        }
        (!self.results.is_empty()).then_some(0)
    }

    fn block_output(&self, target: &str) -> Option<&Output> {
        self.results[self.block_index(target)?].output(target)
    }

    fn preferred_text(&self, target: &str) -> Option<String> {
        self.block_output(target)
            .filter(|output| output.has_text())
            .map(|output| output.text.clone())
    }

    fn first_preferred_target(&self) -> Option<String> {
        self.targets
            .iter()
            .find(|target| self.preferred_text(target).is_some())
            .cloned()
    }

    fn has_any_text(&self) -> bool {
        self.results.iter().any(ServiceResult::has_any_text)
    }

    fn pending_count(&self) -> u32 {
        self.results
            .iter()
            .flat_map(|result| result.outputs.iter())
            .filter(|output| output.translating())
            .count() as u32
    }

    fn failures(&self) -> Vec<(&ServiceResult, &Output)> {
        self.results
            .iter()
            .filter_map(|result| result.first_failure().map(|output| (result, output)))
            .collect()
    }

    fn all_failed(&self) -> bool {
        let failures = self.failures();
        !self.has_any_text()
            && self.pending_count() == 0
            && !failures.is_empty()
            && !failures.iter().any(|(_, output)| output.missing_language())
    }

    fn all_targets_missing_language(&self) -> bool {
        self.targets.iter().all(|target| {
            self.block_output(target)
                .is_some_and(|output| output.missing_language())
        })
    }

    /// Re-key the outputs once 自动匹配 has resolved: the query was armed on
    /// the standing targets, and what detection routed to may differ.
    fn reset_targets(&mut self, targets: Vec<String>) {
        for result in &mut self.results {
            result.reset_targets(&targets);
        }
        self.targets = targets;
    }

    fn state(&self) -> TranslationQueryState {
        TranslationQueryState {
            text: self.text.clone(),
            targets: self.targets.clone(),
            results: self.results.iter().map(ServiceResult::state).collect(),
            default_service_id: self.default_service_id.clone(),
            lead_service_id: self.lead_service_id(),
            dictionary: self.dictionary.clone(),
            blocks: self
                .targets
                .iter()
                .map(|target| TranslationBlockState {
                    target: target.clone(),
                    service_id: self
                        .block_index(target)
                        .map(|index| self.results[index].service.id.clone()),
                    preferred_text: self.preferred_text(target),
                })
                .collect(),
            first_preferred_target: self.first_preferred_target(),
            pending_count: self.pending_count(),
            failed_service_ids: self
                .failures()
                .iter()
                .map(|(result, _)| result.service.id.clone())
                .collect(),
            all_failed: self.all_failed(),
            all_targets_missing_language: self.all_targets_missing_language(),
        }
    }
}

/// The history entry behind the query, kept across re-saves (an edit, a
/// 收藏) so the same source text updates one entry rather than adding more.
#[derive(Debug, Default)]
struct HistoryState {
    source: Option<String>,
    entry_id: Option<String>,
    favorite: bool,
}

impl HistoryState {
    /// Starts a query on `source`; a different text from last time is a new
    /// entry.
    fn begin_source(&mut self, source: &str) -> bool {
        let changed = self.source.as_deref().is_some_and(|known| known != source);
        if changed {
            self.entry_id = None;
            self.favorite = false;
        }
        self.source = Some(source.to_owned());
        changed
    }

    fn reset(&mut self) {
        *self = Self::default();
    }
}

#[derive(Debug)]
struct SessionState {
    source_language: String,
    target_language: Option<String>,
    configured_target_index: i32,
    /// What 自动匹配 last landed on. Concrete languages are needed before the
    /// query is sent — for the input placeholder and for what history records.
    resolved_targets: Vec<String>,
    detected_language: Option<String>,
    text: String,
    loading_services: bool,
    submitting: bool,
    setup_error: Option<String>,
    starred: bool,
    providers: Vec<ProviderConfigEntry>,
    services: Vec<ServiceConfigEntry>,
    /// What the windows call each service, for the history entry.
    service_names: HashMap<String, String>,
    query: Option<Query>,
    /// Bumped by every submit and 清空; an answer carrying an older id landed
    /// too late and goes nowhere.
    request_id: u64,
    history: HistoryState,
}

impl SessionState {
    fn effective_targets(&self) -> Vec<String> {
        match &self.target_language {
            Some(picked) => vec![picked.clone()],
            None => self.resolved_targets.clone(),
        }
    }

    // A service switched off on 服务 takes no part in a query.
    fn translation_services(&self) -> Vec<&ServiceConfigEntry> {
        self.services
            .iter()
            .filter(|service| service.r#type == ServiceType::Translation && is_enabled(service))
            .collect()
    }

    fn dictionary_services(&self) -> Vec<&ServiceConfigEntry> {
        self.services
            .iter()
            .filter(|service| service.r#type == ServiceType::Dictionary && is_enabled(service))
            .collect()
    }

    fn provider_for(&self, service: &ServiceConfigEntry) -> Option<ProviderConfigEntry> {
        self.providers
            .iter()
            .find(|provider| provider.id == service.provider_id)
            .cloned()
    }

    fn with_output(&mut self, service_id: &str, target: &str, update: impl FnOnce(&mut Output)) {
        let Some(query) = self.query.as_mut() else {
            return;
        };
        let Some(index) = query.result_index(service_id) else {
            return;
        };
        if let Some(output) = query.results[index].output_mut(target) {
            update(output);
        }
    }

    fn snapshot(&self) -> TranslationSessionState {
        TranslationSessionState {
            source_language: self.source_language.clone(),
            target_language: self.target_language.clone(),
            configured_target_index: self.configured_target_index,
            effective_targets: self.effective_targets(),
            detected_language: self.detected_language.clone(),
            text: self.text.clone(),
            loading_services: self.loading_services,
            submitting: self.submitting,
            setup_error: self.setup_error.clone(),
            starred: self.starred,
            providers: self.providers.clone(),
            services: self.services.clone(),
            query: self.query.as_ref().map(Query::state),
        }
    }
}

fn is_enabled(service: &ServiceConfigEntry) -> bool {
    service
        .fields
        .get(ENABLED_FIELD)
        .is_none_or(|value| value != "false")
}

/// True when the runtime derived this service from its provider rather than
/// the user creating it.
fn is_implicit(service: &ServiceConfigEntry) -> bool {
    service.provider_id == SYSTEM_PROVIDER_ID
        || IMPLICIT_SERVICE_SUFFIXES
            .iter()
            .any(|suffix| service.id == format!("{}{suffix}", service.provider_id))
}

/// Whether `current` — 设置 › 服务 › 默认 — names this service: by its own id,
/// or by its provider's for a service the runtime synthesised.
fn is_default(service: &ServiceConfigEntry, current: &str) -> bool {
    current == service.id || (is_implicit(service) && current == service.provider_id)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct SessionInner {
    backend: Arc<dyn SessionBackend>,
    initial_target_language: String,
    dictionary_enabled: bool,
    state: Mutex<SessionState>,
    listener: Mutex<Option<Arc<dyn TranslationSessionListener>>>,
}

/// The translation backend a window runs on — see the module docs.
#[derive(uniffi::Object)]
pub struct RuntimeTranslationSession {
    inner: Arc<SessionInner>,
}

impl RuntimeTranslationSession {
    pub(crate) fn for_runtime(
        runtime: Runtime,
        initial_target_language: String,
        dictionary_enabled: bool,
    ) -> Arc<Self> {
        Self::with_backend(
            Arc::new(RuntimeBackend { runtime }),
            initial_target_language,
            dictionary_enabled,
        )
    }

    pub(crate) fn with_backend(
        backend: Arc<dyn SessionBackend>,
        initial_target_language: String,
        dictionary_enabled: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            inner: Arc::new(SessionInner {
                backend,
                state: Mutex::new(SessionState {
                    source_language: TranslationTarget::AUTO_SOURCE.to_owned(),
                    target_language: None,
                    configured_target_index: -1,
                    resolved_targets: vec![initial_target_language.clone()],
                    detected_language: None,
                    text: String::new(),
                    loading_services: true,
                    submitting: false,
                    setup_error: None,
                    starred: false,
                    providers: Vec::new(),
                    services: Vec::new(),
                    service_names: HashMap::new(),
                    query: None,
                    request_id: 0,
                    history: HistoryState::default(),
                }),
                listener: Mutex::new(None),
                initial_target_language,
                dictionary_enabled,
            }),
        })
    }
}

#[uniffi::export]
impl RuntimeTranslationSession {
    /// Who to tell when the state changes. One listener at a time: the
    /// window that owns the session.
    pub fn set_listener(&self, listener: Box<dyn TranslationSessionListener>) {
        *lock(&self.inner.listener) = Some(listener.into());
    }

    pub fn state(&self) -> TranslationSessionState {
        lock(&self.inner.state).snapshot()
    }

    /// What the window calls each service — the history entry carries the
    /// name the user saw.
    pub fn set_service_names(&self, names: HashMap<String, String>) {
        lock(&self.inner.state).service_names = names;
    }

    pub fn set_text(&self, text: String) {
        self.inner.update(|state| state.text = text);
    }

    /// Picking a source on its own is a pair of the user's making: it clears
    /// the configured pick.
    pub fn set_source_language(&self, language: String) {
        self.inner.update(|state| {
            state.source_language = language;
            state.configured_target_index = -1;
        });
    }

    /// `None` is 自动匹配.
    pub fn set_target_language(&self, language: Option<String>) {
        self.inner.update(|state| {
            state.target_language = language;
            state.configured_target_index = -1;
        });
    }

    /// 清空 — drops the text, the query and its history entry; in-flight
    /// requests land nowhere.
    pub fn clear(&self) {
        self.inner.update(|state| {
            state.request_id += 1;
            state.text.clear();
            state.detected_language = None;
            state.query = None;
            state.submitting = false;
            state.starred = false;
            state.history.reset();
        });
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl RuntimeTranslationSession {
    /// Loads the roster. The capsule starts on 自动检测 ⇄ 自动匹配; the first
    /// enabled configured target is what stands behind 自动匹配 until a query
    /// resolves it.
    pub async fn initialize(&self) {
        self.inner.clone().initialize().await;
    }

    /// Picks a configured target as the pair; an `index` out of range goes
    /// back to 自动检测 ⇄ 自动匹配.
    pub async fn select_configured_target(&self, index: i32) {
        self.inner.clone().select_configured_target(index).await;
    }

    /// Runs the query; returns once every request it sent has landed.
    pub async fn submit(&self) {
        self.inner.clone().submit().await;
    }

    /// 对比 — asks the services the submit skipped for `target`, each once
    /// per query.
    pub async fn compare(&self, target: String) {
        self.inner.clone().compare(target).await;
    }

    /// Records the query in history — the first target's translation, by the
    /// service whose block shows it. `override_text` is the user's own edit of
    /// that translation; `edited` marks the entry as such.
    pub async fn save_history(&self, override_text: Option<String>, edited: bool) {
        self.inner.clone().save_history(override_text, edited).await;
    }

    /// 收藏 — saves the entry first if the query has none yet.
    pub async fn toggle_favorite(&self, override_text: Option<String>, edited: bool) {
        self.inner
            .clone()
            .toggle_favorite(override_text, edited)
            .await;
    }
}

impl SessionInner {
    fn notify(&self) {
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_change();
        }
    }

    /// Applies `change` and tells the listener.
    fn update<R>(&self, change: impl FnOnce(&mut SessionState) -> R) -> R {
        let result = change(&mut lock(&self.state));
        self.notify();
        result
    }

    /// Applies `change` unless the request it belongs to was superseded, in
    /// which case the answer landed too late and goes nowhere.
    fn update_if(&self, request_id: u64, change: impl FnOnce(&mut SessionState)) -> bool {
        {
            let mut state = lock(&self.state);
            if state.request_id != request_id {
                return false;
            }
            change(&mut state);
        }
        self.notify();
        true
    }

    fn is_current(&self, request_id: u64) -> bool {
        lock(&self.state).request_id == request_id
    }

    async fn initialize(self: Arc<Self>) {
        self.update(|state| {
            state.loading_services = true;
            state.setup_error = None;
        });
        let providers = self.backend.list_providers().await;
        let services = self.backend.list_services().await;
        let general = self.backend.general().await;
        self.update(|state| {
            match (providers, services) {
                (Ok(providers), Ok(services)) => {
                    state.providers = providers;
                    state.services = services;
                    let standing = general
                        .translation_targets
                        .iter()
                        .find(|target| target.enabled)
                        .map(|target| target.target.clone())
                        .unwrap_or_else(|| self.initial_target_language.clone());
                    state.resolved_targets = vec![standing];
                }
                (Err(error), _) | (_, Err(error)) => state.setup_error = Some(error),
            }
            state.loading_services = false;
        });
    }

    async fn select_configured_target(self: Arc<Self>, index: i32) {
        let configured = self.backend.general().await.translation_targets;
        self.update(|state| {
            match usize::try_from(index)
                .ok()
                .and_then(|index| configured.get(index))
            {
                Some(target) => {
                    state.configured_target_index = index;
                    state.source_language = target.source.clone();
                    state.target_language = Some(target.target.clone());
                }
                None => {
                    state.configured_target_index = -1;
                    state.source_language = TranslationTarget::AUTO_SOURCE.to_owned();
                    state.target_language = None;
                }
            }
        });
    }

    /// Detection, 自动匹配, the default service for every target, and the
    /// dictionary. The other services wait for [`Self::compare`], so a query
    /// costs one translation per target however many services are configured
    /// — for LLM services, money otherwise spent on text nobody reads.
    async fn submit(self: Arc<Self>) {
        let Some((request_id, text, standing, lead, dictionary)) = self.arm_query().await else {
            return;
        };

        self.detect_language(request_id, &text).await;
        if !self.is_current(request_id) {
            return;
        }

        // 自动匹配 can only be settled once detection has spoken, so the
        // targets are resolved here rather than when they were picked.
        let targets = self.resolve_targets(request_id, &text).await;
        if !self.is_current(request_id) {
            return;
        }
        if targets != standing {
            let targets = targets.clone();
            self.update_if(request_id, |state| {
                if let Some(query) = state.query.as_mut() {
                    query.reset_targets(targets);
                }
            });
        }

        let mut requests = Vec::new();
        if let Some((service_id, streams)) = lead {
            for target in &targets {
                requests.push(self.translate_output(
                    request_id,
                    service_id.clone(),
                    streams,
                    target.clone(),
                    text.clone(),
                ));
            }
        }
        let lookup = dictionary.map(|service_id| {
            self.look_up(request_id, service_id, targets[0].clone(), text.clone())
        });
        let (_, _) = futures::join!(join_all(requests), async {
            if let Some(lookup) = lookup {
                lookup.await;
            }
        });

        if !self.update_if(request_id, |state| state.submitting = false) {
            return;
        }
        self.clone().save_history(None, false).await;
    }

    /// Starts a query on the standing targets so the skeletons show while
    /// detection runs; returns what the submit needs to carry on, or `None`
    /// when there is nothing to submit.
    async fn arm_query(
        &self,
    ) -> Option<(
        u64,
        String,
        Vec<String>,
        Option<(String, bool)>,
        Option<String>,
    )> {
        let general = self.backend.general().await;
        let services = {
            let state = lock(&self.state);
            if state.text.trim().is_empty() || state.loading_services {
                return None;
            }
            state
                .translation_services()
                .into_iter()
                .cloned()
                .collect::<Vec<ServiceConfigEntry>>()
        };
        let mut streams = Vec::with_capacity(services.len());
        for service in &services {
            streams.push(self.backend.service_streams(&service.id).await);
        }

        let armed = self.update(|state| {
            let text = state.text.trim().to_owned();
            if text.is_empty() || state.loading_services {
                return None;
            }
            state.request_id += 1;
            let request_id = state.request_id;
            state.submitting = true;
            state.detected_language = None;
            if state.history.begin_source(&text) {
                state.starred = false;
            }
            let standing = state.effective_targets();
            let default_service_id = services
                .iter()
                .find(|service| is_default(service, &general.default_translation_service))
                .map(|service| service.id.clone());
            let results = services
                .iter()
                .zip(streams.iter())
                .map(|(service, streams)| ServiceResult {
                    service: service.clone(),
                    provider: state.provider_for(service),
                    streams: *streams,
                    outputs: standing.iter().map(|target| Output::new(target)).collect(),
                })
                .collect::<Vec<_>>();
            let query = Query {
                text: text.clone(),
                targets: standing.clone(),
                results,
                default_service_id,
                dictionary: None,
            };
            let lead = query.lead_service_id().and_then(|id| {
                query
                    .results
                    .iter()
                    .find(|result| result.service.id == id)
                    .map(|result| (id, result.streams))
            });
            let dictionary = if self.dictionary_enabled {
                state
                    .dictionary_services()
                    .first()
                    .map(|service| service.id.clone())
            } else {
                None
            };
            state.query = Some(query);
            Some((request_id, text, standing, lead, dictionary))
        });
        armed
    }

    async fn compare(self: Arc<Self>, target: String) {
        let (request_id, pending) = {
            let state = lock(&self.state);
            let Some(query) = state.query.as_ref() else {
                return;
            };
            let pending = query
                .results
                .iter()
                .filter(|result| result.output(&target).is_some_and(|output| !output.asked))
                .map(|result| (result.service.id.clone(), result.streams))
                .collect::<Vec<_>>();
            (state.request_id, pending)
        };
        if pending.is_empty() {
            return;
        }
        let text = {
            let state = lock(&self.state);
            match state.query.as_ref() {
                Some(query) => query.text.clone(),
                None => return,
            }
        };
        join_all(pending.into_iter().map(|(service_id, streams)| {
            self.translate_output(
                request_id,
                service_id,
                streams,
                target.clone(),
                text.clone(),
            )
        }))
        .await;
    }

    async fn detect_language(&self, request_id: u64, text: &str) {
        let service_id = {
            let state = lock(&self.state);
            state
                .translation_services()
                .first()
                .map(|service| service.id.clone())
        };
        let Some(service_id) = service_id else {
            return;
        };
        // Detection is supplemental; translation can continue without it.
        if let Ok(Some(detected)) = self.backend.detect_language(&service_id, text).await {
            self.update_if(request_id, |state| state.detected_language = Some(detected));
        }
    }

    /// The languages this submit translates into. A concrete pick is its own
    /// answer; 自动匹配 defers to the configured translation targets, routed
    /// by what the text is already in, and every target the rules hand back
    /// is translated into. With nothing configured or nothing matching, the
    /// last concrete targets stand: a target we cannot resolve is no reason to
    /// fail the whole query.
    async fn resolve_targets(&self, request_id: u64, text: &str) -> Vec<String> {
        let (picked, source, detected, standing) = {
            let state = lock(&self.state);
            (
                state.target_language.clone(),
                state.source_language.clone(),
                state.detected_language.clone(),
                state.resolved_targets.clone(),
            )
        };
        if let Some(picked) = picked {
            return vec![picked];
        }
        let configured = self.backend.general().await.translation_targets;
        if configured.is_empty() {
            return standing;
        }
        // A source the user picked outranks the detector: they have said what
        // the text is, and 自动匹配 routes away from it just the same.
        let language = if source == TranslationTarget::AUTO_SOURCE {
            detected
        } else {
            Some(source)
        };
        let active = TranslationTarget::filter_active(&configured, language.as_deref(), Some(text));
        // Two rules naming the same language are one translation, not two.
        let mut matched: Vec<String> = Vec::new();
        for target in active {
            if !matched.contains(&target.target) {
                matched.push(target.target);
            }
        }
        if !matched.is_empty() && matched != standing {
            let resolved = matched.clone();
            self.update_if(request_id, |state| state.resolved_targets = resolved);
        }
        lock(&self.state).resolved_targets.clone()
    }

    async fn translate_output(
        self: &Arc<Self>,
        request_id: u64,
        service_id: String,
        streams: bool,
        target: String,
        text: String,
    ) {
        let source_language = lock(&self.state).source_language.clone();
        let armed = self.update_if(request_id, |state| {
            state.with_output(&service_id, &target, |output| {
                output.asked = true;
                output.loading = true;
            });
        });
        if !armed {
            return;
        }

        let answer = if streams {
            let session = self.clone();
            let (chunk_service, chunk_target) = (service_id.clone(), target.clone());
            let buffer = Arc::new(Mutex::new(String::new()));
            let on_chunk: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |chunk: String| {
                if chunk.is_empty() {
                    return;
                }
                let text = {
                    let mut buffer = lock(&buffer);
                    buffer.push_str(&chunk);
                    buffer.clone()
                };
                session.update_if(request_id, |state| {
                    state.with_output(&chunk_service, &chunk_target, |output| output.text = text);
                });
            });
            self.backend
                .translate_stream(&service_id, &source_language, &target, &text, on_chunk)
                .await
                .map(|_| None)
        } else {
            self.backend
                .translate(
                    &service_id,
                    TranslateRequest {
                        source_language: (source_language != TranslationTarget::AUTO_SOURCE)
                            .then_some(source_language.clone()),
                        target_language: Some(target.clone()),
                        text: text.clone(),
                    },
                )
                .await
                .map(|response| response.translations.into_iter().next())
        };

        self.update_if(request_id, |state| {
            state.with_output(&service_id, &target, |output| {
                match answer {
                    Ok(Some(translation)) => {
                        output.text = translation.text;
                        output.audio_url = translation.audio_url;
                    }
                    Ok(None) => {}
                    Err(error) => output.error = Some(error),
                }
                // A service that answered with nothing has failed, and says
                // nothing about why; the UI puts its own words to that.
                if !output.has_text() && output.error.is_none() {
                    output.error = Some(String::new());
                }
                output.loading = false;
            });
        });
    }

    async fn look_up(&self, request_id: u64, service_id: String, target: String, text: String) {
        let source_language = lock(&self.state).source_language.clone();
        // Dictionary lookup is optional and must not fail the translation.
        if let Ok(response) = self
            .backend
            .lookup(
                &service_id,
                LookUpRequest {
                    source_language,
                    target_language: target,
                    word: text,
                },
            )
            .await
        {
            self.update_if(request_id, |state| {
                if let Some(query) = state.query.as_mut() {
                    query.dictionary = Some(response);
                }
            });
        }
    }

    async fn save_history(self: Arc<Self>, override_text: Option<String>, edited: bool) {
        let (request_id, input) = {
            let state = lock(&self.state);
            let Some(query) = state.query.as_ref() else {
                return;
            };
            let Some(target) = query.targets.first() else {
                return;
            };
            let Some(index) = query.block_index(target) else {
                return;
            };
            let Some(translation) = override_text.or_else(|| query.preferred_text(target)) else {
                return;
            };
            if translation.trim().is_empty() {
                return;
            }
            let service = &query.results[index].service;
            let service_name = state
                .service_names
                .get(&service.id)
                .cloned()
                .unwrap_or_else(|| service.name.clone());
            (
                state.request_id,
                HistoryEntryInput {
                    id: state.history.entry_id.clone(),
                    source: query.text.clone(),
                    translation,
                    source_language: state
                        .detected_language
                        .clone()
                        .unwrap_or_else(|| state.source_language.clone()),
                    target_language: target.clone(),
                    service_id: service.id.clone(),
                    service_name: service_name.trim().to_owned(),
                    edited,
                },
            )
        };
        if let Ok(entry) = self.backend.upsert_history(input).await {
            self.update_if(request_id, |state| {
                state.history.entry_id = Some(entry.id);
                state.history.favorite = entry.favorite;
                state.history.source = Some(entry.source);
                state.starred = entry.favorite;
            });
        }
    }

    async fn toggle_favorite(self: Arc<Self>, override_text: Option<String>, edited: bool) {
        if lock(&self.state).history.entry_id.is_none() {
            self.clone().save_history(override_text, edited).await;
        }
        let (request_id, entry_id, favorite) = {
            let state = lock(&self.state);
            (
                state.request_id,
                state.history.entry_id.clone(),
                state.history.favorite,
            )
        };
        let Some(entry_id) = entry_id else {
            return;
        };
        if let Ok(Some(entry)) = self
            .backend
            .set_history_favorite(&entry_id, !favorite)
            .await
        {
            self.update_if(request_id, |state| {
                state.history.favorite = entry.favorite;
                state.starred = entry.favorite;
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    fn target(source: &str, target: &str) -> TranslationTarget {
        TranslationTarget {
            source: source.to_owned(),
            target: target.to_owned(),
            enabled: true,
        }
    }

    /// Settles on a later tick, so a 清空 in between is a 清空 in between.
    async fn settle() {
        tokio::task::yield_now().await;
    }

    #[derive(Default)]
    struct FakeBackend {
        configured: Vec<TranslationTarget>,
        detected: Option<String>,
        /// The enabled translation services, by id, in 服务 order.
        services: Vec<&'static str>,
        default_service: String,
        /// Services whose translate call throws.
        failing: HashSet<&'static str>,
        /// Services that answer with no translations at all.
        empty: HashSet<&'static str>,
        /// Services that answer through an LLM, in two chunks.
        streaming: HashSet<&'static str>,
        /// The service and target of every translate request, in order.
        requested: Mutex<Vec<(String, Option<String>)>>,
        saved: Mutex<Vec<HistoryEntryInput>>,
        favorites: Mutex<HashMap<String, bool>>,
    }

    impl FakeBackend {
        fn requested_services(&self) -> Vec<String> {
            lock(&self.requested)
                .iter()
                .map(|(service, _)| service.clone())
                .collect()
        }

        fn requested_targets(&self) -> Vec<Option<String>> {
            lock(&self.requested)
                .iter()
                .map(|(_, target)| target.clone())
                .collect()
        }
    }

    #[async_trait]
    impl SessionBackend for FakeBackend {
        async fn list_providers(&self) -> Result<Vec<ProviderConfigEntry>, String> {
            Ok(Vec::new())
        }

        async fn list_services(&self) -> Result<Vec<ServiceConfigEntry>, String> {
            Ok(self
                .services
                .iter()
                .map(|id| ServiceConfigEntry {
                    id: (*id).to_owned(),
                    provider_id: format!("{id}-provider"),
                    r#type: ServiceType::Translation,
                    name: (*id).to_owned(),
                    fields: HashMap::new(),
                    created_at: None,
                })
                .collect())
        }

        async fn general(&self) -> GeneralSettings {
            GeneralSettings {
                default_translation_service: self.default_service.clone(),
                translation_targets: self.configured.clone(),
                ..GeneralSettings::default()
            }
        }

        async fn service_streams(&self, service_id: &str) -> bool {
            self.streaming.contains(service_id)
        }

        async fn detect_language(
            &self,
            _service_id: &str,
            _text: &str,
        ) -> Result<Option<String>, String> {
            Ok(self.detected.clone())
        }

        async fn translate(
            &self,
            service_id: &str,
            request: TranslateRequest,
        ) -> Result<TranslateResponse, String> {
            lock(&self.requested).push((service_id.to_owned(), request.target_language));
            settle().await;
            if self.failing.contains(service_id) {
                return Err("quota exceeded".to_owned());
            }
            Ok(TranslateResponse {
                translations: if self.empty.contains(service_id) {
                    Vec::new()
                } else {
                    vec![beyondtranslate_core::TextTranslation {
                        text: "ok".to_owned(),
                        detected_source_language: None,
                        audio_url: None,
                    }]
                },
            })
        }

        async fn translate_stream(
            &self,
            service_id: &str,
            _source_language: &str,
            target_language: &str,
            _text: &str,
            on_chunk: Arc<dyn Fn(String) + Send + Sync>,
        ) -> Result<(), String> {
            lock(&self.requested).push((service_id.to_owned(), Some(target_language.to_owned())));
            on_chunk("o".to_owned());
            settle().await;
            on_chunk("k".to_owned());
            Ok(())
        }

        async fn lookup(
            &self,
            _service_id: &str,
            _request: LookUpRequest,
        ) -> Result<LookUpResponse, String> {
            Err("no dictionary".to_owned())
        }

        async fn upsert_history(&self, input: HistoryEntryInput) -> Result<HistoryEntry, String> {
            let id = input.id.clone().unwrap_or_else(|| "entry-1".to_owned());
            lock(&self.saved).push(input.clone());
            let favorite = lock(&self.favorites).get(&id).copied().unwrap_or(false);
            Ok(HistoryEntry {
                id,
                source: input.source,
                translation: input.translation,
                source_language: input.source_language,
                target_language: input.target_language,
                service_id: input.service_id,
                service_name: input.service_name,
                favorite,
                edited: input.edited,
                created_at: 0,
                updated_at: 0,
            })
        }

        async fn set_history_favorite(
            &self,
            entry_id: &str,
            favorite: bool,
        ) -> Result<Option<HistoryEntry>, String> {
            lock(&self.favorites).insert(entry_id.to_owned(), favorite);
            Ok(Some(HistoryEntry {
                id: entry_id.to_owned(),
                source: String::new(),
                translation: String::new(),
                source_language: String::new(),
                target_language: String::new(),
                service_id: String::new(),
                service_name: String::new(),
                favorite,
                edited: false,
                created_at: 0,
                updated_at: 0,
            }))
        }
    }

    struct Fixture {
        backend: Arc<FakeBackend>,
        session: Arc<RuntimeTranslationSession>,
    }

    fn fixture(backend: FakeBackend) -> Fixture {
        let backend = Arc::new(backend);
        let session =
            RuntimeTranslationSession::with_backend(backend.clone(), "en".to_owned(), false);
        Fixture { backend, session }
    }

    fn run<F: std::future::Future<Output = ()>>(future: F) {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime")
            .block_on(future);
    }

    fn query(session: &RuntimeTranslationSession) -> TranslationQueryState {
        session.state().query.expect("a submitted query")
    }

    fn output<'a>(
        query: &'a TranslationQueryState,
        service_id: &str,
        target: &str,
    ) -> &'a TranslationOutputState {
        query
            .results
            .iter()
            .find(|result| result.service.id == service_id)
            .and_then(|result| result.outputs.iter().find(|output| output.target == target))
            .expect("an output for the service and target")
    }

    fn block<'a>(query: &'a TranslationQueryState, target: &str) -> &'a TranslationBlockState {
        query
            .blocks
            .iter()
            .find(|block| block.target == target)
            .expect("a block for the target")
    }

    #[test]
    fn a_picked_target_is_the_one_translated_into() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("ja".to_owned()));
            session.set_text("hello".to_owned());
            session.submit().await;

            assert_eq!(session.state().effective_targets, vec!["ja"]);
            assert_eq!(backend.requested_targets(), vec![Some("ja".to_owned())]);
        });
    }

    #[test]
    fn auto_match_resolves_against_what_detection_found() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("ja", "zh-Hans"), target("en", "zh-Hant")],
                detected: Some("ja".to_owned()),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(None);
            session.set_text("こんにちは".to_owned());
            session.submit().await;

            let state = session.state();
            // The capsule still says 自动匹配…
            assert_eq!(state.target_language, None);
            // …while the query went to the language it resolved to.
            assert_eq!(state.effective_targets, vec!["zh-Hans"]);
            assert_eq!(state.detected_language.as_deref(), Some("ja"));
            assert_eq!(
                backend.requested_targets(),
                vec![Some("zh-Hans".to_owned())]
            );
        });
    }

    #[test]
    fn auto_match_falls_back_to_the_standing_target_when_nothing_matches() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("ja", "zh-Hans")],
                detected: Some("de".to_owned()),
                ..FakeBackend::default()
            });
            session.initialize().await;
            // The roster started with the configured target standing, so that
            // is what "standing" means here — not the constructor's 'en'.
            assert_eq!(session.state().effective_targets, vec!["zh-Hans"]);

            session.set_text("guten tag".to_owned());
            session.submit().await;

            // Detection found a language no target claims. The standing
            // target holds, rather than a null leaking into the request.
            assert_eq!(session.state().effective_targets, vec!["zh-Hans"]);
            assert_eq!(
                backend.requested_targets(),
                vec![Some("zh-Hans".to_owned())]
            );
        });
    }

    #[test]
    fn auto_match_routes_off_the_source_once_the_user_names_one() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("auto", "zh-Hans"), target("auto", "en")],
                detected: Some("en".to_owned()),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_text("hello".to_owned());
            // 自动检测 leaves the routing to the detector…
            session.submit().await;
            assert_eq!(
                backend.requested_targets(),
                vec![Some("zh-Hans".to_owned())]
            );

            // …while a named source is the user telling us what the text is,
            // which is a better answer than the detector's and outranks it.
            session.set_source_language("zh-Hans".to_owned());
            session.submit().await;
            assert_eq!(
                backend.requested_targets(),
                vec![Some("zh-Hans".to_owned()), Some("en".to_owned())]
            );
        });
    }

    #[test]
    fn auto_match_translates_into_every_target_the_rules_hand_back() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                // A specific rule and the 自动检测 fallback both apply; the
                // core returns both, and the pane stacks a block per target.
                configured: vec![target("en", "zh-Hans"), target("auto", "ja")],
                detected: Some("en".to_owned()),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_text("hello".to_owned());
            session.submit().await;

            let state = session.state();
            assert_eq!(state.effective_targets, vec!["zh-Hans", "ja"]);
            let mut targets = backend.requested_targets();
            targets.sort();
            assert_eq!(
                targets,
                vec![Some("ja".to_owned()), Some("zh-Hans".to_owned())]
            );
            let query = state.query.expect("query");
            assert_eq!(query.targets, vec!["zh-Hans", "ja"]);
            assert_eq!(output(&query, "deepl", "zh-Hans").text, "ok");
            assert_eq!(output(&query, "deepl", "ja").text, "ok");
            assert!(!output(&query, "deepl", "ja").loading);
            // History and the single-target readers take the first.
            assert_eq!(query.first_preferred_target.as_deref(), Some("zh-Hans"));
        });
    }

    #[test]
    fn two_rules_naming_one_language_are_one_translation() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("en", "zh-Hans"), target("auto", "zh-Hans")],
                detected: Some("en".to_owned()),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_text("hello".to_owned());
            session.submit().await;

            assert_eq!(session.state().effective_targets, vec!["zh-Hans"]);
            assert_eq!(
                backend.requested_targets(),
                vec![Some("zh-Hans".to_owned())]
            );
        });
    }

    #[test]
    fn a_named_target_collapses_the_set_back_to_one() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("en", "zh-Hans"), target("auto", "ja")],
                detected: Some("en".to_owned()),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_text("hello".to_owned());
            session.submit().await;
            assert_eq!(session.state().effective_targets, vec!["zh-Hans", "ja"]);

            // Picking a language is the user overriding the rules: one target.
            session.set_target_language(Some("ko".to_owned()));
            assert_eq!(session.state().effective_targets, vec!["ko"]);
            lock(&backend.requested).clear();
            session.submit().await;
            assert_eq!(backend.requested_targets(), vec![Some("ko".to_owned())]);
            assert_eq!(query(&session).targets, vec!["ko"]);
        });
    }

    #[test]
    fn the_capsule_starts_on_auto_match_with_the_first_configured_target_standing() {
        run(async {
            let Fixture { session, .. } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("ja", "zh-Hans")],
                ..FakeBackend::default()
            });
            session.initialize().await;

            // Both windows open on 自动检测 ⇄ 自动匹配: the configured targets
            // are rules to route by, not a pick to start from.
            let state = session.state();
            assert_eq!(state.source_language, "auto");
            assert_eq!(state.target_language, None);
            assert_eq!(state.effective_targets, vec!["zh-Hans"]);
            assert!(!state.loading_services);
        });
    }

    #[test]
    fn a_configured_target_picked_as_a_pair_sets_both_languages() {
        run(async {
            let Fixture { session, .. } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("ja", "zh-Hans"), target("en", "ko")],
                ..FakeBackend::default()
            });
            session.initialize().await;

            session.select_configured_target(1).await;
            let state = session.state();
            assert_eq!(state.configured_target_index, 1);
            assert_eq!(state.source_language, "en");
            assert_eq!(state.target_language.as_deref(), Some("ko"));

            // A language picked on its own is a pair of the user's making.
            session.set_target_language(Some("ja".to_owned()));
            let state = session.state();
            assert_eq!(state.configured_target_index, -1);
            assert_eq!(state.source_language, "en");

            // The first menu item puts the capsule back on 自动检测 ⇄ 自动匹配.
            session.select_configured_target(-1).await;
            let state = session.state();
            assert_eq!(state.source_language, "auto");
            assert_eq!(state.target_language, None);
        });
    }

    #[test]
    fn a_submit_asks_the_default_service_only_and_compare_asks_the_rest_once() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl", "claude", "google"],
                default_service: "claude".to_owned(),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("en".to_owned()));
            session.set_text("hello".to_owned());
            session.submit().await;

            let query = query(&session);
            // Every enabled service has a seat, asked or not…
            let seats: Vec<&str> = query
                .results
                .iter()
                .map(|result| result.service.id.as_str())
                .collect();
            assert_eq!(seats, vec!["deepl", "claude", "google"]);
            // …but only the default was asked, and it owns the block.
            assert_eq!(backend.requested_services(), vec!["claude"]);
            assert_eq!(query.default_service_id.as_deref(), Some("claude"));
            assert_eq!(block(&query, "en").service_id.as_deref(), Some("claude"));
            assert_eq!(block(&query, "en").preferred_text.as_deref(), Some("ok"));
            assert!(!output(&query, "deepl", "en").asked);
            assert!(!output(&query, "google", "en").asked);
            assert!(!session.state().submitting);

            session.compare("en".to_owned()).await;
            assert_eq!(
                backend.requested_services(),
                vec!["claude", "deepl", "google"]
            );
            let query = self::query(&session);
            assert_eq!(output(&query, "deepl", "en").text, "ok");
            assert_eq!(output(&query, "google", "en").text, "ok");

            // Each service is asked once per query.
            session.compare("en".to_owned()).await;
            assert_eq!(
                backend.requested_services(),
                vec!["claude", "deepl", "google"]
            );
        });
    }

    #[test]
    fn the_default_service_owns_the_block_even_when_it_fails() {
        run(async {
            let Fixture { session, .. } = fixture(FakeBackend {
                services: vec!["deepl", "claude"],
                default_service: "claude".to_owned(),
                failing: HashSet::from(["claude"]),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("en".to_owned()));
            session.set_text("hello".to_owned());
            session.submit().await;

            let query = query(&session);
            // A default that could not answer is a failed translation: the
            // block says so rather than quietly promoting whichever service
            // answered.
            assert_eq!(block(&query, "en").preferred_text, None);
            assert!(output(&query, "claude", "en").failed);
            assert_eq!(
                output(&query, "claude", "en").error.as_deref(),
                Some("quota exceeded")
            );
            assert!(query.all_failed);
            assert_eq!(query.failed_service_ids, vec!["claude"]);

            session.compare("en".to_owned()).await;
            let query = self::query(&session);
            assert_eq!(block(&query, "en").service_id.as_deref(), Some("claude"));
            assert_eq!(block(&query, "en").preferred_text, None);
            // Another service answering is not this service answering — but
            // the query as a whole is no longer empty-handed.
            assert!(!query.all_failed);
            assert_eq!(output(&query, "deepl", "en").text, "ok");
        });
    }

    #[test]
    fn with_no_default_the_first_service_that_answered_stands_in() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl", "claude"],
                failing: HashSet::from(["deepl"]),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("en".to_owned()));
            session.set_text("hello".to_owned());
            session.submit().await;

            let query = query(&session);
            assert_eq!(query.default_service_id, None);
            // The first enabled service leads the submit…
            assert_eq!(backend.requested_services(), vec!["deepl"]);
            assert_eq!(block(&query, "en").service_id.as_deref(), Some("deepl"));
            assert!(query.all_failed);

            // …and once 对比 finds one that answered, that one takes the slot.
            session.compare("en".to_owned()).await;
            let query = self::query(&session);
            assert_eq!(block(&query, "en").service_id.as_deref(), Some("claude"));
            assert_eq!(block(&query, "en").preferred_text.as_deref(), Some("ok"));
        });
    }

    #[test]
    fn a_service_that_answered_with_nothing_has_failed() {
        run(async {
            let Fixture { session, .. } = fixture(FakeBackend {
                services: vec!["deepl"],
                empty: HashSet::from(["deepl"]),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("en".to_owned()));
            session.set_text("hello".to_owned());
            session.submit().await;

            let query = query(&session);
            let output = output(&query, "deepl", "en");
            assert!(output.failed);
            assert!(!output.translating);
            // It gave no reason; the UI puts its own words to that.
            assert_eq!(output.error.as_deref(), Some(""));
        });
    }

    #[test]
    fn a_missing_language_pair_is_not_a_failed_query() {
        run(async {
            let Fixture { session, .. } = fixture(FakeBackend {
                services: vec!["system"],
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("en".to_owned()));
            session.set_text("hello".to_owned());
            session.submit().await;
            // The system translator's own wording for a pair it cannot serve.
            session.inner.update(|state| {
                state.with_output("system", "en", |output| {
                    output.text.clear();
                    output.error =
                        Some("network error: language pair not installed: zh -> en".to_owned());
                });
            });

            let query = query(&session);
            assert!(output(&query, "system", "en").missing_language);
            assert!(query.all_targets_missing_language);
            // The target's own block reports it, with the fix — not 服务全部失效.
            assert!(!query.all_failed);
        });
    }

    #[test]
    fn a_streaming_service_shows_its_text_as_it_arrives() {
        run(async {
            let Fixture { session, .. } = fixture(FakeBackend {
                services: vec!["claude"],
                streaming: HashSet::from(["claude"]),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("en".to_owned()));
            session.set_text("hello".to_owned());

            let running = session.clone();
            let submit = tokio::spawn(async move { running.submit().await });
            // Let the submit run up to the stream's first pause.
            for _ in 0..8 {
                settle().await;
                let first_chunk = session
                    .state()
                    .query
                    .is_some_and(|query| output(&query, "claude", "en").text == "o");
                if first_chunk {
                    break;
                }
            }
            let query = query(&session);
            let first = output(&query, "claude", "en");
            assert!(first.loading);
            assert_eq!(first.text, "o");
            // Text on screen is not a spinner, even while more is coming.
            assert!(!first.translating);

            submit.await.expect("submit finishes");
            let query = self::query(&session);
            assert_eq!(output(&query, "claude", "en").text, "ok");
            assert!(!output(&query, "claude", "en").loading);
        });
    }

    #[test]
    fn clear_drops_the_query_and_lands_in_flight_answers_nowhere() {
        run(async {
            let Fixture { session, .. } = fixture(FakeBackend {
                services: vec!["deepl"],
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_target_language(Some("en".to_owned()));
            session.set_text("hello".to_owned());

            let running = session.clone();
            let submit = tokio::spawn(async move { running.submit().await });
            settle().await;
            assert!(session.state().query.is_some());
            session.clear();
            submit.await.expect("submit finishes");

            let state = session.state();
            assert!(state.query.is_none());
            assert!(state.text.is_empty());
            assert!(!state.submitting);
        });
    }

    #[test]
    fn history_keeps_the_first_targets_translation_and_follows_the_star() {
        run(async {
            let Fixture { backend, session } = fixture(FakeBackend {
                services: vec!["deepl"],
                configured: vec![target("en", "zh-Hans"), target("auto", "ja")],
                detected: Some("en".to_owned()),
                ..FakeBackend::default()
            });
            session.initialize().await;
            session.set_service_names(HashMap::from([(
                "deepl".to_owned(),
                "DeepL (named)".to_owned(),
            )]));
            session.set_text("hello".to_owned());
            session.submit().await;

            let saved = lock(&backend.saved).clone();
            assert_eq!(saved.len(), 1);
            assert_eq!(saved[0].source, "hello");
            assert_eq!(saved[0].translation, "ok");
            assert_eq!(saved[0].target_language, "zh-Hans");
            assert_eq!(saved[0].source_language, "en");
            assert_eq!(saved[0].service_name, "DeepL (named)");
            assert!(!saved[0].edited);
            assert!(!session.state().starred);

            session.toggle_favorite(None, false).await;
            assert!(session.state().starred);
            session.toggle_favorite(None, false).await;
            assert!(!session.state().starred);

            // An edit re-saves the same entry with the user's words.
            session.save_history(Some("my own".to_owned()), true).await;
            let saved = lock(&backend.saved).clone();
            assert_eq!(saved.len(), 2);
            assert_eq!(saved[1].id.as_deref(), Some("entry-1"));
            assert_eq!(saved[1].translation, "my own");
            assert!(saved[1].edited);
        });
    }
}

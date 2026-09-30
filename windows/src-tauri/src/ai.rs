//! Provider routing lives here; the existing Anthropic client is an adapter.
use serde::{Deserialize, Serialize};
use crate::{claude, openai, secrets, settings::Settings};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Provider { #[default] Anthropic, Openai, Auto }

pub fn resolve(selected: Provider, anthropic: bool, openai: bool) -> Provider {
    match selected {
        Provider::Auto if anthropic => Provider::Anthropic,
        Provider::Auto if openai => Provider::Openai,
        Provider::Auto => Provider::Anthropic,
        explicit => explicit,
    }
}

#[derive(Default)]
pub struct Router {
    active: Option<Provider>,
    claude: claude::Chat,
    openai: openai::Chat,
}

impl Router {
    pub fn reset(&mut self) {
        self.claude.reset(); self.openai.reset(); self.active = None;
    }
    pub async fn download(&self, container: &str, file: &str) -> Result<String,String> {
        if self.active != Some(Provider::Openai) { return Err("Select the OpenAI conversation first.".into()); }
        self.openai.download(container,file).await
    }
    pub async fn send(&mut self, app: &tauri::AppHandle, settings: &Settings, query: String, context: Option<claude::ChatContext>) -> Result<claude::ChatReply, String> {
        let id = resolve(settings.ai_provider, secrets::present("anthropic-api-key"), secrets::present("openai-api-key"));
        if self.active != Some(id) { self.reset(); self.active = Some(id); }
        match id {
            Provider::Anthropic => claude::send(&self.claude, &settings.model, query, context).await,
            Provider::Openai => self.openai.send(app, settings, query, context).await,
            Provider::Auto => unreachable!(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn provider_selection() {
        assert_eq!(resolve(Provider::Auto, true, true), Provider::Anthropic);
        assert_eq!(resolve(Provider::Auto, false, true), Provider::Openai);
        assert_eq!(resolve(Provider::Anthropic, false, true), Provider::Anthropic);
        assert_eq!(resolve(Provider::Openai, true, false), Provider::Openai);
    }
}

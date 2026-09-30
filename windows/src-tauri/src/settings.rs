// Preferences, stored as plain JSON in %APPDATA%\Coucou\settings.json.
// No secret ever lands here — API keys live in the Windows Credential Manager.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub sound_enabled: bool,
    pub sound_volume: f64,
    pub auto_close_interval: f64,
    pub absence_interval: f64,
    pub active_integrations: Vec<String>,
    /// "primary" = the main display, "cursor" = whichever display the mouse is on.
    pub screen: String,
    pub autostart: bool,
    pub hooks_installed: bool,
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    #[serde(default)]
    pub ai_provider: crate::ai::Provider,
    #[serde(default)]
    pub openai_model: String,
    #[serde(default)]
    pub openai_reasoning: String,
    #[serde(default = "default_tokens")]
    pub openai_max_tokens: u32,
    #[serde(default)]
    pub openai_web_search: bool,
    #[serde(default)]
    pub openai_code_interpreter: bool,
    #[serde(default)]
    pub openai_integrations: bool,
    #[serde(default)] pub openai_writes: bool,
    #[serde(default)] pub openai_images: bool,
    #[serde(default)] pub openai_computer: bool,
    #[serde(default)] pub openai_image_model: String,
    #[serde(default = "image_size")] pub openai_image_size: String,
    #[serde(default)] pub openai_image_transparent: bool,
    #[serde(default = "computer_target")] pub computer_target: String,
    #[serde(default)] pub mcp_servers: Vec<crate::remote_mcp::Server>,
    #[serde(default)] pub n8n_webhook: String,

}

fn default_tokens() -> u32 { 4096 }
fn image_size()->String{"auto".into()}
fn computer_target()->String{"msedge".into()}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            sound_enabled: true,
            sound_volume: 0.12,
            auto_close_interval: 15.0,
            absence_interval: 180.0,
            active_integrations: vec![
                "integration_resend".into(),
                "integration_n8n".into(),
                "integration_vercel".into(),
                "integration_github".into(),
            ],
            screen: "primary".into(),
            autostart: false,
            hooks_installed: false,
            model: default_model(),
            ai_provider: crate::ai::Provider::Anthropic,
            openai_model: String::new(), openai_reasoning: String::new(),
            openai_max_tokens: 4096, openai_web_search: false, openai_code_interpreter: false, openai_integrations: false,
            openai_writes:false,openai_images:false,openai_computer:false,openai_image_model:String::new(),openai_image_size:image_size(),openai_image_transparent:false,computer_target:computer_target(),mcp_servers:vec![],n8n_webhook:String::new(),
        }
    }
}

/// %APPDATA%\Coucou
pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

/// %LOCALAPPDATA%\Coucou — where coucou-hook.exe and the log live.
pub fn local_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

pub fn hook_exe_path() -> PathBuf {
    local_dir().join("bin").join("coucou-hook.exe")
}

fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn load() -> Settings {
    match std::fs::read(settings_path()) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

pub fn save(settings: &Settings) -> std::io::Result<()> {
    let dir = config_dir();
    std::fs::create_dir_all(&dir)?;
    let json = serde_json::to_vec_pretty(settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(settings_path(), json)
}

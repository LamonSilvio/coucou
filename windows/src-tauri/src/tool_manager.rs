//! Allowlisted, read-only tool registry. No model-controlled URLs or local execution.
use serde_json::{json, Value};
use crate::{settings::Settings, secrets};
pub fn integration_tool() -> Value {
    json!({"type":"function","name":"list_integrations","description":"List enabled Coucou integrations and whether credentials are configured. Does not retrieve credentials or perform external actions.",
        "strict":true,"parameters":{"type":"object","properties":{},"required":[],"additionalProperties":false}})
}
pub fn execute(name: &str, arguments: &str, settings: &Settings) -> String {
    let valid = serde_json::from_str::<Value>(arguments).ok().is_some_and(|v| v.as_object().is_some_and(|a| a.is_empty()));
    if name != "list_integrations" || !valid { return json!({"error":"Tool unavailable or explicit approval required."}).to_string(); }
    let mapping = [("resend","resend-api-key"),("n8n","n8n-api-key"),("vercel","vercel-token"),("github","github-token"),("stripe","stripe-api-key"),("notion","notion-api-key"),("calcom","calcom-api-key")];
    let integrations: Vec<_> = mapping.iter().filter(|(id,_)| settings.active_integrations.contains(&format!("integration_{id}")))
        .map(|(id,key)|json!({"name":id,"configured":secrets::present(key)})).collect();
    json!({"integrations":integrations}).to_string()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn no_arbitrary_tool_or_arguments() {
        let s = Settings::default();
        assert!(execute("shell","{}",&s).contains("error"));
        assert!(execute("list_integrations","{\"url\":\"https://attacker.invalid\"}",&s).contains("error"));
        assert!(execute("list_integrations","not-json",&s).contains("error"));
    }
}

use serde::{Serialize,Deserialize};
use serde_json::{json,Value};
use tauri::{AppHandle,Manager};
use crate::{actions::{Action,Approvals,Risk,redact},secrets};
#[derive(Clone,Debug,Serialize,Deserialize,PartialEq,Eq)]
#[serde(deny_unknown_fields)]
pub struct Server {pub name:String,pub endpoint:String,pub enabled:bool,pub tools:Vec<String>}
impl Server {
    pub fn valid(&self)->bool{
        let Ok(u)=reqwest::Url::parse(&self.endpoint)else{return false};
        crate::openai::safe_id(&self.name)&&self.name.len()<=32&&self.tools.iter().all(|t|crate::openai::safe_id(t))&&u.scheme()=="https"&&u.host_str().is_some()&&u.username().is_empty()&&u.password().is_none()&&u.query().is_none()&&u.fragment().is_none()
    }
    pub fn tool(&self)->Result<Value,String>{
        if !self.valid(){return Err("Invalid MCP server configuration.".into())}
        let mut v=json!({"type":"mcp","server_label":self.name,"server_url":self.endpoint,"require_approval":"always"});
        if !self.tools.is_empty(){v["allowed_tools"]=json!(self.tools);}
        if let Some(token)=secrets::get(&format!("mcp-token-{}",self.name)){v["authorization"]=json!(token)}
        Ok(v)
    }
}
pub fn validate(servers:&[Server])->Result<(),String>{
    let names:std::collections::HashSet<_>=servers.iter().map(|s|&s.name).collect();
    if servers.len()>8||names.len()!=servers.len()||servers.iter().any(|s|!s.valid()){Err("Invalid MCP configuration; names must be unique.".into())}else{Ok(())}
}
pub fn discovery(output:&[Value])->String{
    output.iter().filter(|i|i["type"]=="mcp_list_tools").map(|i|format!("{}: {}{}",i["server_label"].as_str().unwrap_or("MCP"),i["tools"].as_array().into_iter().flatten().filter_map(|t|t["name"].as_str()).collect::<Vec<_>>().join(", "),if i.get("error").is_some(){" — connection failed"}else{""})).collect::<Vec<_>>().join("\n")
}
pub async fn approval(app:&AppHandle,item:&Value,servers:&[Server])->Value{
    let id=item["id"].as_str().unwrap_or("");let server=item["server_label"].as_str().unwrap_or("");let name=item["name"].as_str().unwrap_or("");
    let args:Value=serde_json::from_str(item["arguments"].as_str().unwrap_or("{}")).unwrap_or(Value::Null);
    let mut allow=false;
    if !id.is_empty()&&args.is_object()&&redact(&args)==args&&servers.iter().any(|s|s.enabled&&s.name==server&&s.tools.iter().any(|t|t==name)){
        allow=app.state::<Approvals>().authorize(app,Action{id:id.into(),provider:"openai".into(),integration:"mcp".into(),operation:name.into(),parameters:json!({"server":server,"tool":name,"arguments":args}),risk:Risk::Critical}).await;
        allow=allow&&app.state::<Approvals>().claim_execution(id);
    }
    json!({"type":"mcp_approval_response","approval_request_id":id,"approve":allow})
}

#[cfg(test)]mod tests{
 use super::*;
 #[test]fn mocked_discovery(){assert_eq!(discovery(&[json!({"type":"mcp_list_tools","server_label":"example","tools":[{"name":"search"}]})]),"example: search");}
 #[test]fn server_configuration_and_auth_boundary(){let s=Server{name:"example".into(),endpoint:"https://example.com/mcp".into(),enabled:true,tools:vec!["search".into()]};assert!(s.valid());let v=s.tool().unwrap();assert_eq!(v["require_approval"],"always");assert_eq!(v["allowed_tools"],json!(["search"]));assert!(validate(&[s.clone(),s]).is_err());}
 #[test]fn secret_endpoint_denied(){for url in ["http://example.com/mcp","https://user:password@example.com/mcp","https://example.com/mcp?token=secret"]{assert!(!Server{name:"example".into(),endpoint:url.into(),enabled:true,tools:vec!["search".into()]}.valid());}}
 #[test]fn plaintext_tokens_rejected_and_empty_allowlist_discovery(){assert!(serde_json::from_value::<Server>(json!({"name":"example","endpoint":"https://example.com/mcp","enabled":true,"tools":[],"authorization":"private"})).is_err());let s=Server{name:"discovery".into(),endpoint:"https://example.com/mcp".into(),enabled:true,tools:vec![]};assert!(s.valid());assert!(s.tool().unwrap().get("allowed_tools").is_none());}
}

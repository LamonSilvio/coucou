use serde_json::{json,Value};
use tauri::{AppHandle,Manager};
use crate::{actions::{Action,Approvals,risk,audit,redact},settings::Settings,secrets};
pub const CATALOG:&str=include_str!("../../../NotchBuddy/Resources/ExternalActions.json");
pub fn tool()->Value{json!({"type":"function","name":"external_action","description":"Propose a Coucou integration write; approval required. github create_issue/comment_issue, notion create_page/append_content, n8n run_workflow, vercel preview_deploy/production_deploy, resend send_email, stripe refund, calcom create_booking. parameters is a JSON object encoded as a string. No credentials or arbitrary URLs.","strict":true,"parameters":{"type":"object","properties":{"integration":{"type":"string"},"operation":{"type":"string"},"parameters":{"type":"string"}},"required":["integration","operation","parameters"],"additionalProperties":false}})}
pub struct Plan{pub url:String,pub method:String,pub body:Value,pub key:String,pub integration:String}
pub fn plan(integration:&str,operation:&str,params:&Value,webhook:&str)->Result<Plan,String>{
    let catalog:Value=serde_json::from_str(CATALOG).map_err(|_|"Invalid action catalog.")?;
    let d=&catalog[format!("{integration}.{operation}")];
    let fields=d["fields"].as_array().ok_or("Unsupported external action.")?;
    let object=params.as_object().ok_or("Parameters must be an object.")?;
    if params.to_string().len()>12000 || redact(params)!=*params || object.keys().any(|k|!fields.iter().any(|v|v==k)) || d["required"].as_array().unwrap().iter().any(|k|params.get(k.as_str().unwrap()).is_none()) {return Err("Unexpected, sensitive or missing action parameters.".into())}
    let mut path=d["path"].as_str().unwrap().to_owned();
    for key in ["owner","repo","number","block_id"]{
        if path.contains(&format!("{{{key}}}")){
            let raw=if let Some(s)=params[key].as_str(){s.to_owned()}else{params[key].to_string()};
            if raw.is_empty()||raw=="."||raw==".."||!raw.bytes().all(|c|c.is_ascii_alphanumeric()||b"._-".contains(&c)){return Err("Invalid resource identifier.".into())}
            path=path.replace(&format!("{{{key}}}"),&raw);
        }
    }
    let url=if integration=="n8n"{webhook.to_owned()}else{format!("{}{path}",d["origin"].as_str().unwrap())};
    let parsed=reqwest::Url::parse(&url).map_err(|_|"Configure a valid HTTPS endpoint.")?;
    if parsed.scheme()!="https"||parsed.host_str().is_none()||!parsed.username().is_empty()||parsed.password().is_some()||parsed.query().is_some()||parsed.fragment().is_some(){return Err("Endpoint must be HTTPS without embedded secrets.".into())}
    let mut body:serde_json::Map<String,Value>=object.iter().filter(|(k,_)|d["bodyFields"].as_array().unwrap().iter().any(|v|v==*k)).map(|(k,v)|(k.clone(),v.clone())).collect();
    if integration=="vercel"{body.insert("target".into(),json!(if operation=="production_deploy"{"production"}else{"preview"}));}
    let body=if integration=="n8n"{if !params["input"].is_object(){return Err("Workflow input must be an object.".into())}params["input"].clone()}else{json!(body)};
    if integration=="stripe" && (!params["amount"].as_u64().is_some_and(|a|a>0)||!params["payment_intent"].as_str().is_some_and(crate::openai::safe_id)){return Err("Invalid refund parameters.".into())}
    Ok(Plan{url,method:d["method"].as_str().unwrap().into(),body,key:d["key"].as_str().unwrap().into(),integration:integration.into()})
}
pub async fn execute(app:&AppHandle,args:&str,id:&str,settings:&Settings)->String{
    let result=async{
        let a:Value=serde_json::from_str(args).map_err(|_|"Invalid action.")?;
        if a.as_object().is_none_or(|o|o.len()!=3){return Err("Unexpected fields.")}
        let integration=a["integration"].as_str().ok_or("Missing integration.")?;let operation=a["operation"].as_str().ok_or("Missing operation.")?;
        if !settings.active_integrations.contains(&format!("integration_{integration}")){return Err("Enable integration in Settings.")}
        let params:Value=serde_json::from_str(a["parameters"].as_str().ok_or("Missing parameters.")?).map_err(|_|"Invalid parameters.")?;
        let p=plan(integration,operation,&params,&settings.n8n_webhook).map_err(|_|"Unsupported action parameters.")?;
        let mut preview=params;preview["destination"]=json!(p.url);preview["method"]=json!(p.method);
        let action=Action{id:id.into(),provider:"openai".into(),integration:integration.into(),operation:operation.into(),parameters:preview,risk:risk(integration,operation)};
        let approvals=app.state::<Approvals>();
        if !approvals.authorize(app,action.clone()).await || !approvals.claim_execution(id){return Err("Action denied, expired or already executed.")}
        let result=send(p,id).await;audit(&action,if result.is_ok(){"success"}else{"failure"});result
    }.await;
    match result{Ok(v)=>v.to_string(),Err(_)=>json!({"error":"Action rejected or failed. Check configuration and verify outcome before retrying a write."}).to_string()}
}
async fn send(p:Plan,id:&str)->Result<Value,&'static str>{
    let key=secrets::get(&p.key).ok_or("Missing integration credential.")?;
    let client=reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()).timeout(std::time::Duration::from_secs(45)).build().map_err(|_|"Connection failed.")?;
    let method=reqwest::Method::from_bytes(p.method.as_bytes()).map_err(|_|"Invalid method.")?;
    let mut request=client.request(method,&p.url).bearer_auth(key).header("User-Agent","Coucou");
    if p.integration=="notion"{request=request.header("Notion-Version","2022-06-28");}
    if p.integration=="calcom"{request=request.header("cal-api-version","2026-02-25");}
    if ["stripe","resend"].contains(&p.integration.as_str()){request=request.header("Idempotency-Key",id);}
    if p.integration=="stripe"{request=request.header("Content-Type","application/x-www-form-urlencoded").body(format!("payment_intent={}&amount={}",p.body["payment_intent"].as_str().unwrap(),p.body["amount"]));}else{request=request.json(&p.body);}
    let mut response=request.send().await.map_err(|_|"Integration network error.")?;
    let status=response.status();if !status.is_success(){return Err("Integration write failed.")}
    let mut bytes=vec![];while let Some(chunk)=response.chunk().await.map_err(|_|"Read failed.")?{if bytes.len()+chunk.len()>2_000_000{return Err("Response too large.")}bytes.extend_from_slice(&chunk);}
    let v:Value=serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    Ok(json!({"success":true,"id":v.get("id").or_else(||v["data"].get("uid")),"status":status.as_u16()}))
}

#[cfg(test)]mod tests{
 use super::*;
 #[test]fn github_write_mock(){let p=plan("github","create_issue",&json!({"owner":"owner","repo":"repo","title":"Test","body":"Body"}),"").unwrap();assert_eq!(p.method,"POST");assert_eq!(p.url,"https://api.github.com/repos/owner/repo/issues");assert_eq!(p.body,json!({"title":"Test","body":"Body"}));}
 #[test]fn notion_write_mock(){let p=plan("notion","append_content",&json!({"block_id":"block_123","children":[]}),"").unwrap();assert_eq!(p.method,"PATCH");assert_eq!(p.body,json!({"children":[]}));}
 #[test]fn n8n_workflow_mock(){let p=plan("n8n","run_workflow",&json!({"workflow":"configured","input":{"x":1},"effect":"Test"}),"https://workflow.example/webhook/fixed").unwrap();assert_eq!(p.body,json!({"x":1}));assert_eq!(p.key,"n8n-webhook-token");}
 #[test]fn vercel_preview_vs_production(){for (operation,target,r) in [("preview_deploy","preview",crate::actions::Risk::Confirm),("production_deploy","production",crate::actions::Risk::Critical)]{let p=plan("vercel",operation,&json!({"name":"project","gitSource":{"type":"github","repoId":1,"ref":"main"}}),"").unwrap();assert_eq!(p.body["target"],target);assert_eq!(risk("vercel",operation),r);}}
 #[test]fn resend_real_send_requires_critical(){let p=plan("resend","send_email",&json!({"from":"from@example.com","to":["to@example.com"],"subject":"Test","text":"Body"}),"").unwrap();assert_eq!(p.url,"https://api.resend.com/emails");assert_eq!(risk("resend","send_email"),crate::actions::Risk::Critical);}
 #[test]fn stripe_refund_critical(){assert_eq!(risk("stripe","refund"),crate::actions::Risk::Critical);assert!(plan("stripe","refund",&json!({"payment_intent":"pi_fake","amount":100}),"").is_ok());assert!(plan("stripe","refund",&json!({"payment_intent":"pi_fake","amount":-1}),"").is_err());}
 #[test]fn calcom_booking_mock(){assert_eq!(plan("calcom","create_booking",&json!({"start":"2027-01-01T10:00:00Z","eventTypeId":1,"attendee":{"name":"Test","email":"test@example.com","timeZone":"UTC"}}),"").unwrap().url,"https://api.cal.com/v2/bookings");}
 #[test]fn arbitrary_urls_and_credentials_rejected(){assert!(plan("github","create_issue",&json!({"owner":"..","repo":"repo","title":"Test","body":"Body"}),"").is_err());assert!(plan("github","create_issue",&json!({"owner":"owner","repo":"repo","title":"Test","body":"Body","url":"https://evil.example"}),"").is_err());}
}

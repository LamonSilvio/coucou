use std::{collections::{HashMap,HashSet,VecDeque},sync::Mutex};
use serde::{Serialize,Deserialize};
use serde_json::{json,Value};
use tauri::{AppHandle,Emitter};

#[derive(Clone,Debug,Serialize,Deserialize,PartialEq,Eq)]
#[serde(rename_all="lowercase")]
pub enum Risk { Safe, Confirm, Critical }
pub fn risk(integration:&str,operation:&str)->Risk {
    if integration=="computer" {return if operation=="wait" {Risk::Safe}else{Risk::Critical}}
    if integration=="mcp" || integration=="codex" || integration=="stripe" || integration=="n8n" || ["send_email","production_deploy","cancel_booking"].contains(&operation){return Risk::Critical}
    if operation=="list_integrations" {Risk::Safe}else{Risk::Confirm}
}
#[derive(Clone,Serialize)]
pub struct Action {pub id:String,pub provider:String,pub integration:String,pub operation:String,pub parameters:Value,pub risk:Risk}
pub fn redact(v:&Value)->Value {
    match v {
        Value::Object(map)=>Value::Object(map.iter().map(|(k,v)| (k.clone(),if k.eq_ignore_ascii_case("key") || ["password","token","secret","authorization","cookie","api_key","api-key","apikey"].iter().any(|s|k.to_lowercase().contains(s)){json!("[REDACTED]")}else{redact(v)})).collect()),
        Value::Array(a)=>json!(a.iter().map(redact).collect::<Vec<_>>()),
        Value::String(s) if ["sk-","ghp_","gho_","ghu_","ghs_","ghr_","bearer "].iter().any(|p|s.to_lowercase().contains(p))=>json!("[REDACTED]"),
        _=>v.clone()
    }
}
#[derive(Default)]
struct State { queue:VecDeque<Action>, pending:HashMap<String,tokio::sync::oneshot::Sender<bool>>,decided:HashSet<String>,approved:HashSet<String>,executed:HashSet<String> }
#[derive(Clone)]
pub enum ApprovalEvent { Requested(Action), Resolved(String) }
fn emit(app:&AppHandle,event:ApprovalEvent){match event{ApprovalEvent::Requested(action)=>{let _=app.emit("action-approval",action);},ApprovalEvent::Resolved(id)=>{let _=app.emit("action-resolved",id);}}}
#[derive(Default)]
pub struct Approvals { state:Mutex<State>, pub cancelled:tokio::sync::Notify, generation:std::sync::atomic::AtomicU64 }
impl Approvals {
    pub async fn authorize(&self,app:&AppHandle,action:Action)->bool {
        self.authorize_with(action,std::time::Duration::from_secs(110),|e|emit(app,e)).await
    }
    pub async fn authorize_with(&self,mut action:Action,timeout:std::time::Duration,events:impl Fn(ApprovalEvent))->bool {
        action.risk=risk(&action.integration,&action.operation); action.parameters=redact(&action.parameters);
        let (tx,rx)=tokio::sync::oneshot::channel();
        let first={
            let mut s=self.state.lock().unwrap();
            if s.decided.contains(&action.id)||s.pending.contains_key(&action.id){return false}
            if action.risk==Risk::Safe {s.decided.insert(action.id.clone());s.approved.insert(action.id.clone());audit(&action,"approved");return true}
            if action.parameters.to_string().len()>24000{return false}
            s.pending.insert(action.id.clone(),tx); s.queue.push_back(action.clone());
            s.queue.len()==1
        };
        if first{events(ApprovalEvent::Requested(action.clone()));}
        match tokio::time::timeout(timeout,rx).await {
            Ok(Ok(allow))=>allow,
            _=>{self.decide_with(&action.id,false,&events);false}
        }
    }
    pub fn decide(&self,app:&AppHandle,id:&str,allow:bool){
        self.decide_with(id,allow,|e|emit(app,e))
    }
    pub fn decide_with(&self,id:&str,allow:bool,events:impl Fn(ApprovalEvent)){
        let mut s=self.state.lock().unwrap();
        if allow && !s.queue.front().is_some_and(|a|a.id==id){return}
        let Some(tx)=s.pending.remove(id) else{return};
        s.decided.insert(id.into());
        if allow{s.approved.insert(id.into());}
        if let Some(index)=s.queue.iter().position(|a|a.id==id){let a=s.queue.remove(index).unwrap();audit(&a,if allow{"approved"}else{"denied"});}
        let next=s.queue.front().cloned();drop(s);
        let _=tx.send(allow);events(ApprovalEvent::Resolved(id.into()));
        if let Some(next)=next{events(ApprovalEvent::Requested(next));}
    }
    pub fn cancel(&self,app:&AppHandle){self.cancel_with(|e|emit(app,e))}
    pub fn cancel_with(&self,events:impl Fn(ApprovalEvent)){
        self.generation.fetch_add(1,std::sync::atomic::Ordering::SeqCst);self.cancelled.notify_waiters();
        let ids:Vec<_>={let mut s=self.state.lock().unwrap();let executed=s.executed.clone();s.approved.retain(|id|executed.contains(id));s.pending.keys().cloned().collect()};
        for id in ids{self.decide_with(&id,false,&events)}
    }
    pub fn generation(&self)->u64{self.generation.load(std::sync::atomic::Ordering::SeqCst)}
    pub fn claim_execution(&self,id:&str)->bool{let mut s=self.state.lock().unwrap();s.approved.contains(id)&&s.executed.insert(id.into())}
}
pub fn audit(action:&Action,outcome:&str){
    use std::io::Write;
    let dir=crate::settings::local_dir();let _=std::fs::create_dir_all(&dir);
    let timestamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs();
    let row=json!({"timestamp":timestamp,"provider":action.provider,"integration":action.integration,"action":action.operation,"risk":action.risk,"outcome":outcome});
    if let Ok(mut file)=std::fs::OpenOptions::new().create(true).append(true).open(dir.join("actions-audit.jsonl")){let _=writeln!(file,"{row}");}
}

#[cfg(test)]
mod tests {
    use super::*;
    fn action(id:&str,integration:&str,operation:&str)->Action{Action{id:id.into(),provider:"openai".into(),integration:integration.into(),operation:operation.into(),parameters:json!({"title":"Test"}),risk:risk(integration,operation)}}
    #[test] fn local_risk_cannot_be_downgraded(){assert_eq!(risk("stripe","read_financial"),Risk::Critical);assert_eq!(risk("mcp","readOnlyHint"),Risk::Critical);assert_eq!(risk("computer","click"),Risk::Critical);assert_eq!(risk("github","create_issue"),Risk::Confirm);assert_eq!(risk("coucou","list_integrations"),Risk::Safe);}
    #[tokio::test] async fn safe_auto_and_single_claim(){let c=Approvals::default();assert!(c.authorize_with(action("safe","coucou","list_integrations"),std::time::Duration::from_millis(5),|_|panic!("Safe should not present")).await);assert!(c.claim_execution("safe"));assert!(!c.claim_execution("safe"));assert!(!c.claim_execution("unknown"));}
    #[tokio::test] async fn confirm_allow_double_click(){let c=Approvals::default();let a=action("confirm","github","create_issue");assert!(c.authorize_with(a,std::time::Duration::from_millis(50),|e|if let ApprovalEvent::Requested(a)=e{c.decide_with(&a.id,true,|_|{});c.decide_with(&a.id,true,|_|{});}).await);assert!(c.claim_execution("confirm"));assert!(!c.claim_execution("confirm"));}
    #[tokio::test] async fn critical_deny(){let c=Approvals::default();assert!(!c.authorize_with(action("critical","resend","send_email"),std::time::Duration::from_millis(50),|e|if let ApprovalEvent::Requested(a)=e{c.decide_with(&a.id,false,|_|{});}).await);assert!(!c.claim_execution("critical"));}
    #[tokio::test] async fn timeout_denies(){let c=Approvals::default();assert!(!c.authorize_with(action("expiry","github","create_issue"),std::time::Duration::from_millis(5),|_|{}).await);c.decide_with("expiry",true,|_|{});assert!(!c.claim_execution("expiry"));}
    #[tokio::test] async fn cancel_revokes_allowed_not_started(){let c=Approvals::default();assert!(c.authorize_with(action("race","github","create_issue"),std::time::Duration::from_millis(50),|e|if let ApprovalEvent::Requested(a)=e{c.decide_with(&a.id,true,|_|{});c.cancel_with(|_|{});}).await);assert!(!c.claim_execution("race"));}
    #[test] fn secrets_redacted_keys_not_keyboard(){let v=redact(&json!({"api_key":"secret","nested":{"password":"private"},"keys":["ENTER"],"text":"Bearer sensitive"}));assert_eq!(v["api_key"],"[REDACTED]");assert_eq!(v["nested"]["password"],"[REDACTED]");assert_eq!(v["keys"],json!(["ENTER"]));assert_eq!(v["text"],"[REDACTED]");}
}

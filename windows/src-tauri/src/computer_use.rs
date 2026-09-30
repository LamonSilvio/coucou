use serde_json::{json,Value};
use tauri::{AppHandle,Manager};
use crate::actions::{Action,Approvals,risk,audit};
pub const SUPPORTED:&[&str]=&["screenshot","wait","move","click","double_click","scroll","type","keypress","drag"];
pub fn parse(call:&Value)->Result<Vec<Value>,String>{
    let actions=call["actions"].as_array().filter(|a|!a.is_empty()&&a.len()<=20).ok_or("Invalid computer action batch.")?;
    if call["type"]!="computer_call"{return Err("Invalid computer call.".into())}
    for a in actions{
        if !SUPPORTED.contains(&a["type"].as_str().unwrap_or(""))||crate::actions::redact(a)!=*a{return Err("Unsupported or sensitive computer action.".into())}
        if a["type"]=="type"&&!a["text"].as_str().is_some_and(|s|s.len()<=2000){return Err("Computer text exceeds limit.".into())}
        if a["type"]=="keypress"&&!a["keys"].as_array().is_some_and(|keys|keys.len()<=4&&keys.iter().all(|k|k.as_str().is_some_and(|s|["ENTER","TAB","ESC","ESCAPE","BACKSPACE","ARROWUP","ARROWDOWN","ARROWLEFT","ARROWRIGHT"].contains(&s.to_uppercase().as_str())))){return Err("Unknown keys and clipboard/credential shortcuts blocked.".into())}
    }
    Ok(actions.clone())
}
pub trait Executor {fn execute(&self,action:&Value)->Result<String,String>;}
pub struct WindowsComputerExecutor {pub target:String}
impl Executor for WindowsComputerExecutor {
    fn execute(&self,action:&Value)->Result<String,String>{
        use std::{io::{Write,Read},process::{Command,Stdio},os::windows::process::CommandExt};
        if !["msedge","chrome","firefox"].contains(&self.target.as_str()){return Err("Select a supported browser target.".into())}
        let binary=std::path::PathBuf::from(std::env::var_os("SystemRoot").ok_or("Windows system directory unavailable.")?).join("System32/WindowsPowerShell/v1.0/powershell.exe");
        let mut process=Command::new(binary).args(["-NoProfile","-NonInteractive","-Command",include_str!("computer-executor.ps1")]).creation_flags(0x08000000).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|_|"Computer executor unavailable.")?;
        let mut stdin=process.stdin.take().ok_or("Input unavailable.")?;
        stdin.write_all(json!({"target":self.target,"action":action}).to_string().as_bytes()).map_err(|_|"Computer input failed.")?;drop(stdin);
        let stdout=process.stdout.take().ok_or("Output unavailable.")?;
        let reader=std::thread::spawn(move||{let mut v=vec![];stdout.take(28_000_001).read_to_end(&mut v).map(|_|v)});
        let start=std::time::Instant::now();
        loop{
            if let Some(status)=process.try_wait().map_err(|_|"Computer executor failed.")?{
                let bytes=reader.join().map_err(|_|"Capture failed.")?.map_err(|_|"Capture failed.")?;
                if !status.success()||bytes.len()>28_000_000{return Err("Computer action blocked or failed. Verify target, permissions and focused field.".into())}
                return String::from_utf8(bytes).map_err(|_|"Invalid screenshot encoding.".into())
            }
            let limit=if action["type"]=="save_image"{600}else{15};
            if start.elapsed()>std::time::Duration::from_secs(limit){let _=process.kill();let _=process.wait();return Err("Computer executor timed out.".into())}
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
}
pub async fn handle(app:&AppHandle,call:&Value,target:&str)->Result<Value,String>{
    let actions=parse(call)?;let id=call["call_id"].as_str().filter(|s|crate::openai::safe_id(s)).ok_or("Invalid computer call identifier.")?;
    let approvals=app.state::<Approvals>();
    if let Some(checks)=call["pending_safety_checks"].as_array().filter(|a|!a.is_empty()){
        let a=Action{id:format!("{id}-safety"),provider:"openai".into(),integration:"computer".into(),operation:"safety_checks".into(),parameters:json!({"checks":checks}),risk:crate::actions::Risk::Critical};
        if !approvals.authorize(app,a).await{return Err("Computer safety check denied.".into())}
    }
    for (i,action) in actions.into_iter().enumerate(){
        let operation=action["type"].as_str().unwrap().to_owned();if operation=="screenshot"{continue}
        let a=Action{id:format!("{id}-{i}"),provider:"openai".into(),integration:"computer".into(),operation:operation.clone(),parameters:action.clone(),risk:risk("computer",&operation)};
        if !approvals.authorize(app,a.clone()).await||!approvals.claim_execution(&a.id){return Err("Computer action denied or expired.".into())}
        let executor=WindowsComputerExecutor{target:target.into()};
        let result=tauri::async_runtime::spawn_blocking(move||executor.execute(&action)).await.map_err(|_|"Computer executor failed.")?;audit(&a,if result.is_ok(){"success"}else{"failure"});result?;
    }
    let capture=Action{id:format!("{id}-capture"),provider:"openai".into(),integration:"computer".into(),operation:"screenshot".into(),parameters:json!({"effect":"Transmit primary display screenshot to OpenAI. Check no credentials or sensitive windows are visible."}),risk:crate::actions::Risk::Critical};
    if !approvals.authorize(app,capture.clone()).await||!approvals.claim_execution(&capture.id){return Err("Screenshot transmission denied.".into())}
    let executor=WindowsComputerExecutor{target:target.into()};
    let result=tauri::async_runtime::spawn_blocking(move||executor.execute(&json!({"type":"screenshot"}))).await.map_err(|_|"Capture failed.")?;audit(&capture,if result.is_ok(){"success"}else{"failure"});let image=result?;
    let mut output=json!({"type":"computer_call_output","call_id":id,"output":{"type":"computer_screenshot","image_url":format!("data:image/png;base64,{image}"),"detail":"original"}});
    if call["pending_safety_checks"].as_array().is_some_and(|a|!a.is_empty()){output["acknowledged_safety_checks"]=call["pending_safety_checks"].clone();}
    Ok(output)
}

#[cfg(test)]mod tests{
 use super::*;
 #[test]fn official_action_batch_parsing(){assert_eq!(parse(&json!({"type":"computer_call","actions":[{"type":"keypress","keys":["ENTER"]},{"type":"click","x":1,"y":2}]})).unwrap().len(),2);}
 #[test]fn no_scripts_or_clipboard(){for a in [json!({"type":"exec","code":"bad"}),json!({"type":"keypress","keys":["CTRL","V"]}),json!({"type":"type","text":"Bearer private"})]{assert!(parse(&json!({"type":"computer_call","actions":[a]})).is_err());}}
 #[test]fn mock_executor(){struct Fake;impl Executor for Fake{fn execute(&self,a:&Value)->Result<String,String>{Ok(a["type"].as_str().unwrap().into())}}assert_eq!(Fake.execute(&json!({"type":"click"})).unwrap(),"click");}
}

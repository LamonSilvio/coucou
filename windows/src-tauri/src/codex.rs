//! Official app-server JSONL transport; never reads unrelated CLI sessions or credentials.
use std::{collections::HashMap, io::{BufRead, BufReader, Write}, process::{Child, ChildStdin, Command, Stdio}, sync::Mutex, os::windows::process::CommandExt};
use serde::{Serialize, Deserialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all="camelCase")]
pub struct AgentEvent {
    pub provider: String, pub session: String, pub kind: String, pub detail: String,
    pub request_id: Option<String>,
}

struct Session {
    child: Child, stdin: ChildStdin, generation: u64, cwd: String, prompt: String, ready: bool,
    thread: Option<String>, turn: Option<String>, approvals: HashMap<String,Value>, proposals: HashMap<String,String>,
}
#[derive(Default)]
pub struct Codex { session: Mutex<Option<Session>>, generation: std::sync::atomic::AtomicU64 }

impl Codex {
    pub fn start(&self, app: AppHandle, binary: String, cwd: String, prompt: String) -> Result<(),String> {
        if !std::path::Path::new(&binary).is_absolute() || !std::path::Path::new(&cwd).is_absolute() || !std::path::Path::new(&cwd).is_dir() || prompt.trim().is_empty() {
            return Err("Choose an absolute Codex executable, project folder and prompt in Settings.".into());
        }
        let mut guard = self.session.lock().unwrap();
        if guard.is_some() { return Err("Stop the current Codex session first.".into()); }
        let mut child = Command::new(binary).arg("app-server").current_dir(&cwd).creation_flags(0x08000000)
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
            .map_err(|_| "Codex could not start. Check installation and the executable path.")?;
        let stdout = child.stdout.take().ok_or("Codex stdout unavailable.")?;
        let stdin = child.stdin.take().ok_or("Codex stdin unavailable.")?;
        let generation = self.generation.fetch_add(1,std::sync::atomic::Ordering::SeqCst) + 1;
        let mut session = Session {child, stdin, generation, cwd, prompt, ready:false, thread:None, turn:None, approvals:HashMap::new(),proposals:HashMap::new()};
        send(&mut session,json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"coucou","title":"Coucou","version":"0.1.1"}}}))?;
        *guard = Some(session); drop(guard);
        let startup_app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(30));
            let codex = startup_app.state::<Codex>();
            let expired = {
                let guard = codex.session.lock().unwrap();
                if let Some(s) = guard.as_ref().filter(|s| s.generation == generation && !s.ready) {
                    emit(&startup_app,s,"agentFailed","Codex initialization timed out. Check installation and authentication.".into(),None); true
                } else { false }
            };
            if expired { codex.close(&startup_app,Some(generation)); }
        });
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                // Bound the frame while reading; do not allocate arbitrary process output.
                let mut limited = std::io::Read::take(&mut reader,4_000_001);
                match limited.read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) if line.len() > 4_000_000 => break,
                    _ => {},
                }
                if let Ok(value) = serde_json::from_slice::<Value>(&line) { app.state::<Codex>().handle(&app,generation,value); }
            }
            app.state::<Codex>().close(&app,Some(generation));
        });
        Ok(())
    }

    pub fn close(&self, app: &AppHandle, generation: Option<u64>) {
        let mut guard = self.session.lock().unwrap();
        if generation.is_some_and(|g| guard.as_ref().is_some_and(|s| s.generation != g)) { return; }
        if let Some(mut s) = guard.take() {
            let _ = s.child.kill(); let _ = s.child.wait();
            emit(app,&s,"sessionEnded","Codex stopped".into(),None);
        }
    }

    pub fn decide(&self, app: &AppHandle, request_id: &str, allow: bool) -> Result<(),String> {
        let mut guard = self.session.lock().unwrap();
        let s = guard.as_mut().ok_or("Codex session ended.")?;
        let id = s.approvals.remove(request_id).ok_or("Codex approval expired or already resolved.")?;
        send(s,json!({"id":id,"result":{"decision":decision(allow)}}))?;
        emit(app,s,"statusChanged","Codex working".into(),None);
        Ok(())
    }

    fn handle(&self, app: &AppHandle, generation: u64, m: Value) {
        let mut guard = self.session.lock().unwrap();
        let Some(s) = guard.as_mut().filter(|s| s.generation == generation) else { return };
        if m.get("method").is_none() {
            if m.get("error").is_some() { emit(app,s,"agentFailed","Codex request failed. Check codex login and model availability.".into(),None); return }
            match m["id"].as_u64() {
                Some(1) => {
                    let _ = send(s,json!({"method":"initialized","params":{}}));
                    let body = json!({"id":2,"method":"thread/start","params":{"cwd":s.cwd,"sandbox":"readOnly","approvalPolicy":"untrusted"}});
                    let _ = send(s,body);
                }
                Some(2) => {
                    s.thread = m["result"]["thread"]["id"].as_str().map(str::to_owned);
                    if let Some(id) = &s.thread {
                        emit(app,s,"sessionStarted",format!("Codex: {id}"),None);
                        let body = json!({"id":3,"method":"turn/start","params":{"threadId":id,"input":[{"type":"text","text":s.prompt}]}});
                        let _ = send(s,body);
                    }
                }
                Some(3) => { s.turn = m["result"]["turn"]["id"].as_str().map(str::to_owned); s.ready = s.turn.is_some(); }
                _ => {},
            }
            return;
        }
        let method = m["method"].as_str().unwrap_or(""); let p = &m["params"];
        if p["threadId"].as_str().is_some_and(|id| Some(id) != s.thread.as_deref()) { return }
        match method {
            "turn/started" => { s.turn = p["turn"]["id"].as_str().map(str::to_owned); s.ready = s.turn.is_some(); emit(app,s,"statusChanged","Codex working".into(),None); }
            "turn/completed" => {
                emit(app,s,if p["turn"]["status"] == "failed" {"agentFailed"} else {"agentCompleted"},format!("Codex turn {}",p["turn"]["status"].as_str().unwrap_or("ended")),None);
                s.approvals.clear(); s.turn = None;
            }
            "item/started" | "item/completed" => {
                let i = &p["item"]; let done = method == "item/completed";
                let (kind,detail) = match i["type"].as_str().unwrap_or("tool") {
                    "commandExecution" => (if done {"commandCompleted"} else {"commandStarted"},i["command"].as_str().unwrap_or("Command").to_owned()),
                    "fileChange" => {
                        let changes = i["changes"].as_array().cloned().unwrap_or_default();
                        let preview = changes.iter().map(|c|format!("{}\n{}",c["path"].as_str().unwrap_or("File"),c["diff"].as_str().unwrap_or(""))).collect::<Vec<_>>().join("\n");
                        s.proposals.insert(i["id"].as_str().unwrap_or("").to_owned(),preview);
                        (if done {"fileModified"} else {"toolStarted"},changes.iter().filter_map(|c|c["path"].as_str()).collect::<Vec<_>>().join(", "))
                    }
                    "agentMessage" if done => ("toolCompleted",i["text"].as_str().unwrap_or("Codex response").chars().take(300).collect()),
                    other => (if done {"toolCompleted"} else {"toolStarted"},other.to_owned()),
                };
                emit(app,s,kind,detail,None);
            }
            "serverRequest/resolved" => {
                s.approvals.remove(&p["requestId"].to_string());
                emit(app,s,"statusChanged","Codex approval resolved".into(),Some(p["requestId"].to_string()));
            }
            _ => {},
        }
        let Some(id) = m.get("id") else { return };
        if !["item/commandExecution/requestApproval","item/fileChange/requestApproval"].contains(&method) {
            let _ = send(s,json!({"id":id,"error":{"code":-32601,"message":"Unsupported client request"}})); return
        }
        if !can_approve(method,s.thread.as_deref(),s.turn.as_deref(),p) || !s.approvals.is_empty() {
            let _ = send(s,json!({"id":id,"result":{"decision":"decline"}})); return
        }
        if method == "item/fileChange/requestApproval" && s.proposals.get(p["itemId"].as_str().unwrap_or("")).is_none_or(|v|v.is_empty()) {
            let _ = send(s,json!({"id":id,"result":{"decision":"decline"}}));
            emit(app,s,"agentFailed","Codex file change has no reviewable diff. Request a smaller change.".into(),None); return
        }
        let detail = if p["networkApprovalContext"].is_object() {
            format!("Network access: {}://{}",p["networkApprovalContext"]["protocol"].as_str().unwrap_or(""),p["networkApprovalContext"]["host"].as_str().unwrap_or(""))
        } else { p["command"].as_str().map(str::to_owned).or_else(||s.proposals.get(p["itemId"].as_str().unwrap_or("")).cloned()).unwrap_or_else(||p["reason"].as_str().unwrap_or("Codex file change").to_owned()) };
        if detail.chars().count() > 20000 {
            let _ = send(s,json!({"id":id,"result":{"decision":"decline"}}));
            emit(app,s,"agentFailed","Codex approval exceeds the review limit. Split the task.".into(),None); return
        }
        let request_id = id.to_string(); s.approvals.insert(request_id.clone(),id.clone());
        emit(app,s,"permissionRequested",detail,Some(request_id.clone()));
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(110));
            let codex = app.state::<Codex>();
            if codex.session.lock().unwrap().as_ref().is_some_and(|s| s.generation == generation && s.approvals.contains_key(&request_id)) { let _ = codex.decide(&app,&request_id,false); }
        });
    }
}

fn send(s: &mut Session, value: Value) -> Result<(),String> {
    let bytes = serde_json::to_vec(&value).map_err(|_| "Invalid Codex request.")?;
    s.stdin.write_all(&bytes).and_then(|_|s.stdin.write_all(b"\n")).and_then(|_|s.stdin.flush()).map_err(|_| "Codex connection closed.".into())
}
fn emit(app: &AppHandle, s: &Session, kind: &str, detail: String, request_id: Option<String>) {
    let _ = app.emit("agent",AgentEvent {provider:"codex".into(),session:s.thread.clone().unwrap_or_default(),kind:kind.into(),detail,request_id});
}

fn decision(allow: bool) -> &'static str { if allow {"accept"} else {"decline"} }
fn can_approve(method: &str, thread: Option<&str>, turn: Option<&str>, params: &Value) -> bool {
    ["item/commandExecution/requestApproval","item/fileChange/requestApproval"].contains(&method)
        && thread.is_some() && turn.is_some() && params["threadId"].as_str() == thread && params["turnId"].as_str() == turn
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn official_decisions_and_scoped_approvals() {
        let p = json!({"threadId":"thread","turnId":"turn"});
        assert_eq!(decision(true),"accept"); assert_eq!(decision(false),"decline");
        assert!(can_approve("item/commandExecution/requestApproval",Some("thread"),Some("turn"),&p));
        assert!(!can_approve("item/commandExecution/requestApproval",Some("other"),Some("turn"),&p));
        assert!(!can_approve("item/fileChange/requestApproval",Some("thread"),None,&p));
        assert!(!can_approve("fakeApproval",Some("thread"),Some("turn"),&p));
    }
}

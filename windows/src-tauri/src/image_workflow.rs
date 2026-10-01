use serde_json::{json,Value};
pub fn intent(query:&str)->Option<&'static str>{
    let q=query.to_lowercase();
    if ["rimuovi lo sfondo","remove the background","cambia il colore","modifica questa immagine","edit this image"].iter().any(|s|q.contains(s)){Some("edit")}
    else if ["genera un'immagine","crea un'immagine","generate an image","draw ","disegna "].iter().any(|s|q.contains(s)){Some("generate")}else{None}
}
pub fn tool(model:&str,size:&str,transparent:bool,action:Option<&str>)->Result<Value,String>{
    let c:Value=serde_json::from_str(crate::openai::CATALOG).map_err(|_|"Image configuration missing.")?;
    let model=if model.is_empty(){c["defaultImageModel"].as_str().unwrap_or("")}else{model};
    if !c["imageModels"].as_array().is_some_and(|a|a.iter().any(|v|v==model))||!["auto","1024x1024","1536x1024","1024x1536"].contains(&size){return Err("Unsupported image model or size.".into())}
    Ok(json!({"type":"image_generation","model":model,"size":size,"background":if transparent{"transparent"}else{"auto"},"output_format":"png","action":action.unwrap_or("auto")}))
}
pub fn parse(output:&[Value])->Result<Vec<String>,String>{
    output.iter().filter(|i|i["type"]=="image_generation_call").map(|i|{
        let s=i["result"].as_str().ok_or("Missing image result.")?;
        if i["status"]!="completed"||s.len()>68_000_000{return Err("Incomplete or oversized image.".into())}
        let bytes=decode(s)?;
        if !valid_png(&bytes){return Err("Invalid generated PNG image.".into())}
        Ok(s.to_owned())
    }).collect()
}
pub fn decode(s:&str)->Result<Vec<u8>,String>{
    if s.len()>68_000_000 || s.len()%4!=0{return Err("Invalid image encoding.".into())}
    let clean=s.trim_end_matches('=');
    if s.len()-clean.len()>2 || clean.contains('='){return Err("Invalid image encoding.".into())}
    let mut bytes=Vec::new();let mut buffer=0u32;let mut bits=0;
    for c in s.bytes(){if c==b'='{break}let v=match c{b'A'..=b'Z'=>c-b'A',b'a'..=b'z'=>c-b'a'+26,b'0'..=b'9'=>c-b'0'+52,b'+'=>62,b'/'=>63,_=>return Err("Invalid image encoding.".into())};buffer=(buffer<<6)|v as u32;bits+=6;if bits>=8{bits-=8;bytes.push((buffer>>bits)as u8);}}
    Ok(bytes)
}
pub fn valid_png(bytes:&[u8])->bool{
    if bytes.len()<45||bytes.len()>50_000_000||!bytes.starts_with(&[137,80,78,71,13,10,26,10])||&bytes[12..16]!=b"IHDR"||!bytes.ends_with(&[0,0,0,0,73,69,78,68,174,66,96,130]){return false}
    let w=u32::from_be_bytes(bytes[16..20].try_into().unwrap()) as u64;
    let h=u32::from_be_bytes(bytes[20..24].try_into().unwrap()) as u64;
    w>0&&h>0&&w<=16384&&h<=16384&&w*h<=32_000_000
}
pub fn save_with(image:&str,choose:impl FnOnce()->Result<Option<std::path::PathBuf>,String>)->Result<String,String>{
    let bytes=decode(image)?;if !valid_png(&bytes){return Err("Invalid PNG image.".into())}
    let Some(path)=choose()? else{return Ok("Cancelled".into())};
    if !path.is_absolute(){return Err("Choose an absolute image destination.".into())}
    std::fs::write(path,bytes).map_err(|_|"Could not save image.".to_string())?;Ok("Saved".into())
}

#[cfg(test)]mod tests{
 use super::*;
 #[test]fn generation_request(){let v=tool("","1024x1024",true,Some("generate")).unwrap();assert_eq!(v["action"],"generate");assert_eq!(v["background"],"transparent");}
 #[test]fn editing_and_vision_separate(){assert_eq!(intent("rimuovi lo sfondo"),Some("edit"));assert_eq!(intent("cosa c'è in questa immagine?"),None);assert_eq!(tool("","auto",false,Some("edit")).unwrap()["action"],"edit");}
 #[test]fn base64_png_response(){let image="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6R6IAAAAASUVORK5CYII=";assert_eq!(parse(&[json!({"type":"image_generation_call","status":"completed","result":image})]).unwrap(),vec![image]);assert!(parse(&[json!({"type":"image_generation_call","status":"completed","result":"aGVsbG8="})]).is_err());}
 #[test]fn user_chosen_save_and_cancel(){let image="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6R6IAAAAASUVORK5CYII=";assert_eq!(save_with(image,||Ok(None)).unwrap(),"Cancelled");let path=std::env::temp_dir().join(format!("coucou-save-{}.png",std::process::id()));assert_eq!(save_with(image,||Ok(Some(path.clone()))).unwrap(),"Saved");assert!(valid_png(&std::fs::read(&path).unwrap()));let _=std::fs::remove_file(path);}
 #[test]fn incompatible_image_settings(){assert!(tool("unknown","auto",false,None).is_err());assert!(tool("","arbitrary",false,None).is_err());assert!(decode("not base64!").is_err());}
}

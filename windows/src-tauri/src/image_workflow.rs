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
        if bytes.len()>50_000_000||!bytes.starts_with(&[137,80,78,71,13,10,26,10]){return Err("Invalid generated PNG image.".into())}
        Ok(s.to_owned())
    }).collect()
}
pub fn decode(s:&str)->Result<Vec<u8>,String>{
    let mut bytes=Vec::new();let mut buffer=0u32;let mut bits=0;
    for c in s.bytes(){if c==b'='{break}let v=match c{b'A'..=b'Z'=>c-b'A',b'a'..=b'z'=>c-b'a'+26,b'0'..=b'9'=>c-b'0'+52,b'+'=>62,b'/'=>63,_=>return Err("Invalid image encoding.".into())};buffer=(buffer<<6)|v as u32;bits+=6;if bits>=8{bits-=8;bytes.push((buffer>>bits)as u8);}}
    Ok(bytes)
}

#[cfg(test)]mod tests{
 use super::*;
 #[test]fn generation_request(){let v=tool("","1024x1024",true,Some("generate")).unwrap();assert_eq!(v["action"],"generate");assert_eq!(v["background"],"transparent");}
 #[test]fn editing_and_vision_separate(){assert_eq!(intent("rimuovi lo sfondo"),Some("edit"));assert_eq!(intent("cosa c'è in questa immagine?"),None);assert_eq!(tool("","auto",false,Some("edit")).unwrap()["action"],"edit");}
 #[test]fn base64_png_response(){let image="iVBORw0KGgo=";assert_eq!(parse(&[json!({"type":"image_generation_call","status":"completed","result":image})]).unwrap(),vec![image]);assert!(parse(&[json!({"type":"image_generation_call","status":"completed","result":"aGVsbG8="})]).is_err());}
 #[test]fn incompatible_image_settings(){assert!(tool("unknown","auto",false,None).is_err());assert!(tool("","arbitrary",false,None).is_err());assert!(decode("not base64!").is_err());}
}

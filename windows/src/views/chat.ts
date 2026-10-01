// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  const reply = h("div", {class:"reply"},h("div", {text:(message.provider ? message.provider + " · " : "") + message.content}));
  for (const encoded of message.images ?? []) {
    const uri="data:image/png;base64,"+encoded;
    const save = h("button",{text:"Save Image"});
    save.addEventListener("click",async()=>{save.disabled=true;try{save.textContent=await Bridge.imageSave(encoded);}catch{save.textContent="Save failed — retry";}finally{save.disabled=false;}});
    reply.append(h("img",{src:uri,alt:"Generated image",style:"max-width:100%;max-height:180px;object-fit:contain"}),save);
  }
  for (const source of message.sources ?? []) reply.append(h("button", {text:source.title,onclick:() => void Bridge.openUrl(source.url)}));
  for (const artifact of message.artifacts ?? []) {
    const button = h("button", {text:`Save ${artifact.filename}`});
    button.addEventListener("click", async () => {
      button.disabled = true;
      try { const path = await Bridge.downloadArtifact(artifact.containerId,artifact.fileId); State.noteMessage = `Saved: ${path}`; }
      catch { State.noteMessage = "Could not save generated file. It may have expired."; }
      finally { button.disabled = false; State.view = "note"; State.notify(); }
    });
    reply.append(button);
  }
  return h("div", {class:"chat-row"},reply);
}

function typingDots(): HTMLElement {
  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "typing" }, h("i"), h("i"), h("i")),
  );
}

/** The coloured chip showing what the question is about (a dropped file). */
function contextChip(label: string): HTMLElement {
  const chip = h("div", { class: "chip" }, h("i", { class: "chip-dot" }), h("span", { text: label }));
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, send,h("button",{text:"Cancel",onclick:()=>void Bridge.actionCancel()}));

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let provider = State.settings.aiProvider;
  let renderedCount = -1;

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    input.value = "";
    sending = true;
    Sound.play("send");

    if (provider !== State.settings.aiProvider) {
      provider = State.settings.aiProvider;
      State.chatHistory = [];
      await Bridge.chatReset();
    }
    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context);
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text, provider: reply.provider, sources: reply.sources, artifacts: reply.artifacts,images:reply.images });
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      sending = false;
      State.activeAITool = null;
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") {
      e.preventDefault();
      void submit();
    }
    e.stopPropagation(); // Escape closes the island, not the chat
  });

  return {
    el,
    sync() {
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? (State.activeAITool ? 0.75 : 0.5) : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) { log.append(typingDots()); if (State.activeAITool) log.append(h("div", {class:"hint",text:State.activeAITool})); }
        log.scrollTop = log.scrollHeight;
      }

      input.placeholder = `Ask ${State.settings.aiProvider === "openai" ? "OpenAI" : State.settings.aiProvider === "auto" ? "AI (Auto)" : "Claude"}…`;
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

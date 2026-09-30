import { onEvent, Bridge } from "../core/bridge";
import type { AgentEvent } from "../core/agent-events";
import { State } from "../core/state";
import { Sound } from "../core/sound";
import type { Island } from "./island";

export function registerAgentHandlers(island: Island) {
  void onEvent<AgentEvent>("agent", event => {
    if (event.provider !== "codex") return;
    const id = "integration_codex";
    if (!State.tasks.some(t => t.id === id)) State.tasks.push({id,name:"Codex",color:"#10A37F",state:"idle",stepIndex:0,steps:[],source:"codex",isIntegration:true});
    if (event.kind === "permissionRequested" && event.requestId) {
      if (State.paused || State.pendingApproval) { void Bridge.codexDecide(event.requestId,false).catch(() => {}); return; }
      State.pendingApproval = {provider:"codex",requestId:event.requestId,sessionId:event.session,tool:"Codex",command:event.detail};
      State.focusId = id; State.isPinned = true;
      State.updateTask(id,"approval"); Sound.play("approval"); island.alert("approval");
    } else {
      const pending = State.pendingApproval;
      if (pending?.provider === "codex" && (event.kind === "sessionEnded" || event.kind === "agentCompleted" || event.kind === "agentFailed" ||
        (event.kind === "statusChanged" && (!event.requestId || event.requestId === pending.requestId)))) {
        State.pendingApproval = null; State.isPinned = false; island.dropPin();
        if (State.view === "approval") island.setView(State.defaultView());
      }
      State.updateTask(id,event.kind === "agentFailed" ? "error" : event.kind === "agentCompleted" ? "finished" : event.kind === "sessionEnded" ? "idle" : "working");
      State.appendStep(id,`Codex · ${event.kind}: ${event.detail.slice(0,300)}`);
      if (event.kind === "agentCompleted") Sound.play("finish");
      if (event.kind === "agentFailed") Sound.play("error");
      if (State.mode === "hidden" && !State.paused) island.reveal();
    }
    State.notify();
  });
}

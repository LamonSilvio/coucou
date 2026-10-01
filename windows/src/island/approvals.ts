import { ApprovalQueue } from "../core/approvals";
import { State, type ApprovalInfo } from "../core/state";
import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import type { Island } from "./island";

let queue: ApprovalQueue | undefined;
export function enqueueApproval(info: ApprovalInfo, finish: (allow: boolean, reason: string) => void) {
  if (State.paused || !queue) { finish(false, "cancel"); return; }
  queue.enqueue(info, finish, info.provider === "claudeCode" ? 107_000 : 109_000);
}
export function resolveApproval(id: string, allow: boolean, notify = true) { return queue?.resolve(id, allow, notify); }
export function registerApprovalHandlers(island: Island) {
  queue = new ApprovalQueue(info => {
    State.pendingApproval = info; State.isPinned = info !== null;
    if (info) { Sound.play("approval"); island.alert("approval"); }
    else { island.dropPin(); if (State.view === "approval") island.setView(State.defaultView()); }
    State.notify();
  });
  void onEvent<{id:string;provider:string;integration:string;operation:string;risk:string;parameters:unknown}>("action-approval", action => {
    enqueueApproval({provider:"actions",requestId:action.id,sessionId:"",tool:action.integration,
      command:`Provider: ${action.provider}\nServer / Integration: ${action.integration}\nAction: ${action.operation}\nRisk: ${action.risk.toUpperCase()}\n${JSON.stringify(action.parameters,null,2)}`},
      allow => void Bridge.actionDecide(action.id,allow).catch(() => {}));
  });
  void onEvent<string>("action-resolved", id => resolveApproval(id,false,false));
}

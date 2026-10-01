import type { ApprovalInfo } from "./state";

/** FIFO presentation queue. Native executors remain the permission authority. */
export class ApprovalQueue {
  private queue: {info: ApprovalInfo; finish: (allow: boolean, reason: string) => void; timer: ReturnType<typeof setTimeout>}[] = [];
  private resolved = new Set<string>();
  constructor(private present: (info: ApprovalInfo | null) => void) {}
  enqueue(info: ApprovalInfo, finish: (allow: boolean, reason: string) => void, timeout = 110_000) {
    if (!info.requestId || this.resolved.has(info.requestId) || this.queue.some(q => q.info.requestId === info.requestId)) return;
    const timer = setTimeout(() => this.resolve(info.requestId, false, true, "timeout"), timeout);
    this.queue.push({info, finish, timer});
    if (this.queue.length === 1) this.present(info);
  }
  resolve(id: string, allow: boolean, notify = true, reason = "decision") {
    const index = this.queue.findIndex(q => q.info.requestId === id);
    if (index < 0 || (allow && index !== 0)) return false;
    const [item] = this.queue.splice(index, 1);
    clearTimeout(item.timer); this.resolved.add(id);
    if (index === 0) this.present(this.queue[0]?.info ?? null);
    if (notify) item.finish(allow, reason);
    return true;
  }
  cancel() { for (const item of [...this.queue]) this.resolve(item.info.requestId, false, true, "cancel"); }
}

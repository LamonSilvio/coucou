import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
const code=ts.transpileModule(fs.readFileSync(new URL('../src/core/approvals.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ES2022}}).outputText;
const {ApprovalQueue}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
const info=id=>({requestId:id,sessionId:'',provider:'actions',tool:'GitHub',command:'Create issue CONFIRM'});
test('Shared approval FIFO and scoped decisions',()=>{
  const shown=[],decisions=[],q=new ApprovalQueue(i=>shown.push(i?.requestId));
  q.enqueue(info('a'),a=>decisions.push(['a',a]));q.enqueue(info('b'),a=>decisions.push(['b',a]));
  assert.equal(q.resolve('b',true),false);assert.deepEqual(shown,['a']);
  assert.equal(q.resolve('a',true),true);assert.equal(q.resolve('a',true),false);
  assert.equal(q.resolve('b',false),true);assert.deepEqual(decisions,[['a',true],['b',false]]);
});
test('Approval expiry denies and cannot be revived',async()=>{
  const decisions=[],q=new ApprovalQueue(()=>{});q.enqueue(info('expiry'),a=>decisions.push(a),5);
  await new Promise(resolve=>setTimeout(resolve,20));assert.deepEqual(decisions,[false]);assert.equal(q.resolve('expiry',true),false);
});
test('Cancellation drains all providers exactly once',()=>{
  const decisions=[],q=new ApprovalQueue(()=>{});q.enqueue({...info('claude'),provider:'claudeCode'},a=>decisions.push(a));q.enqueue(info('mcp'),a=>decisions.push(a));q.cancel();q.cancel();assert.deepEqual(decisions,[false,false]);
});
test('Native resolution removes stale card without second decision',()=>{
  let calls=0;const q=new ApprovalQueue(()=>{});q.enqueue(info('native'),()=>calls++);q.resolve('native',false,false);assert.equal(calls,0);
});
test('Repeated delivery does not overwrite a queued request',()=>{
  let calls=0;const q=new ApprovalQueue(()=>{});q.enqueue(info('id'),()=>calls++);q.enqueue(info('id'),()=>calls+=10);q.resolve('id',true);assert.equal(calls,1);
});

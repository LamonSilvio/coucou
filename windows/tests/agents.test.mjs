import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';

const source = fs.readFileSync(new URL('../src/core/agent-events.ts',import.meta.url),'utf8');
const code = ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ES2022}}).outputText;
const {claudeEvent,permits} = await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));

for (const [name,kind] of Object.entries({SessionStart:'sessionStarted',SessionEnd:'sessionEnded',PermissionRequest:'permissionRequested',Stop:'agentCompleted',StopFailure:'agentFailed',PostToolUse:'toolCompleted'})) {
  test(`Claude adapter: ${name}`,() => {
    const event = claudeEvent(name,'session-1');
    assert.equal(event.kind,kind); assert.equal(event.session,'session-1'); assert.equal(event.provider,'claudeCode');
  });
}
for (const [tool,kind] of [['Read','fileRead'],['Write','fileModified'],['Edit','fileModified'],['Bash','commandStarted'],['PowerShell','commandStarted'],['WebSearch','toolStarted']]) {
  test(`Claude tool: ${tool}`,() => assert.equal(claudeEvent('PreToolUse','s',tool).kind,kind));
}
test('Unknown events do not acquire meaning',() => assert.equal(claudeEvent('maliciousAllow','s'),null));
for (const level of ['safe','confirm','critical']) {
  test(`Permission level ${level}`,() => {
    assert.equal(permits(level,false),level === 'safe'); assert.equal(permits(level,true),true);
  });
}

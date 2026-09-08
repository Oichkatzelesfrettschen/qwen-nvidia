#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const page = fs.readFileSync(new URL('../webui/index.html', import.meta.url), 'utf8');
const answerSource = page.match(/function answerCall\([\s\S]*?\n\}/);
assert.ok(answerSource, 'fallback page answerCall implementation is absent');

const context = vm.createContext({ history: [], conversationGeneration: 17 });
vm.runInContext(`${answerSource[0]}; globalThis.answerCall = answerCall;`, context);

const toolCallId = 'call_retained_search_01';
const artifactSha256 = '7b'.repeat(32);
const approvalId = 'approval_pending_01';
context.history.push({
  role: 'assistant',
  tool_calls: [{ id: toolCallId, type: 'function',
    function: { name: 'web_fetch', arguments: '{}' } }],
  pending_approval: { id: approvalId, state: 'pending' },
});
vm.runInContext(
  `answerCall(${JSON.stringify(toolCallId)}, 'web_fetch', ` +
  `${JSON.stringify(JSON.stringify({ artifact_sha256: artifactSha256, approval_id: approvalId }))}, 17)`,
  context,
);
const retainedHistory = structuredClone(context.history);
assert.equal(retainedHistory[1].tool_call_id, toolCallId);
assert.match(retainedHistory[1].content, new RegExp(artifactSha256));

// Clear or a different request increments conversationGeneration. The actual
// page function must refuse a late result from generation 17.
context.conversationGeneration = 18;
vm.runInContext(
  `answerCall(${JSON.stringify(toolCallId)}, 'web_fetch', 'cross-request result', 17)`,
  context,
);
assert.equal(JSON.stringify(context.history), JSON.stringify(retainedHistory));

process.stdout.write(JSON.stringify({
  messages: retainedHistory,
  attribution: {
    request_id: 'request-retained',
    approval_id: approvalId,
    artifact_sha256: artifactSha256,
    tool_call_id: toolCallId,
    approval_state: 'pending_metadata_retained',
  },
  cross_request_result: 'refused_by_conversation_generation',
}));

#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

class FakeElement {
  constructor() {
    this.checked = false;
    this.children = [];
    this.className = '';
    this.hidden = false;
    this.listeners = new Map();
    this.scrollHeight = 0;
    this.scrollTop = 0;
    this._textContent = '';
    this.value = '';
  }

  // A DOM element returns null for an attribute it carries no value for, and
  // the page reads the broker origin through this call, so the double answers
  // the way an element without that attribute does: the page falls through to
  // its stated default rather than reading a value this harness invented.
  getAttribute() {
    return null;
  }

  get textContent() {
    return this._textContent;
  }

  set textContent(value) {
    this._textContent = value;
    if (value === '') this.children = [];
  }

  addEventListener(eventName, listener) {
    this.listeners.set(eventName, listener);
  }

  append(...children) {
    this.children.push(...children);
    for (const child of children) {
      this._textContent += typeof child === 'string' ? child : child.textContent;
    }
  }

  focus() {}
}

const elements = new Map();
const document = {
  createElement() {
    return new FakeElement();
  },
  querySelector(selector) {
    if (!elements.has(selector)) elements.set(selector, new FakeElement());
    return elements.get(selector);
  },
};

let storageWriteAttempts = 0;
const deniedStorage = {
  getItem() {
    throw new Error('storage denied');
  },
  removeItem() {
    storageWriteAttempts += 1;
    throw new Error('storage denied');
  },
  setItem() {
    storageWriteAttempts += 1;
    throw new Error('storage denied');
  },
};

const pendingRequests = [];
function deferredFetch(url, options = {}) {
  return new Promise((resolve, reject) => {
    pendingRequests.push({ url, options, resolve, reject });
  });
}

function takeRequest(predicate, description) {
  const requestIndex = pendingRequests.findIndex(predicate);
  assert.notEqual(requestIndex, -1, `missing request: ${description}`);
  return pendingRequests.splice(requestIndex, 1)[0];
}

function jsonResponse(payload, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return payload;
    },
  };
}

async function flushPromises() {
  for (let turn = 0; turn < 6; turn += 1) {
    await new Promise(resolve => setImmediate(resolve));
  }
}

const webuiPath = new URL('../webui/index.html', import.meta.url);
const webuiHtml = fs.readFileSync(webuiPath, 'utf8');
const inlineScript = webuiHtml.match(/<script>\s*([\s\S]*?)\s*<\/script>/);
assert.ok(inlineScript, 'fallback Web UI has no inline script');

const testInterface = `
globalThis.webuiModelStateTest = {
  selectRequestModel,
  setAttachments(nextAttachments) {
    attachments = nextAttachments;
    renderAttached();
  },
  state() {
    return {
      requestModel,
      nctx,
      nctxModel,
      attachments: attachments.map(attachment => ({ ...attachment })),
      contextText: $('#ctx').textContent,
      attachmentText: $('#attached').children.map(child => child.textContent),
    };
  },
  async runStaleProposalCheck(proposalModel) {
    const fetchBudget = { remaining: WEB_FETCH_BUDGET_PER_TURN };
    const searchBudget = { remaining: WEB_SEARCH_BUDGET_PER_TURN };
    const historyStart = history.length;
    const view = { turn: { root: document.createElement('div') } };
    await runProposedTools(
      [
        { name: WEB_FETCH_TOOL_NAME, args: JSON.stringify({ result_id: 'rid' }) },
        { name: WEB_SEARCH_TOOL_NAME, args: JSON.stringify({ query: 'query' }) },
      ],
      ['stale-fetch', 'stale-search'],
      view,
      false,
      fetchBudget,
      searchBudget,
      conversationGeneration,
      proposalModel,
      true,
    );
    return {
      fetchRemaining: fetchBudget.remaining,
      searchRemaining: searchBudget.remaining,
      messages: history.slice(historyStart).map(message => ({ ...message })),
    };
  },
};
`;

const browserContext = vm.createContext({
  console,
  document,
  fetch: deferredFetch,
  window: {
    alert() {},
    localStorage: deniedStorage,
    sessionStorage: deniedStorage,
  },
});
vm.runInContext(`${inlineScript[1]}\n${testInterface}`, browserContext, {
  filename: webuiPath.pathname,
});

const testApi = browserContext.webuiModelStateTest;
const modelA = 'model-A';
const modelB = 'model B/8k';

const rosterRequest = takeRequest(
  request => request.url === './v1/models', 'initial model roster');
rosterRequest.resolve(jsonResponse({ data: [{ id: modelA }, { id: modelB }] }));
await flushPromises();
// boot() probes GET /tools per roster row before it picks a default, and
// prefers the first row whose probe answers 200 over sort position: model A
// answers 200 here (an ordinary language row) and model B answers 403 (a
// review-only row), so the props request below being for model A is this
// rule choosing it rather than modelIds[0] happening to agree with it.
const toolsProbeA = takeRequest(
  request => request.url === './tools?model=model-A&autoload=true',
  'model A tool probe');
toolsProbeA.resolve(jsonResponse([], 200));
await flushPromises();
const toolsProbeB = takeRequest(
  request => request.url === './tools?model=model%20B%2F8k&autoload=true',
  'model B tool probe');
toolsProbeB.resolve(jsonResponse({ error: 'feature_disabled' }, 403));
await flushPromises();
const initialProps = takeRequest(
  request => request.url === './props?model=model-A', 'model A properties');
initialProps.resolve(jsonResponse({ n_ctx: 24576 }));
await flushPromises();
assert.equal(testApi.state().requestModel, modelA,
  'boot() did not default to the tool-offering row');
assert.equal(testApi.state().nctx, 24576);
assert.equal(testApi.state().nctxModel, modelA);

testApi.setAttachments([
  { name: 'retained.txt', text: 'retained text', tokens: 7000, tokenModel: modelA },
]);
testApi.selectRequestModel(modelB);
let state = testApi.state();
assert.equal(state.requestModel, modelB);
assert.equal(state.nctx, null);
assert.equal(state.nctxModel, null);
assert.equal(state.attachments[0].tokens, null);
assert.equal(state.attachments[0].tokenModel, null);
assert.match(state.contextText, /pending/);
assert.ok(state.attachmentText.some(text => text.includes('token count pending')));

const encodedProps = takeRequest(
  request => request.url === './props?model=model%20B%2F8k',
  'URL-encoded model B properties');
const modelBTokenize = takeRequest(
  request => request.url === './tokenize' &&
    JSON.parse(request.options.body).model === modelB,
  'model B attachment tokenization');
encodedProps.resolve(jsonResponse({ n_ctx: 8192 }));
modelBTokenize.resolve(jsonResponse({ tokens: [1, 2, 3] }));
await flushPromises();
state = testApi.state();
assert.equal(state.nctx, 8192);
assert.equal(state.nctxModel, modelB);
assert.equal(state.attachments[0].tokens, 3);
assert.equal(state.attachments[0].tokenModel, modelB);

testApi.selectRequestModel(modelA);
const staleProps = takeRequest(
  request => request.url === './props?model=model-A', 'stale model A properties');
const staleTokenize = takeRequest(
  request => request.url === './tokenize' &&
    JSON.parse(request.options.body).model === modelA,
  'stale model A tokenization');
testApi.selectRequestModel(modelB);
const currentProps = takeRequest(
  request => request.url === './props?model=model%20B%2F8k',
  'current model B properties');
const currentTokenize = takeRequest(
  request => request.url === './tokenize' &&
    JSON.parse(request.options.body).model === modelB,
  'current model B tokenization');
currentProps.resolve(jsonResponse({ n_ctx: 8192 }));
currentTokenize.resolve(jsonResponse({ tokens: [1, 2, 3, 4] }));
await flushPromises();
staleProps.resolve(jsonResponse({ n_ctx: 24576 }));
staleTokenize.resolve(jsonResponse({ tokens: new Array(99).fill(1) }));
await flushPromises();
state = testApi.state();
assert.equal(state.requestModel, modelB);
assert.equal(state.nctx, 8192);
assert.equal(state.nctxModel, modelB);
assert.equal(state.attachments[0].tokens, 4);
assert.equal(state.attachments[0].tokenModel, modelB);

testApi.selectRequestModel(modelA);
const failureProps = takeRequest(
  request => request.url === './props?model=model-A', 'model A properties after switch');
const failedTokenize = takeRequest(
  request => request.url === './tokenize' &&
    JSON.parse(request.options.body).model === modelA,
  'failed model A tokenization');
failureProps.resolve(jsonResponse({ n_ctx: 24576 }));
failedTokenize.reject(new Error('tokenizer unavailable'));
await flushPromises();
state = testApi.state();
assert.equal(state.attachments[0].tokens, null);
assert.equal(state.attachments[0].tokenModel, modelA);
assert.ok(state.attachmentText.some(text => text.includes('token count unavailable')));

testApi.selectRequestModel(modelB);
const malformedProps = takeRequest(
  request => request.url === './props?model=model%20B%2F8k',
  'malformed model B properties');
const recoveredTokenize = takeRequest(
  request => request.url === './tokenize' &&
    JSON.parse(request.options.body).model === modelB,
  'recovered model B tokenization');
malformedProps.resolve(jsonResponse({ n_ctx: '8192' }));
recoveredTokenize.resolve(jsonResponse({ tokens: [1] }));
await flushPromises();
state = testApi.state();
assert.equal(state.nctx, null);
assert.equal(state.nctxModel, null);
assert.match(state.contextText, /unavailable/);

testApi.setAttachments([
  { name: 'removed.txt', text: 'removed text', tokens: 1, tokenModel: modelB },
]);
testApi.selectRequestModel(modelA);
const removalProps = takeRequest(
  request => request.url === './props?model=model-A', 'removal model properties');
const removalTokenize = takeRequest(
  request => request.url === './tokenize' &&
    JSON.parse(request.options.body).model === modelA,
  'removed attachment tokenization');
testApi.setAttachments([]);
removalProps.resolve(jsonResponse({ n_ctx: 24576 }));
removalTokenize.resolve(jsonResponse({ tokens: [1, 2] }));
await flushPromises();
assert.deepEqual(testApi.state().attachments, []);
const requestCountBeforeStaleProposals = pendingRequests.length;
const staleProposalResult = await testApi.runStaleProposalCheck(modelB);
assert.equal(staleProposalResult.fetchRemaining, 2);
assert.equal(staleProposalResult.searchRemaining, 1);
assert.equal(staleProposalResult.messages.length, 2);
assert.ok(staleProposalResult.messages.every(message =>
  message.content.includes('proposed by model model B/8k')));
assert.equal(pendingRequests.length, requestCountBeforeStaleProposals);
assert.ok(storageWriteAttempts > 0);
assert.equal(pendingRequests.length, 0);

console.log('fallback_webui_model_state=accepted');

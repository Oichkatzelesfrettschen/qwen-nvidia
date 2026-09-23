import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const helperSource = await readFile(
  new URL("./llama-ui/qwen-graft-grant.js", import.meta.url),
  "utf8",
);
const { authorizeGraftTool, graftBrokerOrigin, graftToolForModel } = await import(
  `data:text/javascript;base64,${Buffer.from(helperSource).toString("base64")}`
);

for (const name of ['graft_start_build', 'graft_cancel_build',
    'qwen_graft_graft_start_build', 'qwen_graft_graft_cancel_build']) {
  test(`${name} hides authorization only in its model-facing schema`, () => {
    const definition = {
      type: 'function', function: {name, description: 'Run the selected Graft operation.',
        parameters: {type: 'object', additionalProperties: false,
          properties: {repo: {type: 'string'}, authorization: {type: 'string'}},
          required: ['repo', 'authorization']}}
    };
    const before = JSON.stringify(definition);
    const projected = graftToolForModel(new Proxy(definition, {}));
    assert.equal(JSON.stringify(definition), before);
    assert.notEqual(projected, definition);
    assert.deepEqual(projected.function.parameters.properties, {repo: {type: 'string'}});
    assert.deepEqual(projected.function.parameters.required, ['repo']);
    assert.equal(projected.function.parameters.additionalProperties, false);
    assert.equal(projected.function.description, definition.function.description);
    assert.equal(projected.function.name, name);
    assert.ok(definition.function.parameters.required.includes('authorization'));
  });
}

test('ordinary and unrelated MCP schemas keep their authorization contract', () => {
  for (const name of ['read_file', 'graft_status', 'other_graft_start_build', 'toString']) {
    const definition = {type: 'function', function: {name, parameters: {
      type: 'object', properties: {authorization: {type: 'string'}}, required: ['authorization']
    }}};
    assert.equal(graftToolForModel(definition), definition);
  }
});

function fixture({
  approve = true,
  sessionStatus = 200,
  grantStatus = 200,
  session = { session_secret: "session-secret" },
  grant = { authorization: "signed-grant" },
} = {}) {
  const calls = [];
  const approvals = [];
  const options = {
    approve(message) {
      approvals.push(message);
      return approve;
    },
    async request(url, init) {
      calls.push({ url, ...init });
      return new Response(
        JSON.stringify(url.endsWith("/session") ? session : grant),
        {
          status: url.endsWith("/session") ? sessionStatus : grantStatus,
        },
      );
    },
  };
  return { calls, approvals, options };
}

for (const tool of [
  "graft_start_build",
  "graft_cancel_build",
  "qwen_graft_graft_start_build",
  "qwen_graft_graft_cancel_build",
]) {
  test(`${tool} receives a fresh grant after exact-argument approval`, async () => {
    const { calls, approvals, options } = fixture();
    const args =
      tool === "graft_start_build"
        ? { repo: "discobsd", deep: true }
        : { job_id: "job-123" };
    const before = JSON.stringify(args);
    const result = await authorizeGraftTool(
      tool,
      args,
      { Authorization: "Bearer ui-key" },
      undefined,
      options,
    );
    assert.equal(approvals.length, 1);
    assert.ok(approvals[0].includes(tool));
    assert.ok(approvals[0].includes("http://127.0.0.1:8571"));
    assert.ok(approvals[0].includes(JSON.stringify(args, null, 2)));
    assert.equal(calls.length, 2);
    assert.equal(calls[0].headers.Authorization, "Bearer ui-key");
    assert.equal(calls[0].url, "http://127.0.0.1:8571/session");
    assert.equal(calls[1].url, "http://127.0.0.1:8571/grant-graft");
    assert.equal(calls[1].headers["X-Qwen-Web-Session"], "session-secret");
    assert.equal(calls[1].headers.Authorization, undefined);
    assert.deepEqual(JSON.parse(calls[1].body), {
      tool: tool.replace(/^qwen_graft_/, ""),
      arguments: args,
    });
    assert.deepEqual(result, { ...args, authorization: "signed-grant" });
    assert.equal(JSON.stringify(args), before);
    assert.notEqual(result, args);
    assert.equal(JSON.stringify(approvals).includes("signed-grant"), false);
    assert.ok(
      calls.every(
        (call) => call.redirect === "error" && call.credentials === "omit",
      ),
    );
  });
}

test("generic native tools retain their arguments and bypass the broker", async () => {
  const { calls, approvals, options } = fixture();
  const args = { path: "README.md" };
  assert.equal(
    await authorizeGraftTool("read_file", args, {}, undefined, options),
    args,
  );
  assert.equal(calls.length, 0);
  assert.equal(approvals.length, 0);
});

test("other MCP server prefixes cannot acquire Graft grants", async () => {
  const { calls, approvals, options } = fixture();
  const args = { repo: "discobsd" };
  assert.equal(
    await authorizeGraftTool(
      "unknown_graft_start_build",
      args,
      {},
      undefined,
      options,
    ),
    args,
  );
  assert.equal(calls.length, 0);
  assert.equal(approvals.length, 0);
});

test("every Graft operation requires another explicit approval", async () => {
  const { calls, approvals, options } = fixture();
  await authorizeGraftTool("graft_start_build", {}, {}, undefined, options);
  await authorizeGraftTool("graft_start_build", {}, {}, undefined, options);
  assert.equal(approvals.length, 2);
  assert.equal(calls.filter((call) => call.url.endsWith("/session")).length, 2);
});

test("denial and forged model authorization reach zero broker requests", async () => {
  for (const [args, approve] of [
    [{}, false],
    [{ authorization: "forged" }, true],
  ]) {
    const { calls, options } = fixture({ approve });
    await assert.rejects(
      authorizeGraftTool("graft_start_build", args, {}, undefined, options),
    );
    assert.equal(calls.length, 0);
  }
});

test("abort before and immediately after approval prevents grant acquisition", async () => {
  for (const before of [true, false]) {
    const controller = new AbortController();
    const { calls, options } = fixture();
    if (before) controller.abort();
    options.approve = () => {
      controller.abort();
      return true;
    };
    await assert.rejects(
      authorizeGraftTool(
        "graft_cancel_build",
        {},
        {},
        controller.signal,
        options,
      ),
      { name: "AbortError" },
    );
    assert.equal(calls.length, 0);
  }
});

for (const settings of [
  { sessionStatus: 401 },
  { grantStatus: 403 },
  { session: {} },
  { grant: {} },
  { grant: { authorization: 123 } },
  { grant: { authorization: "" } },
]) {
  test(`broker failure refuses execution: ${JSON.stringify(settings)}`, async () => {
    const { options } = fixture(settings);
    await assert.rejects(
      authorizeGraftTool("graft_start_build", {}, {}, undefined, options),
    );
  });
}

test("broker origin comes from served metadata rather than a shared URL", async () => {
  const previousDocument = globalThis.document;
  const previousWindow = globalThis.window;
  try {
    globalThis.window = { location: { href: "http://127.0.0.1:8080/?broker=http://127.0.0.1:9999" } };
    globalThis.document = { querySelector: () => null };
    assert.equal(graftBrokerOrigin(), "http://127.0.0.1:8571");
    const defaultBroker = fixture();
    await authorizeGraftTool("graft_start_build", {}, {}, undefined, defaultBroker.options);
    assert.equal(defaultBroker.calls[0].url, "http://127.0.0.1:8571/session");

    globalThis.document = { querySelector: () => ({ content: "http://[::1]:9000" }) };
    assert.equal(graftBrokerOrigin(), "http://[::1]:9000");
    const configuredBroker = fixture();
    await authorizeGraftTool("graft_start_build", {}, {}, undefined, configuredBroker.options);
    assert.equal(configuredBroker.calls[0].url, "http://[::1]:9000/session");
    assert.ok(configuredBroker.approvals[0].includes("http://[::1]:9000"));

    for (const broker of [
      "https://example.com",
      "http://localhost:8571",
      "http://user@127.0.0.1",
      "http://127.0.0.1/path",
      "file:///etc/passwd",
      "http://127.0.0.1/?secret=x",
      "http://127.0.0.1/#fragment",
    ]) {
      globalThis.document = { querySelector: () => ({ content: broker }) };
      assert.throws(() => graftBrokerOrigin());
    }
  } finally {
    globalThis.document = previousDocument;
    globalThis.window = previousWindow;
  }
});

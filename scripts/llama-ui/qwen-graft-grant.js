const graftMutations = new Map([
	['graft_start_build', 'graft_start_build'],
	['graft_cancel_build', 'graft_cancel_build'],
	['qwen_graft_graft_start_build', 'graft_start_build'],
	['qwen_graft_graft_cancel_build', 'graft_cancel_build']
]);

/**
 * Present Graft's proposal fields to the model while the transport schema
 * continues to require the broker-owned grant at execution.
 *
 * @template {{type: string, function: {name: string, parameters: Record<string, unknown>}}} Tool
 * @param {Tool} definition
 * @returns {Tool}
 */
export function graftToolForModel(definition) {
	if (!graftMutations.has(definition.function.name)) return definition;

	// JSON serialization also accepts Svelte's reactive schema proxies.
	const projected = /** @type {Tool} */ (JSON.parse(JSON.stringify(definition)));
	const parameters = projected.function.parameters;
	const properties = parameters.properties;

	if (properties && typeof properties === 'object' && !Array.isArray(properties)) {
		parameters.properties = Object.fromEntries(
			Object.entries(properties).filter(([name]) => name !== 'authorization')
		);
	}

	if (Array.isArray(parameters.required)) {
		parameters.required = parameters.required.filter((name) => name !== 'authorization');
	}

	return projected;
}

/** Resolve the broker from served-page configuration, never from a shared URL. */
export function graftBrokerOrigin() {
	const configured =
		globalThis.document?.querySelector('meta[name="qwen-graft-broker-origin"]')?.content ||
		'http://127.0.0.1:8571';
	const broker = new URL(configured);

	if (
		!['http:', 'https:'].includes(broker.protocol) ||
		!['127.0.0.1', '[::1]'].includes(broker.hostname) ||
		broker.username ||
		broker.password ||
		broker.search ||
		broker.hash ||
		broker.pathname !== '/'
	) {
		throw new Error('The Graft approval broker must be a loopback HTTP origin.');
	}

	return broker.origin;
}

/**
 * Acquire one grant after the operator approves the exact Graft arguments.
 * Keep the grant in a fresh transport object; the agent retains its proposal.
 *
 * @param {string} toolName
 * @param {Record<string, unknown>} args
 * @param {Record<string, string>} authHeaders
 * @param {AbortSignal | undefined} signal
 * @param {{request?: typeof fetch, approve?: (message: string) => boolean}} options
 * @returns {Promise<Record<string, unknown>>}
 */
export async function authorizeGraftTool(toolName, args, authHeaders, signal, options = {}) {
	const canonicalTool = graftMutations.get(toolName);

	if (!canonicalTool) return args;

	signal?.throwIfAborted();

	if (Object.hasOwn(args, 'authorization')) {
		throw new Error('Graft authorization must come from the approval broker.');
	}

	const proposal = JSON.parse(JSON.stringify(args));
	const broker = graftBrokerOrigin();
	const approve = options.approve ?? ((message) => window.confirm(message));

	if (!approve(`Approve one ${toolName} call through ${broker}?\n\n${JSON.stringify(proposal, null, 2)}`)) {
		throw new Error('The operator declined the Graft operation.');
	}

	signal?.throwIfAborted();
	const request = options.request ?? globalThis.fetch.bind(globalThis);
	const sessionResponse = await request(`${broker}/session`, {
		cache: 'no-store',
		credentials: 'omit',
		headers: authHeaders,
		method: 'GET',
		mode: 'cors',
		redirect: 'error',
		signal
	});

	if (!sessionResponse.ok) {
		throw new Error(`The Graft broker refused the session: HTTP ${sessionResponse.status}.`);
	}

	const session = await sessionResponse.json();

	if (typeof session.session_secret !== 'string' || !session.session_secret) {
		throw new Error('The Graft broker returned an invalid session.');
	}

	const grantResponse = await request(`${broker}/grant-graft`, {
		body: JSON.stringify({ arguments: proposal, tool: canonicalTool }),
		cache: 'no-store',
		credentials: 'omit',
		headers: {
			'Content-Type': 'application/json',
			'X-Qwen-Web-Session': session.session_secret
		},
		method: 'POST',
		mode: 'cors',
		redirect: 'error',
		signal
	});

	if (!grantResponse.ok) {
		throw new Error(`The Graft broker refused the grant: HTTP ${grantResponse.status}.`);
	}

	const grant = await grantResponse.json();

	if (
		typeof grant.authorization !== 'string' ||
		!grant.authorization ||
		grant.authorization.length > 16384
	) {
		throw new Error('The Graft broker returned an invalid grant.');
	}

	signal?.throwIfAborted();

	return { ...proposal, authorization: grant.authorization };
}

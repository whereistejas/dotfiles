import { anthropicMessagesApi } from "@earendil-works/pi-ai/compat";
import { createProvider } from "@earendil-works/pi-ai/models";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { createTokenCache } from "./token-cache.mjs";

export default function (pi: ExtensionAPI) {
	const getToken = createTokenCache();

	pi.registerProvider(createProvider({
		id: "aigw",
		name: "AI Gateway",
		models: [],
		api: anthropicMessagesApi(),
		auth: {
			apiKey: {
				name: "Gateway token",
				check: async () => ({ type: "api_key", source: "aigw token" }),
				resolve: async ({ credential, signal }) => ({
					auth: { apiKey: credential?.key ?? await getToken(signal) },
					env: credential?.env,
					source: credential?.key ? "stored credential" : "aigw token",
				}),
			},
		},
	}));
}

import {
	createExecutionContext,
	waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src";

describe("Nimbus worker", () => {
	it("reports a missing D1 binding", async () => {
		const ctx = createExecutionContext();
		const response = await worker.fetch(new Request("http://example.com/health"), {}, ctx);
		await waitOnExecutionContext(ctx);
		expect(response.status).toBe(503);
		expect(await response.json()).toEqual({
			ok: false,
			error: "D1 binding nimbus_db is not configured.",
		});
	});

	it("returns the no-storm state when PAGASA has no stored update", async () => {
		const db = {
			prepare: () => ({ first: async () => null }),
		};
		const ctx = createExecutionContext();
		const response = await worker.fetch(
			new Request("http://example.com/api/pagasa"),
			{ nimbus_db: db },
			ctx,
		);
		await waitOnExecutionContext(ctx);
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			active: false,
			message: "No storm updates yet",
			updatedAt: null,
		});
	});
});

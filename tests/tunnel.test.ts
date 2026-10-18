import assert from "node:assert/strict";
import test from "node:test";
import { tunnelLaunch } from "../src/tunnel.js";

test("remote-managed tunnel uses environment token and needs no local config.yml", () => {
  const token = "test-token-not-a-secret";
  const launch = tunnelLaunch("C:\\missing\\config.yml", "chatgpt-local-agent-mcp", token);
  assert.equal(launch.mode, "remote");
  assert.deepEqual(launch.args, ["tunnel", "run"]);
  assert.equal(launch.extraEnv.TUNNEL_TOKEN, token);
  assert.ok(!launch.args.join(" ").includes(token));
  assert.ok(!launch.args.join(" ").includes("config.yml"));
});

test("locally-managed tunnel preserves config.yml compatibility", () => {
  const launch = tunnelLaunch("C:\\Users\\Test\\.cloudflared\\config.yml", "local-tunnel", undefined);
  assert.equal(launch.mode, "local");
  assert.deepEqual(launch.args, ["tunnel", "--config", "C:\\Users\\Test\\.cloudflared\\config.yml", "run", "local-tunnel"]);
  assert.deepEqual(launch.extraEnv, {});
});

test("blank token cannot enable remote mode", () => {
  assert.equal(tunnelLaunch("config.yml", "local", "   ").mode, "local");
});

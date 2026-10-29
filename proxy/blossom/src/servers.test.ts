import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mock, test } from "node:test";
import axios from "axios";
import { ServerRegistry, selectOwner, uploadBlob } from "./servers.js";

const activeStorage = {
  npub: "npub-storage",
  tunnelIp: "10.44.0.8",
  blossomPort: 3000,
};

test("ServerRegistry maps DB npubs and resolves legacy URLs", async () => {
  const registry = new ServerRegistry({
    listActiveStorages: async () => [activeStorage] as never,
  });

  await registry.refresh();
  assert.deepEqual(registry.candidates(), [
    { id: "npub-storage", url: "http://10.44.0.8:3000" },
  ]);
  for (const url of ["http://old", "https://old", "ws://old", "wss://old"]) {
    assert.equal(registry.resolve(url), url);
  }
});

test("ServerRegistry retains good state on failure and stays empty with no DB rows", async () => {
  let fail = false;
  const registry = new ServerRegistry({
    listActiveStorages: async () => {
      if (fail) throw new Error("unavailable");
      return [activeStorage] as never;
    },
  });

  await registry.refresh();
  fail = true;
  const errorLog = mock.method(console, "error", () => undefined);
  await registry.refresh();
  errorLog.mock.restore();
  assert.equal(registry.resolve("npub-storage"), "http://10.44.0.8:3000");

  // The DB is the only provider source: an empty roster is empty, never a
  // static URL list.
  const emptyRegistry = new ServerRegistry({
    listActiveStorages: async () => [] as never,
  });
  await emptyRegistry.refresh();
  assert.deepEqual(emptyRegistry.candidates(), []);
});

const candidates = [
  { id: "npub-carol", url: "http://10.44.0.3:3000" },
  { id: "npub-alice", url: "http://10.44.0.1:3000" },
  { id: "npub-bob", url: "http://10.44.0.2:3000" },
];

test("selectOwner is deterministic, time-seeded, and independent of candidate order", () => {
  // Fixed clock: fnv1a("npub:slot") mod 3 over [alice, bob, carol]:
  // slot 472222 -> alice, bob; slot 472227 -> alice -> carol.
  const first = 472222 * 3_600_000;
  const later = 472227 * 3_600_000;
  assert.equal(selectOwner("npub-alice", candidates, first)?.id, "npub-alice");
  assert.equal(selectOwner("npub-bob", candidates, first)?.id, "npub-bob");
  assert.equal(selectOwner("npub-alice", [...candidates].reverse(), first)?.id, "npub-alice");
  assert.equal(selectOwner("npub-alice", candidates, later)?.id, "npub-carol");
});

test("uploadBlob stores on the pk+time-selected provider and fails over by recomputing the selection", async () => {
  const now = 472227 * 3_600_000;
  const health = mock.method(axios, "get", async () => ({ status: 200 }));
  const put = mock.method(axios, "put", async (url: string) => {
    if (url.startsWith("http://10.44.0.3:3000")) {
      throw new Error("provider down");
    }
    return { status: 200 };
  });
  const warn = mock.method(console, "warn", () => undefined);
  const error = mock.method(console, "error", () => undefined);
  const registry = { freshCandidates: async () => [...candidates] };

  try {
    // npub-alice picks npub-carol (10.44.0.3) at this slot; after dropping it,
    // the 3 -> 2 recompute over the sorted pair picks npub-bob (10.44.0.2).
    const result = await uploadBlob(Buffer.from("blob"), "hash", "Nostr token", "npub-alice", registry, now, 1);
    assert.deepEqual(result, { hash: "hash", replicas: ["npub-bob"] });
    assert.deepEqual(put.mock.calls.map((call) => call.arguments[0]), [
      "http://10.44.0.3:3000/upload",
      "http://10.44.0.2:3000/upload",
    ]);
    assert.equal(warn.mock.callCount(), 1);
  } finally {
    health.mock.restore();
    put.mock.restore();
    warn.mock.restore();
    error.mock.restore();
  }
});

test("uploadBlob throws when no provider accepts and when the roster is empty", async () => {
  const health = mock.method(axios, "get", async () => ({ status: 200 }));
  const put = mock.method(axios, "put", async () => {
    throw new Error("provider down");
  });
  const error = mock.method(console, "error", () => undefined);

  try {
    await assert.rejects(
      uploadBlob(Buffer.from("blob"), "hash", "Nostr token", "npub-bob", { freshCandidates: async () => [...candidates] }, 0),
      /Failed to upload blob to any storage provider/,
    );
    assert.equal(put.mock.callCount(), 3);
    await assert.rejects(
      uploadBlob(Buffer.from("blob"), "hash", "Nostr token", "npub-bob", { freshCandidates: async () => [] }, 0),
      /No storage providers available/,
    );
  } finally {
    health.mock.restore();
    put.mock.restore();
    error.mock.restore();
  }
});

test("uploadBlob stores a second copy on a different provider", async () => {
  const now = 472227 * 3_600_000;
  const health = mock.method(axios, "get", async () => ({ status: 200 }));
  const put = mock.method(axios, "put", async () => ({ status: 200 }));
  const registry = { freshCandidates: async () => [...candidates] };

  try {
    const result = await uploadBlob(Buffer.from("blob"), "hash", "Nostr token", "npub-alice", registry, now, 2);
    assert.equal(result.replicas.length, 2);
    assert.notEqual(result.replicas[0], result.replicas[1]);
    assert.equal(put.mock.callCount(), 2);
  } finally {
    health.mock.restore();
    put.mock.restore();
  }
});

test("uploadBlob still succeeds with one copy when the second provider fails", async () => {
  const now = 472227 * 3_600_000;
  const health = mock.method(axios, "get", async () => ({ status: 200 }));
  let calls = 0;
  const put = mock.method(axios, "put", async () => {
    calls += 1;
    if (calls === 2) throw new Error("provider down");
    return { status: 200 };
  });
  const warn = mock.method(console, "warn", () => undefined);
  const error = mock.method(console, "error", () => undefined);
  const registry = { freshCandidates: async () => [candidates[0]!, candidates[1]!] };

  try {
    const result = await uploadBlob(Buffer.from("blob"), "hash", "Nostr token", "npub-alice", registry, now, 2);
    assert.equal(result.replicas.length, 1);
  } finally {
    health.mock.restore();
    put.mock.restore();
    warn.mock.restore();
    error.mock.restore();
  }
});

test("uploadBlob does not send bytes when every provider fails its readiness check", async () => {
  const health = mock.method(axios, "get", async () => {
    throw new Error("health endpoint unavailable");
  });
  const put = mock.method(axios, "put", async () => ({ status: 200 }));
  const error = mock.method(console, "error", () => undefined);

  try {
    await assert.rejects(
      uploadBlob(Buffer.from("blob"), "hash", "Nostr token", "npub-bob", { freshCandidates: async () => [...candidates] }, 0),
      /Failed to upload blob to any storage provider/,
    );
    assert.equal(health.mock.callCount(), 3);
    assert.equal(put.mock.callCount(), 0);
  } finally {
    health.mock.restore();
    put.mock.restore();
    error.mock.restore();
  }
});

test("uploadBlob skips a hanging health endpoint and uploads to the next provider", { timeout: 10_000 }, async () => {
  const requests: string[] = [];
  let uploaded: Buffer | undefined;
  const server = createServer((req, res) => {
    requests.push(`${req.method} ${req.url}`);
    // Accept the connection but never return headers: the probe must have a
    // real deadline, not merely wait for a socket to connect successfully.
    if (req.url?.startsWith("/stale/")) return;
    if (req.method === "GET" && req.url === "/ready/health") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"status":"ok"}');
      return;
    }
    if (req.method === "PUT" && req.url === "/ready/upload") {
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        uploaded = Buffer.concat(chunks);
        res.writeHead(201);
        res.end("{}");
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const origin = `http://127.0.0.1:${address.port}`;
  const roster = [
    { id: "npub-one", url: origin },
    { id: "npub-two", url: origin },
  ];
  const first = selectOwner("npub-alice", roster, 0)!;
  for (const candidate of roster) candidate.url += candidate === first ? "/stale" : "/ready";
  const warn = mock.method(console, "warn", () => undefined);
  const error = mock.method(console, "error", () => undefined);

  try {
    const blob = Buffer.from("upload after bounded readiness probe");
    const result = await uploadBlob(blob, "hash", "Nostr token", "npub-alice", { freshCandidates: async () => [...roster] }, 0, 1);
    assert.deepEqual(result.replicas, [roster.find((candidate) => candidate !== first)!.id]);
    assert.deepEqual(uploaded, blob);
    assert.deepEqual(requests, ["GET /stale/health", "GET /ready/health", "PUT /ready/upload"]);
  } finally {
    warn.mock.restore();
    error.mock.restore();
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
  }
});

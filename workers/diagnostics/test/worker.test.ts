import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import fixtures from "../../../Shared/Diagnostics/secret-scan-fixtures.json";
import { adminListSummary, adminURLForBaseURL, diagnosticsNotificationPayload, notificationSummary } from "../src/index";
import { scanForSecrets } from "../src/secretScan";

const uploadHeaders = {
  "content-type": "application/json; charset=utf-8",
  "x-toastty-diagnostics-key": "test-upload-key"
};

const adminHeaders = {
  "x-toastty-admin-key": "test-admin-key"
};

describe("diagnostics worker", () => {
  it("stores a report and retrieves it by admin key", async () => {
    const response = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: uploadHeaders,
      body: JSON.stringify(makeBundle())
    });

    expect(response.status).toBe(201);
    const submitted = await response.json() as { reportID: string; receivedAtMs: number; expiresAtMs: number };
    expect(submitted.reportID).toMatch(/^TT-[0-9]{8}-[A-Z2-9]{16}$/);

    const stored = await env.DIAGNOSTICS_BUCKET.get(objectKeyForReportID(submitted.reportID));
    expect(stored).not.toBeNull();

    const retrieved = await SELF.fetch(`https://diagnostics.test/v1/diagnostics/${submitted.reportID}`, {
      method: "GET",
      headers: adminHeaders
    });
    expect(retrieved.status).toBe(200);
    const envelope = await retrieved.json() as {
      reportID: string;
      summary: { socketState?: string; redactionRulesVersion: number };
      bundle: { schemaVersion: number; automation?: { recentRequests?: unknown[] } };
    };
    expect(envelope.reportID).toBe(submitted.reportID);
    expect(envelope.summary.socketState).toBe("healthy");
    expect(envelope.summary.redactionRulesVersion).toBe(1);
    expect(envelope.bundle.schemaVersion).toBe(1);
    expect(envelope.bundle.automation?.recentRequests).toHaveLength(1);
  });

  it("lists recent reports by admin key without returning bundles", async () => {
    const first = await submitBundle(makeBundle({
      note: "tab switched unexpectedly; contact: user@example.com",
      runtimeLabel: "toastty-alpha"
    }));
    const second = await submitBundle(makeBundle({
      note: "socket failed after automation",
      runtimeLabel: "toastty-beta"
    }));

    const response = await SELF.fetch("https://diagnostics.test/v1/diagnostics?limit=10", {
      method: "GET",
      headers: adminHeaders
    });

    expect(response.status).toBe(200);
    const listed = await response.json() as {
      count: number;
      limit: number;
      scannedObjectCount: number;
      incomplete: boolean;
      reports: Array<{
        reportID: string;
        receivedAtMs: number;
        expiresAtMs: number;
        adminURL?: string;
        summary?: {
          runtimeLabel?: string;
          notePreview?: string;
          secretScanFindingCount?: number;
          secretScanFindings?: unknown[];
        };
        bundle?: unknown;
        logs?: unknown;
      }>;
    };
    expect(listed.limit).toBe(10);
    expect(listed.count).toBeGreaterThanOrEqual(2);
    expect(listed.scannedObjectCount).toBeGreaterThanOrEqual(2);
    expect(listed.incomplete).toBe(false);

    const reportsByID = new Map(listed.reports.map((report) => [report.reportID, report]));
    const firstListed = reportsByID.get(first.reportID);
    const secondListed = reportsByID.get(second.reportID);
    expect(firstListed).toBeDefined();
    expect(secondListed).toBeDefined();
    expect(firstListed?.adminURL).toBe(`https://diagnostics.test/v1/diagnostics/${first.reportID}`);
    expect(firstListed?.summary?.runtimeLabel).toBe("toastty-alpha");
    expect(firstListed?.summary?.notePreview).toContain("user@example.com");
    expect(firstListed?.summary?.secretScanFindingCount).toBe(0);
    expect(firstListed?.summary?.secretScanFindings).toBeUndefined();
    expect(firstListed?.bundle).toBeUndefined();
    expect(firstListed?.logs).toBeUndefined();
  });

  it("limits and validates report listing requests", async () => {
    await submitBundle(makeBundle({ runtimeLabel: "limit-one" }));
    await submitBundle(makeBundle({ runtimeLabel: "limit-two" }));

    const limited = await SELF.fetch("https://diagnostics.test/v1/diagnostics?limit=1", {
      method: "GET",
      headers: adminHeaders
    });
    expect(limited.status).toBe(200);
    const listed = await limited.json() as { count: number; reports: unknown[] };
    expect(listed.count).toBe(1);
    expect(listed.reports).toHaveLength(1);

    const invalid = await SELF.fetch("https://diagnostics.test/v1/diagnostics?limit=0", {
      method: "GET",
      headers: adminHeaders
    });
    expect(invalid.status).toBe(400);

    const tooLarge = await SELF.fetch("https://diagnostics.test/v1/diagnostics?limit=101", {
      method: "GET",
      headers: adminHeaders
    });
    expect(tooLarge.status).toBe(400);

    const unauthorized = await SELF.fetch("https://diagnostics.test/v1/diagnostics?limit=1", {
      method: "GET"
    });
    expect(unauthorized.status).toBe(401);
  });

  it("requires upload and admin keys", async () => {
    const upload = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(makeBundle())
    });
    expect(upload.status).toBe(401);

    const admin = await SELF.fetch("https://diagnostics.test/v1/diagnostics/TT-20260628-ABCDEFGHJKLMNPQ", {
      method: "GET"
    });
    expect(admin.status).toBe(401);
  });

  it("accepts older bundles without automation diagnostics", async () => {
    const bundle = makeBundle();
    delete (bundle as { automation?: unknown }).automation;

    const response = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: uploadHeaders,
      body: JSON.stringify(bundle)
    });

    expect(response.status).toBe(201);
    const submitted = await response.json() as { reportID: string };
    const retrieved = await SELF.fetch(`https://diagnostics.test/v1/diagnostics/${submitted.reportID}`, {
      method: "GET",
      headers: adminHeaders
    });
    expect(retrieved.status).toBe(200);
    const envelope = await retrieved.json() as { bundle: { automation?: unknown } };
    expect(envelope.bundle.automation).toBeUndefined();
  });

  it("rejects oversized streamed bodies before JSON parsing", async () => {
    const response = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: {
        ...uploadHeaders,
        "content-length": "15000001"
      },
      body: "{}"
    });
    expect(response.status).toBe(413);
  });

  it("rejects oversized bodies while streaming when content-length is absent", async () => {
    const largeBody = new Uint8Array(15_000_001);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(largeBody);
        controller.close();
      }
    });
    const request = new Request("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: uploadHeaders,
      body: stream
    });

    const response = await SELF.fetch(request);

    expect(response.status).toBe(413);
  });

  it("rejects secret scan findings unless the override header is present", async () => {
    const bundle = makeBundle();
    bundle.logs.current.content = "leaked sk-test_abcdefghijklmnopqrstuvwxyz";

    const rejected = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: uploadHeaders,
      body: JSON.stringify(bundle)
    });
    expect(rejected.status).toBe(422);

    const accepted = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: {
        ...uploadHeaders,
        "x-toastty-secret-scan-override": "1"
      },
      body: JSON.stringify(bundle)
    });
    expect(accepted.status).toBe(201);
  });

  it("runs the secret scan before JSON parsing", async () => {
    const response = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
      method: "POST",
      headers: uploadHeaders,
      body: "sk-test_abcdefghijklmnopqrstuvwxyz {"
    });

    expect(response.status).toBe(422);
  });

  it("keeps secret scanner behavior aligned with shared fixtures", () => {
    for (const fixture of fixtures.positive) {
      const findings = scanForSecrets(fixture.text);
      expect(findings.map((finding) => finding.ruleID), fixture.name).toEqual(
        fixture.expectedFindings.map((finding) => finding.ruleID)
      );
      expect(findings.map((finding) => finding.matchCount), fixture.name).toEqual(
        fixture.expectedFindings.map((finding) => finding.matchCount)
      );
    }
    for (const fixture of fixtures.negative) {
      expect(scanForSecrets(fixture.text), fixture.name).toHaveLength(0);
    }
  });

  it("omits freeform bundle content from notification summaries", () => {
    const summary = notificationSummary({
      appVersion: "1.0",
      build: "100",
      runtimeLabel: "toastty-test",
      socketState: "healthy",
      redactionRulesVersion: 1,
      redactedKeyCount: 2,
      notePreview: "freeform user note",
      systemArch: "arm64",
      hardwareModel: "Mac16,1",
      secretScanOverride: true,
      secretScanFindings: [{ ruleID: "openai-token", label: "OpenAI-style API token", matchCount: 1 }]
    });

    expect("notePreview" in summary).toBe(false);
    expect("secretScanFindings" in summary).toBe(false);
    expect(summary.secretScanFindingCount).toBe(1);
  });

  it("keeps note preview but omits secret finding details from admin list summaries", () => {
    const summary = adminListSummary({
      appVersion: "1.0",
      build: "100",
      runtimeLabel: "toastty-test",
      socketState: "healthy",
      redactionRulesVersion: 1,
      redactedKeyCount: 2,
      notePreview: "contact: user@example.com",
      systemArch: "arm64",
      hardwareModel: "Mac16,1",
      secretScanOverride: true,
      secretScanFindings: [{ ruleID: "openai-token", label: "OpenAI-style API token", matchCount: 1 }]
    });

    expect(summary?.notePreview).toBe("contact: user@example.com");
    expect("secretScanFindings" in (summary ?? {})).toBe(false);
    expect(summary?.secretScanFindingCount).toBe(1);
  });

  it("builds actionable notification payloads without freeform bundle content", () => {
    const reportID = "TT-20260628-ABCDEFGHJKLMNPQR";
    const payload = diagnosticsNotificationPayload(
      reportID,
      "https://diagnostics.example.com/v1/diagnostics/TT-20260628-ABCDEFGHJKLMNPQR",
      {
        appVersion: "1.0",
        build: "100",
        runtimeLabel: "toastty-test",
        socketState: "healthy",
        redactionRulesVersion: 1,
        redactedKeyCount: 2,
        notePreview: "freeform user note",
        systemArch: "arm64",
        hardwareModel: "Mac16,1",
        secretScanOverride: false,
        secretScanFindings: []
      }
    );

    expect(payload.type).toBe("toastty.diagnostics.submitted");
    expect(payload.reportID).toBe(reportID);
    expect(payload.adminURL).toBe("https://diagnostics.example.com/v1/diagnostics/TT-20260628-ABCDEFGHJKLMNPQR");
    expect(payload.skillPrompt).toBe(
      "Use $toastty-diagnostics to fetch and summarize TT-20260628-ABCDEFGHJKLMNPQR."
    );
    expect("notePreview" in payload.summary).toBe(false);
    expect("secretScanFindings" in payload.summary).toBe(false);
  });

  it("omits adminURL from notification payloads when no trusted base URL is configured", () => {
    const payload = diagnosticsNotificationPayload(
      "TT-20260628-ABCDEFGHJKLMNPQR",
      undefined,
      {
        redactionRulesVersion: 1,
        redactedKeyCount: 0,
        secretScanOverride: false,
        secretScanFindings: []
      }
    );

    expect("adminURL" in payload).toBe(false);
    expect(payload.reportID).toBe("TT-20260628-ABCDEFGHJKLMNPQR");
    expect(payload.summary.secretScanFindingCount).toBe(0);
  });

  it("builds admin URLs from a trusted base URL instead of request host data", () => {
    const reportID = "TT-20260628-ABCDEFGHJKLMNPQR";

    expect(adminURLForBaseURL("https://diagnostics.example.com", reportID)).toBe(
      "https://diagnostics.example.com/v1/diagnostics/TT-20260628-ABCDEFGHJKLMNPQR"
    );
    expect(adminURLForBaseURL("https://diagnostics.example.com/support?ignored=1#frag", reportID)).toBe(
      "https://diagnostics.example.com/support/v1/diagnostics/TT-20260628-ABCDEFGHJKLMNPQR"
    );
    expect(adminURLForBaseURL("https://diagnostics.example.com/v1/diagnostics/", reportID)).toBe(
      "https://diagnostics.example.com/v1/diagnostics/TT-20260628-ABCDEFGHJKLMNPQR"
    );
    expect(adminURLForBaseURL("not a url", reportID)).toBeUndefined();
  });
});

async function submitBundle(bundle: ReturnType<typeof makeBundle>): Promise<{ reportID: string }> {
  const response = await SELF.fetch("https://diagnostics.test/v1/diagnostics", {
    method: "POST",
    headers: uploadHeaders,
    body: JSON.stringify(bundle)
  });
  expect(response.status).toBe(201);
  return await response.json() as { reportID: string };
}

function makeBundle(overrides: { note?: string; runtimeLabel?: string } = {}) {
  return {
    schemaVersion: 1,
    generatedAtMs: 1_800_000_000_000,
    note: overrides.note ?? "terminal didn't connect",
    app: {
      shortVersion: "1.0",
      build: "100",
      runtimeLabel: overrides.runtimeLabel ?? "toastty-test"
    },
    logs: {
      current: {
        exists: true,
        path: "/Users/vishal/Library/Logs/Toastty/toastty.log",
        sizeBytes: 12,
        truncated: false,
        content: "socket healthy"
      },
      previous: {
        exists: false,
        path: "/Users/vishal/Library/Logs/Toastty/toastty.previous.log",
        truncated: false
      },
      configSummary: {}
    },
    shell: {
      detectedShells: [],
      shimDirectory: {
        exists: true,
        path: "/Users/vishal/.toastty/bin",
        entries: []
      },
      environment: [],
      otherEnvironmentNames: []
    },
    socket: {
      state: "healthy",
      socketPath: "/tmp/toastty-501/events-v1.sock"
    },
    automation: {
      status: {
        status: "available"
      },
      recentRequests: [
        {
          timestampMs: 1_800_000_000_000,
          kind: "request",
          requestID: "req-1",
          command: "app_control.run_action",
          callerSessionID: "sess-1",
          callerAgent: "codex",
          actionID: "workspace.select",
          argumentKeys: ["focusUnreadSessionPanel", "workspaceID"],
          selectors: {
            workspaceID: "workspace-1"
          },
          flags: {
            focusUnreadSessionPanel: false
          },
          ok: true,
          durationMs: 3
        }
      ]
    },
    system: {
      arch: "arm64",
      hardwareModel: "Mac16,1",
      macosVersion: "Version 15.0"
    },
    redaction: {
      rulesVersion: 1,
      redactedKeyCount: 1
    },
    probe: {
      shellProbePath: null,
      rawShellProbe: null,
      readError: null
    }
  };
}

function objectKeyForReportID(reportID: string): string {
  const date = reportID.slice(3, 11);
  return `reports/${date.slice(0, 4)}/${date.slice(4, 6)}/${date.slice(6, 8)}/${reportID}.json`;
}

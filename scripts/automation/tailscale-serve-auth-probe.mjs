#!/usr/bin/env node

import { createHash, randomBytes } from "node:crypto";
import { constants as fsConstants, writeFileSync } from "node:fs";
import { access, mkdir, writeFile } from "node:fs/promises";
import { createServer, request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { connect as connectTCP } from "node:net";
import { delimiter, join } from "node:path";
import { spawnSync } from "node:child_process";
import { connect as connectTLS } from "node:tls";

const RESULT_FILE_NAME = "tailscale-serve-auth-probe-result.json";
const HTTPS_PORT_CANDIDATES = Object.freeze([10_443, 11_443, 12_443, 13_443, 14_443]);
const REQUEST_TIMEOUT_MS = 15_000;
const CLEANUP_COMMAND_TIMEOUT_MS = 5_000;
const DEFAULT_WATCHDOG_TIMEOUT_MS = 90_000;

// Numeric-only failure categories keep even failed probe artifacts free of
// hostnames, identities, credentials, filesystem paths, and command output.
const FailureCode = Object.freeze({
  none: 0,
  outputUnavailable: 10,
  unsafeDebugEnvironment: 11,
  tailscaleCLIUnavailable: 20,
  statusUnavailable: 21,
  safeHTTPSPortUnavailable: 22,
  dnsNameUnavailable: 23,
  serveConfigurationFailed: 24,
  restRequestFailed: 25,
  webSocketRequestFailed: 26,
  observationFailed: 27,
  cleanupFailed: 28,
  internalFailure: 29,
  testInjectedFailure: 90,
});

function makeResult() {
  return {
    schemaVersion: 1,
    testMode,
    probeSucceeded: false,
    restRequestCount: 0,
    restAuthorizationHeaderCount: 0,
    restAuthorizationUnchanged: false,
    restIdentityHeaderCount: 0,
    restIdentityPresent: false,
    webSocketUpgradeCount: 0,
    webSocketAuthorizationHeaderCount: 0,
    webSocketAuthorizationUnchanged: false,
    webSocketIdentityHeaderCount: 0,
    webSocketIdentityPresent: false,
    webSocketClientSawSwitchingProtocols: false,
    restTLSVerified: false,
    webSocketTLSVerified: false,
    ignoredRequestCount: 0,
    serveConfigureCommandSucceeded: false,
    serveMappingConfigured: false,
    serveOwnedTargetOccurrenceCount: 0,
    serveTotalTargetOccurrenceCount: 0,
    serveResidualMatchesBaseline: false,
    serveMappingRemoved: false,
    serveConfigurationRestored: false,
    funnelMatchesBaselineAtConfigure: false,
    funnelConfigurationUnchanged: false,
    listenerClosed: false,
    failureCode: FailureCode.none,
  };
}

const artifactsDirectory = process.env.TOASTTY_ARTIFACTS_DIR ?? "";
const testMode = process.env.TOASTTY_TAILSCALE_PROBE_TEST_MODE === "1";
const result = makeResult();
let resultPath = "";
let tailscaleCLI = "";
let selectedHTTPSPort = 0;
let mappingMayExist = false;
let expectedServeTarget = "";
let expectedServeHostPort = "";
let server;
let serveStatusBefore;
let funnelStatusBefore;
let cleanupStarted = false;
let resultWritten = false;
const serverSockets = new Set();
let watchdog;
let emergencyExiting = false;

class ProbeFailure extends Error {
  constructor(code) {
    super("probe failed");
    this.code = code;
  }
}

function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function selectedHostPortEntries(record, port) {
  if (!isRecord(record)) return [];
  const portText = String(port);
  return Object.entries(record).filter(([key]) => key.endsWith(`:${portText}`));
}

function statusUsesSelectedPort(status, port) {
  if (!isRecord(status)) return false;
  const portText = String(port);
  return (isRecord(status.TCP) && Object.hasOwn(status.TCP, portText))
    || selectedHostPortEntries(status.Web, port).length > 0
    || selectedHostPortEntries(status.AllowFunnel, port).some(([, allowed]) => Boolean(allowed));
}

function countExactString(value, expected) {
  if (Array.isArray(value)) {
    return value.reduce((count, entry) => count + countExactString(entry, expected), 0);
  }
  if (value !== null && typeof value === "object") {
    return Object.values(value).reduce(
      (count, entry) => count + countExactString(entry, expected),
      0,
    );
  }
  return value === expected ? 1 : 0;
}

function selectedServeTargetOccurrenceCount(status, port, expected) {
  if (!isRecord(status)) return 0;
  const portText = String(port);
  const tcpEntry = isRecord(status.TCP) ? status.TCP[portText] : undefined;
  const selectedWebEntries = selectedHostPortEntries(status.Web, port);
  const selectedAllowFunnelEntries = selectedHostPortEntries(status.AllowFunnel, port);
  return countExactString(tcpEntry, expected)
    + selectedWebEntries.reduce((count, [, entry]) => count + countExactString(entry, expected), 0)
    + selectedAllowFunnelEntries.reduce(
      (count, [, entry]) => count + countExactString(entry, expected),
      0,
    );
}

function normalizedStatusWithoutSelectedPort(status, port) {
  if (!isRecord(status)) return status;
  const portText = String(port);
  const normalized = { ...status };

  if (isRecord(status.TCP)) {
    const tcp = Object.fromEntries(
      Object.entries(status.TCP).filter(([key]) => key !== portText),
    );
    if (Object.keys(tcp).length > 0) {
      normalized.TCP = tcp;
    } else {
      delete normalized.TCP;
    }
  }

  if (isRecord(status.Web)) {
    const web = Object.fromEntries(
      Object.entries(status.Web).filter(([key]) => !key.endsWith(`:${portText}`)),
    );
    if (Object.keys(web).length > 0) {
      normalized.Web = web;
    } else {
      delete normalized.Web;
    }
  }

  if (isRecord(status.AllowFunnel)) {
    const allowFunnel = Object.fromEntries(
      Object.entries(status.AllowFunnel).filter(([key, allowed]) => (
        !key.endsWith(`:${portText}`) || Boolean(allowed)
      )),
    );
    if (Object.keys(allowFunnel).length > 0) {
      normalized.AllowFunnel = allowFunnel;
    } else {
      delete normalized.AllowFunnel;
    }
  }

  return normalized;
}

function selectedServeMappingIsExclusive(status) {
  if (!isRecord(status) || !expectedServeHostPort) return false;
  const portText = String(selectedHTTPSPort);
  const tcpEntry = isRecord(status.TCP) ? status.TCP[portText] : undefined;
  const selectedWebEntries = selectedHostPortEntries(status.Web, selectedHTTPSPort);
  const selectedAllowFunnelEntries = selectedHostPortEntries(
    status.AllowFunnel,
    selectedHTTPSPort,
  );
  const expectedTCPEntry = { HTTPS: true };
  const expectedWebEntry = { Handlers: { "/": { Proxy: expectedServeTarget } } };
  return canonicalJSON(tcpEntry) === canonicalJSON(expectedTCPEntry)
    && selectedWebEntries.length === 1
    && selectedWebEntries[0][0] === expectedServeHostPort
    && canonicalJSON(selectedWebEntries[0][1]) === canonicalJSON(expectedWebEntry)
    && selectedAllowFunnelEntries.every(([, allowed]) => !Boolean(allowed));
}

function configuredStatusIsOwned(configuredServeStatus, configuredFunnelStatus) {
  const ownedTargetCount = selectedServeTargetOccurrenceCount(
    configuredServeStatus,
    selectedHTTPSPort,
    expectedServeTarget,
  );
  const totalTargetCount = countExactString(configuredServeStatus, expectedServeTarget);
  const residualMatchesBaseline = (
    canonicalJSON(normalizedStatusWithoutSelectedPort(configuredServeStatus, selectedHTTPSPort))
      === canonicalJSON(normalizedStatusWithoutSelectedPort(serveStatusBefore, selectedHTTPSPort))
  );
  const funnelMatchesBaseline = (
    canonicalJSON(normalizedStatusWithoutSelectedPort(configuredFunnelStatus, selectedHTTPSPort))
      === canonicalJSON(normalizedStatusWithoutSelectedPort(funnelStatusBefore, selectedHTTPSPort))
  );
  result.serveOwnedTargetOccurrenceCount = ownedTargetCount;
  result.serveTotalTargetOccurrenceCount = totalTargetCount;
  result.serveResidualMatchesBaseline = residualMatchesBaseline;
  result.funnelMatchesBaselineAtConfigure = funnelMatchesBaseline;
  return ownedTargetCount >= 1
    && totalTargetCount === ownedTargetCount
    && residualMatchesBaseline
    && funnelMatchesBaseline
    && selectedServeMappingIsExclusive(configuredServeStatus);
}

function runTailscale(argumentsList, timeout = REQUEST_TIMEOUT_MS) {
  const completed = spawnSync(tailscaleCLI, argumentsList, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout,
  });
  if (completed.status !== 0 || completed.error) {
    throw new ProbeFailure(FailureCode.statusUnavailable);
  }
  return completed.stdout;
}

function readJSONStatus(argumentsList, timeout = REQUEST_TIMEOUT_MS) {
  try {
    return JSON.parse(runTailscale(argumentsList, timeout));
  } catch (error) {
    if (error instanceof ProbeFailure) {
      throw error;
    }
    throw new ProbeFailure(FailureCode.statusUnavailable);
  }
}

async function isExecutable(path) {
  try {
    await access(path, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function resolveTailscaleCLI() {
  const override = process.env.TOASTTY_TAILSCALE_CLI;
  if (override) {
    return await isExecutable(override) ? override : "";
  }

  const candidates = (process.env.PATH ?? "")
    .split(delimiter)
    .filter(Boolean)
    .map((directory) => join(directory, "tailscale"));
  candidates.push("/Applications/Tailscale.app/Contents/MacOS/Tailscale");
  for (const candidate of candidates) {
    if (await isExecutable(candidate)) {
      return candidate;
    }
  }
  return "";
}

function rawHeaderValues(rawHeaders, requestedName) {
  const values = [];
  for (let index = 0; index + 1 < rawHeaders.length; index += 2) {
    if (rawHeaders[index].toLowerCase() === requestedName) {
      values.push(rawHeaders[index + 1]);
    }
  }
  return values;
}

function observeHeaders(rawHeaders, expectedAuthorization, prefix) {
  const authorizationValues = rawHeaderValues(rawHeaders, "authorization");
  const identityValues = rawHeaderValues(rawHeaders, "tailscale-user-login");
  result[`${prefix}AuthorizationHeaderCount`] = authorizationValues.length;
  result[`${prefix}AuthorizationUnchanged`] = (
    authorizationValues.length === 1
      && authorizationValues[0] === expectedAuthorization
  );
  result[`${prefix}IdentityHeaderCount`] = identityValues.length;
  result[`${prefix}IdentityPresent`] = (
    identityValues.length === 1
      && identityValues[0].length > 0
      && identityValues[0] === identityValues[0].trim()
  );
}

function createProbeServer(expectedAuthorization, probePaths) {
    const probeServer = createServer((request, response) => {
    if (request.url !== probePaths.rest) {
      result.ignoredRequestCount += 1;
      response.writeHead(404).end();
      return;
    }
    result.restRequestCount += 1;
    observeHeaders(request.rawHeaders, expectedAuthorization, "rest");
    response.writeHead(204).end();
  });

  probeServer.on("upgrade", (request, socket) => {
    if (request.url !== probePaths.webSocket) {
      result.ignoredRequestCount += 1;
      socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      return;
    }
    result.webSocketUpgradeCount += 1;
    observeHeaders(request.rawHeaders, expectedAuthorization, "webSocket");

    const keyValues = rawHeaderValues(request.rawHeaders, "sec-websocket-key");
    if (keyValues.length !== 1) {
      socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
      return;
    }
    const accept = createHash("sha1")
      .update(`${keyValues[0]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    socket.end(
      "HTTP/1.1 101 Switching Protocols\r\n"
        + "Upgrade: websocket\r\n"
        + "Connection: Upgrade\r\n"
        + `Sec-WebSocket-Accept: ${accept}\r\n`
        + "\r\n",
    );
  });
  probeServer.on("connection", (socket) => {
    serverSockets.add(socket);
    socket.once("close", () => serverSockets.delete(socket));
  });
  return probeServer;
}

function listenOnLoopback(probeServer) {
  return new Promise((resolve, reject) => {
    const onError = () => reject(new ProbeFailure(FailureCode.internalFailure));
    probeServer.once("error", onError);
    probeServer.listen(0, "127.0.0.1", () => {
      probeServer.off("error", onError);
      const address = probeServer.address();
      if (!address || typeof address === "string") {
        reject(new ProbeFailure(FailureCode.internalFailure));
        return;
      }
      resolve(address.port);
    });
  });
}

function closeServer(probeServer) {
  for (const socket of serverSockets) {
    socket.destroy();
  }
  serverSockets.clear();
  if (!probeServer?.listening) {
    result.listenerClosed = true;
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const hardStop = setTimeout(() => {
      result.listenerClosed = !probeServer.listening;
      resolve();
    }, CLEANUP_COMMAND_TIMEOUT_MS);
    probeServer.close(() => {
      clearTimeout(hardStop);
      result.listenerClosed = true;
      resolve();
    });
  });
}

function restRequest(hostname, httpsPort, backendPort, expectedAuthorization, probePaths) {
  return new Promise((resolve, reject) => {
    const options = testMode
      ? {
          hostname: "127.0.0.1",
          port: backendPort,
          path: probePaths.rest,
          method: "GET",
          headers: {
            Authorization: expectedAuthorization,
            "Tailscale-User-Login": "test-identity",
          },
        }
      : {
          hostname,
          port: httpsPort,
          path: probePaths.rest,
          method: "GET",
          headers: { Authorization: expectedAuthorization },
        };
    const request = (testMode ? httpRequest : httpsRequest)(options, (response) => {
      response.resume();
      response.once("end", () => {
        if (response.statusCode === 204) {
          result.restTLSVerified = !testMode;
          resolve();
        } else {
          reject(new ProbeFailure(FailureCode.restRequestFailed));
        }
      });
    });
    request.setTimeout(REQUEST_TIMEOUT_MS, () => request.destroy());
    request.once("error", () => reject(new ProbeFailure(FailureCode.restRequestFailed)));
    request.end();
  });
}

function webSocketRequest(hostname, httpsPort, backendPort, expectedAuthorization, probePaths) {
  return new Promise((resolve, reject) => {
    const webSocketKey = randomBytes(16).toString("base64");
    const socket = testMode
      ? connectTCP({ host: "127.0.0.1", port: backendPort })
      : connectTLS({ host: hostname, port: httpsPort, servername: hostname });
    let responseHead = "";
    let settled = false;
    const settle = (error) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      if (error) reject(error);
      else resolve();
    };
    socket.setTimeout(REQUEST_TIMEOUT_MS, () => settle(new ProbeFailure(FailureCode.webSocketRequestFailed)));
    socket.once("error", () => settle(new ProbeFailure(FailureCode.webSocketRequestFailed)));
    socket.on("data", (chunk) => {
      responseHead += chunk.toString("ascii");
      if (responseHead.length > 8_192) {
        settle(new ProbeFailure(FailureCode.webSocketRequestFailed));
        return;
      }
      if (responseHead.includes("\r\n\r\n")) {
        result.webSocketClientSawSwitchingProtocols = responseHead.startsWith("HTTP/1.1 101 ");
        settle(result.webSocketClientSawSwitchingProtocols
          ? undefined
          : new ProbeFailure(FailureCode.webSocketRequestFailed));
      }
    });
    socket.once(testMode ? "connect" : "secureConnect", () => {
      result.webSocketTLSVerified = !testMode;
      const identityHeader = testMode ? "Tailscale-User-Login: test-identity\r\n" : "";
      socket.write(
        `GET ${probePaths.webSocket} HTTP/1.1\r\n`
          + `Host: ${hostname}:${httpsPort}\r\n`
          + "Upgrade: websocket\r\n"
          + "Connection: Upgrade\r\n"
          + "Sec-WebSocket-Version: 13\r\n"
          + `Sec-WebSocket-Key: ${webSocketKey}\r\n`
          + `Authorization: ${expectedAuthorization}\r\n`
          + identityHeader
          + "\r\n",
      );
    });
  });
}

function validateHostname(status) {
  const rawName = status?.Self?.DNSName;
  if (typeof rawName !== "string") return "";
  const hostname = rawName.endsWith(".") ? rawName.slice(0, -1) : rawName;
  return /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.ts\.net$/i.test(hostname) ? hostname : "";
}

function selectHTTPSPort(serveStatus, funnelStatus) {
  const override = process.env.TOASTTY_TAILSCALE_PROBE_HTTPS_PORT;
  const candidates = override ? [Number(override)] : HTTPS_PORT_CANDIDATES;
  for (const port of candidates) {
    if (Number.isSafeInteger(port)
      && port >= 1_024
      && port <= 65_535
      && !statusUsesSelectedPort(serveStatus, port)
      && !statusUsesSelectedPort(funnelStatus, port)) {
      return port;
    }
  }
  return 0;
}

function configureServe(backendPort, hostname) {
  expectedServeTarget = `http://127.0.0.1:${backendPort}`;
  expectedServeHostPort = `${hostname}:${selectedHTTPSPort}`;
  let serveStatusImmediatelyBeforeConfigure;
  let funnelStatusImmediatelyBeforeConfigure;
  try {
    serveStatusImmediatelyBeforeConfigure = readJSONStatus(["serve", "status", "--json"]);
    funnelStatusImmediatelyBeforeConfigure = readJSONStatus(["funnel", "status", "--json"]);
  } catch {
    throw new ProbeFailure(FailureCode.serveConfigurationFailed);
  }
  if (canonicalJSON(serveStatusImmediatelyBeforeConfigure) !== canonicalJSON(serveStatusBefore)
    || canonicalJSON(funnelStatusImmediatelyBeforeConfigure) !== canonicalJSON(funnelStatusBefore)
    || statusUsesSelectedPort(serveStatusImmediatelyBeforeConfigure, selectedHTTPSPort)
    || statusUsesSelectedPort(funnelStatusImmediatelyBeforeConfigure, selectedHTTPSPort)) {
    throw new ProbeFailure(FailureCode.serveConfigurationFailed);
  }

  // A failed or timed-out CLI can still mutate Serve state. From this point on,
  // cleanup must inspect the selected port regardless of the reported exit.
  mappingMayExist = true;
  const configured = spawnSync(tailscaleCLI, [
    "serve",
    "--bg",
    "--yes",
    `--https=${selectedHTTPSPort}`,
    `http://127.0.0.1:${backendPort}`,
  ], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: REQUEST_TIMEOUT_MS,
  });
  const configureReportedSuccess = configured.status === 0 && !configured.error;
  result.serveConfigureCommandSucceeded = configureReportedSuccess;
  let configuredServeStatus;
  let configuredFunnelStatus;
  try {
    configuredServeStatus = readJSONStatus(["serve", "status", "--json"]);
    configuredFunnelStatus = readJSONStatus(["funnel", "status", "--json"]);
  } catch {
    throw new ProbeFailure(FailureCode.serveConfigurationFailed);
  }
  result.serveMappingConfigured = configureReportedSuccess
    && configuredStatusIsOwned(configuredServeStatus, configuredFunnelStatus);
  if (!result.serveMappingConfigured) {
    throw new ProbeFailure(FailureCode.serveConfigurationFailed);
  }
}

function cleanupServeSynchronously({ attempts = 3, verify = true } = {}) {
  if (cleanupStarted) return;
  cleanupStarted = true;

  if (mappingMayExist && tailscaleCLI && selectedHTTPSPort) {
    for (let attempt = 0; attempt < attempts && !result.serveMappingRemoved; attempt += 1) {
      let liveServeStatus;
      try {
        liveServeStatus = readJSONStatus(
          ["serve", "status", "--json"],
          CLEANUP_COMMAND_TIMEOUT_MS,
        );
      } catch {
        break;
      }
      if (!statusUsesSelectedPort(liveServeStatus, selectedHTTPSPort)) {
        mappingMayExist = false;
        result.serveMappingRemoved = true;
        break;
      }
      // `serve ... off` removes the whole selected port. Refuse it if another
      // handler, host, or Funnel grant appeared after ownership confirmation.
      if (!selectedServeMappingIsExclusive(liveServeStatus)) {
        break;
      }
      spawnSync(tailscaleCLI, [
        "serve",
        "--yes",
        `--https=${selectedHTTPSPort}`,
        "off",
      ], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: CLEANUP_COMMAND_TIMEOUT_MS,
      });
      try {
        const serveAfterRemovalAttempt = readJSONStatus(
          ["serve", "status", "--json"],
          CLEANUP_COMMAND_TIMEOUT_MS,
        );
        result.serveMappingRemoved = !statusUsesSelectedPort(
          serveAfterRemovalAttempt,
          selectedHTTPSPort,
        );
        if (result.serveMappingRemoved) {
          mappingMayExist = false;
        }
      } catch {
        result.serveMappingRemoved = false;
        break;
      }
    }
  }

  if (verify && serveStatusBefore !== undefined && funnelStatusBefore !== undefined && tailscaleCLI) {
    result.serveConfigurationRestored = false;
    result.funnelConfigurationUnchanged = false;
    try {
      const serveAfter = readJSONStatus(
        ["serve", "status", "--json"],
        CLEANUP_COMMAND_TIMEOUT_MS,
      );
      const funnelAfter = readJSONStatus(
        ["funnel", "status", "--json"],
        CLEANUP_COMMAND_TIMEOUT_MS,
      );
      result.serveConfigurationRestored = canonicalJSON(serveAfter) === canonicalJSON(serveStatusBefore);
      result.funnelConfigurationUnchanged = canonicalJSON(funnelAfter) === canonicalJSON(funnelStatusBefore);
    } catch {
      result.serveConfigurationRestored = false;
      result.funnelConfigurationUnchanged = false;
    }
  }
}

async function writeResult() {
  const output = `${JSON.stringify(result, null, 2)}\n`;
  if (resultPath) {
    await writeFile(resultPath, output, { mode: 0o600 });
  }
  process.stdout.write(output);
  resultWritten = true;
}

function writeResultSynchronouslyForSignal() {
  if (emergencyExiting) return;
  emergencyExiting = true;
  cleanupServeSynchronously({ attempts: 1, verify: false });
  result.listenerClosed = true;
  result.probeSucceeded = false;
  result.failureCode = FailureCode.cleanupFailed;
  const output = `${JSON.stringify(result, null, 2)}\n`;
  try {
    if (resultPath) {
      writeFileSync(resultPath, output, { mode: 0o600 });
    }
    process.stdout.write(output);
  } finally {
    process.exit(1);
  }
}

process.once("SIGINT", writeResultSynchronouslyForSignal);
process.once("SIGTERM", writeResultSynchronouslyForSignal);
process.once("uncaughtException", writeResultSynchronouslyForSignal);
process.once("unhandledRejection", writeResultSynchronouslyForSignal);

async function main() {
  try {
    if (!artifactsDirectory) {
      throw new ProbeFailure(FailureCode.outputUnavailable);
    }
    await mkdir(artifactsDirectory, { recursive: true, mode: 0o700 });
    resultPath = join(artifactsDirectory, RESULT_FILE_NAME);
    if ((process.env.NODE_DEBUG ?? "").trim() || (process.env.NODE_OPTIONS ?? "").trim()) {
      throw new ProbeFailure(FailureCode.unsafeDebugEnvironment);
    }
    const requestedWatchdogTimeout = Number(process.env.TOASTTY_TAILSCALE_PROBE_TIMEOUT_MS);
    const watchdogTimeout = Number.isSafeInteger(requestedWatchdogTimeout) && requestedWatchdogTimeout >= 5_000
      ? requestedWatchdogTimeout
      : DEFAULT_WATCHDOG_TIMEOUT_MS;
    watchdog = setTimeout(writeResultSynchronouslyForSignal, watchdogTimeout);
    watchdog.unref();

    tailscaleCLI = await resolveTailscaleCLI();
    if (!tailscaleCLI) {
      throw new ProbeFailure(FailureCode.tailscaleCLIUnavailable);
    }

    serveStatusBefore = readJSONStatus(["serve", "status", "--json"]);
    funnelStatusBefore = readJSONStatus(["funnel", "status", "--json"]);
    selectedHTTPSPort = selectHTTPSPort(serveStatusBefore, funnelStatusBefore);
    if (!selectedHTTPSPort) {
      throw new ProbeFailure(FailureCode.safeHTTPSPortUnavailable);
    }

    const nodeStatus = readJSONStatus(["status", "--json"]);
    const hostname = validateHostname(nodeStatus);
    if (!hostname) {
      throw new ProbeFailure(FailureCode.dnsNameUnavailable);
    }

    const expectedAuthorization = `Bearer ${randomBytes(32).toString("base64url")}`;
    const pathNonce = randomBytes(18).toString("base64url");
    const probePaths = {
      rest: `/toastty-auth-probe-rest-${pathNonce}`,
      webSocket: `/toastty-auth-probe-websocket-${pathNonce}`,
    };
    server = createProbeServer(expectedAuthorization, probePaths);
    const backendPort = await listenOnLoopback(server);
    configureServe(backendPort, hostname);

    if (testMode && process.env.TOASTTY_TAILSCALE_PROBE_TEST_FAIL_AFTER_SERVE === "1") {
      throw new ProbeFailure(FailureCode.testInjectedFailure);
    }

    await restRequest(hostname, selectedHTTPSPort, backendPort, expectedAuthorization, probePaths);
    await webSocketRequest(hostname, selectedHTTPSPort, backendPort, expectedAuthorization, probePaths);

    const observationsPassed = result.restRequestCount === 1
      && result.restAuthorizationHeaderCount === 1
      && result.restAuthorizationUnchanged
      && result.restIdentityHeaderCount === 1
      && result.restIdentityPresent
      && result.webSocketUpgradeCount === 1
      && result.webSocketAuthorizationHeaderCount === 1
      && result.webSocketAuthorizationUnchanged
      && result.webSocketIdentityHeaderCount === 1
      && result.webSocketIdentityPresent
      && result.webSocketClientSawSwitchingProtocols
      && result.ignoredRequestCount === 0
      && (testMode || result.restTLSVerified)
      && (testMode || result.webSocketTLSVerified);
    if (!observationsPassed) {
      throw new ProbeFailure(FailureCode.observationFailed);
    }
  } catch (error) {
    result.failureCode = error instanceof ProbeFailure
      ? error.code
      : FailureCode.internalFailure;
  } finally {
    clearTimeout(watchdog);
    await closeServer(server);
    cleanupServeSynchronously();
  }

  const cleanupPassed = result.serveMappingConfigured
    && result.serveMappingRemoved
    && result.serveConfigurationRestored
    && result.funnelConfigurationUnchanged
    && result.listenerClosed;
  if (result.failureCode === FailureCode.none && !cleanupPassed) {
    result.failureCode = FailureCode.cleanupFailed;
  }
  result.probeSucceeded = result.failureCode === FailureCode.none && cleanupPassed;
  await writeResult();
  process.exitCode = result.probeSucceeded ? 0 : 1;
}

main().catch(async () => {
  result.probeSucceeded = false;
  result.failureCode = FailureCode.internalFailure;
  if (!resultWritten) {
    try {
      await writeResult();
    } catch {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    }
  }
  process.exitCode = 1;
});

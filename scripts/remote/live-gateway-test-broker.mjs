#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";

const argumentsList = process.argv.slice(2);
const stateFlagIndex = argumentsList.indexOf("--state-file");
if (stateFlagIndex < 0 || !argumentsList[stateFlagIndex + 1] || argumentsList.length !== 2) {
  process.stderr.write("error: live gateway broker requires a state file\n");
  process.exit(64);
}

const stateFile = argumentsList[stateFlagIndex + 1];
const temporaryStateFile = `${stateFile}.tmp-${process.pid}`;
process.umask(0o077);

let input = "";
for await (const chunk of process.stdin) {
  input += chunk;
  if (Buffer.byteLength(input, "utf8") > 512) {
    process.stderr.write("error: live gateway broker rejected its input\n");
    process.exit(65);
  }
}

const inputLines = input.split("\n");
if (inputLines.at(-1) === "") {
  inputLines.pop();
}
const [gatewayURL, credential, rawAllowDestructive] = inputLines;
const hostnameLabel = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?";
const gatewayPattern = new RegExp(`^https://(?:${hostnameLabel}\\.)+ts\\.net$`);
const credentialPattern = /^[A-Za-z0-9_-]{43}$/;
if (
  inputLines.length !== 3
  || !gatewayURL
  || gatewayURL.length > 255
  || !gatewayPattern.test(gatewayURL)
  || !credentialPattern.test(credential ?? "")
  || !["false", "true"].includes(rawAllowDestructive)
) {
  process.stderr.write("error: live gateway broker rejected its input\n");
  process.exit(65);
}

const token = crypto.randomBytes(32).toString("base64url");
const allowDestructiveRevocation = rawAllowDestructive === "true";
let servedRequests = 0;
let shuttingDown = false;

function authorizationMatches(value) {
  const expected = Buffer.from(`Bearer ${token}`, "utf8");
  const actual = Buffer.from(value ?? "", "utf8");
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

function categoricalResponse(response, status) {
  response.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Length": "0",
    Connection: "close",
  });
  response.end();
}

const server = http.createServer((request, response) => {
  const address = server.address();
  const expectedHost = typeof address === "object" && address
    ? `127.0.0.1:${address.port}`
    : "";
  try {
    if (
      request.method !== "GET"
      || request.url !== "/v1/config"
      || request.headers.host !== expectedHost
      || request.headers.upgrade !== undefined
      || request.headers["transfer-encoding"] !== undefined
      || ![undefined, "0"].includes(request.headers["content-length"])
      || !authorizationMatches(request.headers.authorization)
      || servedRequests >= 8
    ) {
      categoricalResponse(response, 404);
      return;
    }

    servedRequests += 1;
    const body = Buffer.from(JSON.stringify({
      gatewayURL,
      credential,
      allowDestructiveRevocation,
    }), "utf8");
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Type": "application/json",
      "Content-Length": String(body.length),
      Connection: "close",
    });
    response.end(body);
  } catch {
    categoricalResponse(response, 404);
  }
});

server.requestTimeout = 2_000;
server.headersTimeout = 2_000;
server.keepAliveTimeout = 500;
server.maxConnections = 8;
server.on("clientError", (_error, socket) => socket.destroy());

function removeStateFiles() {
  for (const path of [temporaryStateFile, stateFile]) {
    try {
      fs.unlinkSync(path);
    } catch (error) {
      if (error?.code !== "ENOENT") {
        // State contains only an ephemeral endpoint capability. Cleanup stays
        // categorical so even unexpected filesystem errors expose no input.
        process.stderr.write("warning: live gateway broker state cleanup failed\n");
      }
    }
  }
}

function shutDown(exitCode) {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  server.close(() => {
    removeStateFiles();
    process.exit(exitCode);
  });
  setTimeout(() => {
    removeStateFiles();
    process.exit(exitCode);
  }, 1_000).unref();
}

process.once("SIGTERM", () => shutDown(0));
process.once("SIGINT", () => shutDown(130));
process.once("SIGHUP", () => shutDown(129));
setTimeout(() => shutDown(124), 3_900_000).unref();

server.once("error", () => {
  removeStateFiles();
  process.stderr.write("error: live gateway broker failed\n");
  process.exit(70);
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (typeof address !== "object" || !address) {
    shutDown(70);
    return;
  }

  try {
    fs.writeFileSync(
      temporaryStateFile,
      `${JSON.stringify({ port: address.port, token })}\n`,
      { encoding: "utf8", mode: 0o600, flag: "wx" },
    );
    fs.renameSync(temporaryStateFile, stateFile);
  } catch {
    process.stderr.write("error: live gateway broker failed\n");
    shutDown(70);
  }
});

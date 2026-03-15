#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
import process from "node:process";

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = {
    output: "",
    repoRoot: "",
    version: "",
    sourceCommit: "",
    sourceCommitShort: "",
    previousTag: "",
    previousCommit: "",
    previousCommitShort: "",
    ghosttyCommit: "",
    ghosttyBuildFlags: "",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];

    switch (argument) {
      case "--output":
        args.output = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--repo-root":
        args.repoRoot = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--version":
        args.version = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--source-commit":
        args.sourceCommit = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--source-commit-short":
        args.sourceCommitShort = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--previous-tag":
        args.previousTag = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--previous-commit":
        args.previousCommit = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--previous-commit-short":
        args.previousCommitShort = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--ghostty-commit":
        args.ghosttyCommit = argv[index + 1] ?? "";
        index += 1;
        break;
      case "--ghostty-build-flags":
        args.ghosttyBuildFlags = argv[index + 1] ?? "";
        index += 1;
        break;
      default:
        fail(`unknown argument: ${argument}`);
    }
  }

  for (const [key, value] of Object.entries(args)) {
    if (["previousTag", "previousCommit", "previousCommitShort"].includes(key)) {
      continue;
    }

    if (!value) {
      fail(`missing required argument: ${key}`);
    }
  }

  return args;
}

function runGit(repoRoot, args) {
  return execFileSync("git", ["-C", repoRoot, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function listCommits(repoRoot, previousCommit, sourceCommit) {
  const rangeArgs =
    previousCommit !== ""
      ? ["rev-list", "--reverse", `${previousCommit}..${sourceCommit}`]
      : ["rev-list", "--reverse", sourceCommit];
  const output = runGit(repoRoot, rangeArgs);

  if (!output) {
    return [];
  }

  return output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((commit) => {
      const metadata = runGit(repoRoot, ["show", "-s", "--format=%H%x1f%s%x1f%b%x1f%cI", commit]);
      const [sha, subject, body, committedAt] = metadata.split("\u001f");
      const filesOutput = runGit(repoRoot, [
        "show",
        "--format=",
        "--name-only",
        "--diff-filter=ACDMRTUXB",
        "--no-renames",
        commit,
      ]);
      const files = filesOutput
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
        .slice(0, 12);

      return {
        sha,
        shortSha: sha.slice(0, 12),
        subject,
        body: body.trim(),
        committedAt,
        files,
      };
    });
}

function buildChangesInput(args, commits) {
  const previousReleaseDescription =
    args.previousTag !== ""
      ? `Previous release tag: ${args.previousTag} (${args.previousCommitShort || args.previousCommit})`
      : "Previous release tag: none";

  const commitLines = commits.length
    ? commits
        .map((commit, index) => {
          const body = commit.body ? `Body: ${commit.body.replace(/\s+/g, " ").trim()}` : "Body: none";
          const files = commit.files.length ? commit.files.join(", ") : "none";
          return [
            `${index + 1}. ${commit.subject}`,
            `Commit: ${commit.shortSha}`,
            `Committed at: ${commit.committedAt}`,
            body,
            `Files: ${files}`,
          ].join("\n");
        })
        .join("\n\n")
    : "No commits detected in the computed release range.";

  return [
    `Toastty version: ${args.version}`,
    `Release source commit: ${args.sourceCommitShort}`,
    previousReleaseDescription,
    "",
    "Commits included in this release:",
    commitLines,
  ].join("\n");
}

function buildFallbackSummary(args, commits) {
  if (commits.length === 0) {
    return "- No code changes were detected between the previous release anchor and this release commit.";
  }

  const bullets = commits.slice(0, 8).map((commit) => `- ${commit.subject}`);
  if (commits.length > 8) {
    bullets.push(`- Additional changes are included across ${commits.length - 8} more commits.`);
  }

  if (args.previousTag === "") {
    bullets.unshift("- Initial release cut from the current repository history.");
  }

  return bullets.join("\n");
}

async function summarizeChangesWithOpenAI(args, commits) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    return buildFallbackSummary(args, commits);
  }

  const model = process.env.TOASTTY_RELEASE_NOTES_MODEL || "gpt-5-mini";
  const instructions = [
    "You are drafting the Changes section for Toastty release notes.",
    "Write 4 to 8 concise markdown bullet points.",
    "Ground every bullet in the supplied commit subjects, bodies, and file paths.",
    "Prioritize user-visible features, workflow changes, configuration changes, automation improvements, and release tooling when they matter to the shipped artifact.",
    "Do not mention commit hashes.",
    "Do not add a heading or any intro sentence.",
    "Do not speculate beyond the supplied data.",
  ].join(" ");

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 60_000);

  try {
    const response = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        instructions,
        input: buildChangesInput(args, commits),
        max_output_tokens: 500,
        store: false,
      }),
      signal: controller.signal,
    });

    if (!response.ok) {
      throw new Error(`OpenAI API request failed with status ${response.status}`);
    }

    const payload = await response.json();
    const outputText =
      typeof payload.output_text === "string" ? payload.output_text.trim() : "";

    if (!outputText) {
      throw new Error("OpenAI API response did not include output_text");
    }

    return outputText;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`warning: failed to generate LLM changes summary, using fallback: ${message}\n`);
    return buildFallbackSummary(args, commits);
  } finally {
    clearTimeout(timeout);
  }
}

function buildReleaseNotes(args, changesSection) {
  const generationDate = new Date().toISOString().slice(0, 10);
  const releaseRangeLabel =
    args.previousTag !== ""
      ? `_Generated from commits since ${args.previousTag} (${args.previousCommitShort})._`
      : "_Generated from the full repository history up to this release commit._";

  return `# v${args.version}

Commit: ${args.sourceCommitShort}
Draft generated: ${generationDate}

## Changes

${releaseRangeLabel}

${changesSection.trim()}

## Installation

- Download \`Toastty-${args.version}.dmg\` from this release

## Embedded Ghostty

- Commit: \`${args.ghosttyCommit}\`
- Build flags: \`${args.ghosttyBuildFlags}\`

## Notes

- macOS requirement: 14.0+
- Edit the generated summary and highlights before publishing
`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const commits = listCommits(args.repoRoot, args.previousCommit, args.sourceCommit);
  const changesSection = await summarizeChangesWithOpenAI(args, commits);
  const releaseNotes = buildReleaseNotes(args, changesSection);
  await writeFile(args.output, releaseNotes, "utf8");
}

await main();

#!/usr/bin/env node

import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const rootDirectory = path.resolve(scriptDirectory, "../..");
const outputPath = path.join(
  rootDirectory,
  "Sources/App/Resources/ThirdPartyNotices.txt",
);
const webPanelDirectory = path.join(rootDirectory, "WebPanels/LocalDocumentApp");
const packageLockPath = path.join(webPanelDirectory, "package-lock.json");
const sparkleCheckoutDirectory = path.join(
  rootDirectory,
  "Tuist/.build/checkouts/Sparkle",
);
const sparkleResolvedPath = path.join(rootDirectory, "Tuist/Package.resolved");
const defaultGhosttySourceDirectory = path.resolve(rootDirectory, "../ghostty");
// A package that ships no license file needs an entry here that names the exact
// package version, its license and where the license text comes from.
const licenseOverridesPath = path.join(scriptDirectory, "third-party-license-overrides.json");

const checkOnly = process.argv.includes("--check");
const unknownArguments = process.argv.slice(2).filter((argument) => argument !== "--check");
if (unknownArguments.length > 0) {
  console.error(`error: unknown argument: ${unknownArguments[0]}`);
  process.exit(2);
}

function readRequiredFile(filePath, description) {
  try {
    return normalizedText(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    console.error(`error: unable to read ${description}: ${filePath}`);
    console.error(error.message);
    process.exit(1);
  }
}

function ghosttyFile(sourceDirectory, relativePath, description) {
  if (!process.env.GHOSTTY_COMMIT) {
    return readRequiredFile(path.join(sourceDirectory, relativePath), description);
  }

  try {
    return normalizedText(execFileSync(
      "git",
      ["-C", sourceDirectory, "show", `${process.env.GHOSTTY_COMMIT}:${relativePath}`],
      { encoding: "utf8" },
    ));
  } catch (error) {
    console.error(
      `error: unable to read Ghostty ${relativePath} at commit ${process.env.GHOSTTY_COMMIT} from ${sourceDirectory}`,
    );
    console.error(error.message);
    process.exit(1);
  }
}

function normalizedText(value) {
  return value
    .replaceAll("\r\n", "\n")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .trim();
}

function packageLicenseFiles(packageDirectory) {
  return fs.readdirSync(packageDirectory)
    .filter((fileName) => /^(licen[sc]e|copying)(\.|$)/i.test(fileName))
    .sort()
    .concat(
      fs.readdirSync(packageDirectory)
        .filter((fileName) => /^(notice|third[._-]?party)(\.|$)/i.test(fileName))
        .sort(),
    );
}

function licenseOverrides() {
  if (!fs.existsSync(licenseOverridesPath)) {
    return new Map();
  }
  const entries = JSON.parse(readRequiredFile(licenseOverridesPath, "third-party license overrides"));
  const overrides = new Map();
  for (const [packageLabel, entry] of Object.entries(entries)) {
    for (const field of ["license", "file", "source", "reason"]) {
      if (typeof entry?.[field] !== "string" || entry[field].trim().length === 0) {
        console.error(`error: license override for ${packageLabel} needs a "${field}" in ${licenseOverridesPath}`);
        process.exit(1);
      }
    }
    overrides.set(packageLabel, path.join(scriptDirectory, entry.file));
  }
  return overrides;
}

function productionPackageNotices() {
  const packageLock = JSON.parse(readRequiredFile(packageLockPath, "WebPanel package lock"));
  const overrides = licenseOverrides();
  const usedOverrides = new Set();
  const noticeGroups = new Map();
  const packages = [];

  for (const [relativePackagePath, lockEntry] of Object.entries(packageLock.packages ?? {})) {
    if (relativePackagePath.length === 0 || lockEntry.dev === true) {
      continue;
    }

    const packageDirectory = path.join(webPanelDirectory, relativePackagePath);
    const packageJSON = JSON.parse(readRequiredFile(
      path.join(packageDirectory, "package.json"),
      `package metadata for ${relativePackagePath}`,
    ));
    const packageLabel = `${packageJSON.name}@${packageJSON.version}`;
    let noticePaths = packageLicenseFiles(packageDirectory)
      .map((fileName) => path.join(packageDirectory, fileName));
    if (overrides.has(packageLabel)) {
      if (noticePaths.length > 0) {
        console.error(
          `error: ${packageLabel} ships a license file; remove its entry from ${licenseOverridesPath}`,
        );
        process.exit(1);
      }
      noticePaths = [overrides.get(packageLabel)];
      usedOverrides.add(packageLabel);
    }
    if (noticePaths.length === 0) {
      console.error(`error: no license or notice file found for ${packageLabel}`);
      console.error(
        `If the license is established elsewhere, add an entry for ${packageLabel} to ${licenseOverridesPath}.`,
      );
      process.exit(1);
    }

    packages.push(packageLabel);
    for (const noticePath of noticePaths) {
      const noticeText = normalizedText(readRequiredFile(
        noticePath,
        `${path.basename(noticePath)} for ${packageLabel}`,
      ));
      const digest = crypto.createHash("sha256").update(noticeText).digest("hex");
      const existing = noticeGroups.get(digest) ?? { text: noticeText, packages: [] };
      existing.packages.push(packageLabel);
      noticeGroups.set(digest, existing);
    }
  }

  for (const packageLabel of overrides.keys()) {
    if (!usedOverrides.has(packageLabel)) {
      console.error(
        `error: ${packageLabel} is not a production WebPanel package; remove or update its entry in ${licenseOverridesPath}`,
      );
      process.exit(1);
    }
  }

  packages.sort((lhs, rhs) => lhs.localeCompare(rhs));
  const groups = [...noticeGroups.values()]
    .map((group) => ({
      text: group.text,
      packages: group.packages.sort((lhs, rhs) => lhs.localeCompare(rhs)),
    }))
    .sort((lhs, rhs) => lhs.packages[0].localeCompare(rhs.packages[0]));

  return { packages, groups };
}

function sparklePin() {
  const resolved = JSON.parse(readRequiredFile(sparkleResolvedPath, "Tuist package resolution"));
  const pin = resolved.pins?.find((candidate) => candidate.identity === "sparkle");
  if (!pin?.state?.version || !pin?.state?.revision) {
    console.error("error: Tuist/Package.resolved is missing the pinned Sparkle version or revision");
    process.exit(1);
  }
  return pin.state;
}

function renderSection(title, metadata, contents) {
  const separator = "=".repeat(80);
  return [separator, title, metadata, separator, "", contents].filter(Boolean).join("\n");
}

const ghosttySourceDirectory = process.env.GHOSTTY_SOURCE_REPO
  ? path.resolve(process.env.GHOSTTY_SOURCE_REPO)
  : defaultGhosttySourceDirectory;
const sparkle = sparklePin();
const webPanel = productionPackageNotices();
const renderedPackageGroups = webPanel.groups.map((group) => renderSection(
  `WebPanel dependency license`,
  `Packages: ${group.packages.join(", ")}`,
  group.text,
));

const generatedContents = `${[
  "TOASTTY THIRD-PARTY SOFTWARE NOTICES",
  "",
  "This file is generated by scripts/release/generate-third-party-notices.mjs.",
  "It includes the licenses and notices shipped with Toastty and its bundled dependencies.",
  "",
  renderSection(
    "Toastty",
    "Project license",
    readRequiredFile(path.join(rootDirectory, "LICENSE"), "Toastty license"),
  ),
  "",
  renderSection(
    "Ghostty",
    "Bundled terminal runtime",
    ghosttyFile(ghosttySourceDirectory, "LICENSE", "Ghostty license"),
  ),
  "",
  renderSection(
    "Nerd Fonts",
    "Symbols Only font data embedded by the bundled Ghostty runtime",
    ghosttyFile(
      ghosttySourceDirectory,
      "vendor/nerd-fonts/LICENSE",
      "Ghostty Nerd Fonts license",
    ),
  ),
  "",
  renderSection(
    "Sparkle",
    `Version ${sparkle.version}; revision ${sparkle.revision}`,
    readRequiredFile(path.join(sparkleCheckoutDirectory, "LICENSE"), "Sparkle license"),
  ),
  "",
  `Bundled LocalDocument WebPanel production packages:\n${webPanel.packages.join("\n")}`,
  "",
  ...renderedPackageGroups.flatMap((section) => [section, ""]),
].join("\n").trim()}\n`;

if (checkOnly) {
  const existingContents = fs.existsSync(outputPath)
    ? fs.readFileSync(outputPath, "utf8")
    : "";
  if (existingContents !== generatedContents) {
    console.error(`error: third-party notices are stale or missing: ${outputPath}`);
    console.error("Run scripts/release/generate-third-party-notices.mjs and commit the result.");
    process.exit(1);
  }
  console.log("ok: third-party notices match pinned dependencies");
  process.exit(0);
}

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, generatedContents);
console.log(`wrote ${path.relative(rootDirectory, outputPath)}`);

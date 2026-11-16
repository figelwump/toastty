#!/usr/bin/env python3
"""Tests for the release checks that stop a release before it ships: the
Ghostty pin check and the publish step's release notes checks. Disposable
directories and Git repositories with a fake gh; never contacts GitHub.

Run: python3 Tests/Scripts/test_release_scripts.py
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[2]
PIN_SCRIPT = REPO / "scripts/release/check-ghostty-pin.sh"
PUBLISH_SCRIPT = REPO / "scripts/release/publish-github-release.sh"

PIN = "13dc86d4c663e0a8b1b3569417f5ceeb6934f5a7"
OTHER = "8bc4f5354d334b2f3d743261faf87cdb4637155c"

FAKE_GH = """#!/bin/sh
echo "$@" >> "$FAKE_GH_LOG"
exit 1
"""

VALID_NOTES = """# v0.10.0

Release date: November 20, 2026
Toastty commit: `abc123`
Previous release: `v0.9.2`

## Highlights

- Tasks: describe work once and Toastty runs it in its own worktree.

## Changes

- A change.

## Upgrade Notes

- No manual migration is required.

## Embedded Ghostty

- Commit: `13dc86d4c663`
- Build flags: `-Demit-xcframework=true`
"""


def run(args, env=None, cwd=None):
    return subprocess.run(args, capture_output=True, text=True, env=env, cwd=cwd)


class GhosttyPinTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.doc = self.tmp / "ghostty-integration.md"

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def check(self, installed, doc_text):
        self.doc.write_text(doc_text)
        env = dict(os.environ, TOASTTY_GHOSTTY_PIN_DOC=str(self.doc))
        return run([str(PIN_SCRIPT), installed], env=env)

    def doc_with(self, *commits):
        lines = ["# Ghostty", "", "```bash"]
        lines += [f"git -C ../ghostty checkout {commit}" for commit in commits]
        lines += ["```", ""]
        return "\n".join(lines)

    def test_matching_artifact_passes(self):
        result = self.check(PIN, self.doc_with(PIN))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(PIN, result.stdout)

    def test_commit_case_does_not_matter(self):
        result = self.check(PIN.upper(), self.doc_with(PIN))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_stale_artifact_stops_the_release(self):
        result = self.check(OTHER, self.doc_with(PIN))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(OTHER, result.stderr)
        self.assertIn(PIN, result.stderr)

    def test_short_installed_commit_does_not_pass(self):
        result = self.check(PIN[:12], self.doc_with(PIN))
        self.assertNotEqual(result.returncode, 0)

    def test_document_without_a_pin_stops_the_release(self):
        result = self.check(PIN, "# Ghostty\n\nNo checkout line.\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)

    def test_document_with_two_pins_stops_the_release(self):
        result = self.check(PIN, self.doc_with(PIN, OTHER))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 2", result.stderr)

    def test_repeated_identical_pin_counts_once(self):
        result = self.check(PIN, self.doc_with(PIN, PIN))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_repository_document_has_one_pin(self):
        """The real document must keep the line the release check reads."""
        doc = (REPO / "docs/ghostty-integration.md").read_text()
        pins = {line.split()[4] for line in doc.splitlines()
                if line.startswith("git -C ../ghostty checkout ")}
        self.assertEqual(len(pins), 1, pins)
        env = dict(os.environ)
        env.pop("TOASTTY_GHOSTTY_PIN_DOC", None)
        result = run([str(PIN_SCRIPT), pins.pop()], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)


class PublishNotesTests(unittest.TestCase):
    """Runs the real publish script with --dry-run in a disposable checkout."""

    VERSION = "0.10.0"
    BUILD = "40"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "toastty"
        script_dir = self.root / "scripts/release"
        script_dir.mkdir(parents=True)
        shutil.copy2(PUBLISH_SCRIPT, script_dir / PUBLISH_SCRIPT.name)

        origin = self.tmp / "origin.git"
        run(["git", "init", "-q", "--bare", str(origin)])
        git = ["git", "-C", str(self.root)]
        run(git + ["init", "-q"])
        run(git + ["remote", "add", "origin", str(origin)])
        (self.root / "README").write_text("release\n")
        run(git + ["add", "README"])
        run(git + ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                   "commit", "-q", "-m", "release"])
        commit = run(git + ["rev-parse", "HEAD"]).stdout.strip()

        label = f"{self.VERSION}-{self.BUILD}"
        self.release_dir = self.root / "artifacts/release" / label
        self.release_dir.mkdir(parents=True)
        dmg = self.release_dir / f"Toastty-{self.VERSION}.dmg"
        dmg.write_bytes(b"dmg")
        self.notes = self.release_dir / "release-notes.md"
        sparkle = self.release_dir / "sparkle-metadata.env"
        (self.release_dir / "release-metadata.env").write_text("\n".join([
            f"RELEASE_VERSION={self.VERSION}",
            f"RELEASE_BUILD_NUMBER={self.BUILD}",
            f"RELEASE_SOURCE_COMMIT={commit}",
            f"RELEASE_SOURCE_COMMIT_SHORT={commit[:12]}",
            "RELEASE_SOURCE_DIRTY=0",
            f"RELEASE_NOTES_PATH={self.notes}",
            f"RELEASE_DMG_PATH={dmg}",
            f"RELEASE_SPARKLE_METADATA_PATH={sparkle}",
            "RELEASE_GHOSTTY_COMMIT_SHORT=13dc86d4c663",
            "RELEASE_GHOSTTY_BUILD_FLAGS='-Demit-xcframework=true'",
            "",
        ]))
        sparkle.write_text("\n".join([
            "SPARKLE_FEED_URL=https://updates.example.invalid/appcast.xml",
            "SPARKLE_PUBLIC_ED_KEY=key",
            "SPARKLE_MINIMUM_SYSTEM_VERSION=14.0",
            f"SPARKLE_DMG_PATH={dmg}",
            f"SPARKLE_DMG_FILENAME={dmg.name}",
            "SPARKLE_ENCLOSURE_LENGTH=3",
            "SPARKLE_ED_SIGNATURE=c2lnbmF0dXJl",
            "",
        ]))

        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.gh_log = self.tmp / "gh.log"
        self.env = dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            FAKE_GH_LOG=str(self.gh_log),
            TOASTTY_VERSION=self.VERSION,
            TOASTTY_BUILD_NUMBER=self.BUILD,
            GIT_TERMINAL_PROMPT="0",
        )

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def publish(self, notes):
        self.notes.write_text(notes)
        result = run([str(self.root / "scripts/release/publish-github-release.sh"),
                      "--dry-run", "--create-tag", "--repo", "example/toastty"],
                     env=self.env, cwd=self.root)
        self.assertFalse(self.gh_log.exists(), "a dry run must not call gh")
        return result

    def test_notes_with_highlights_pass(self):
        result = self.publish(VALID_NOTES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run release command", result.stdout)

    def test_highlights_with_subsections_pass(self):
        notes = VALID_NOTES.replace(
            "- Tasks: describe work once and Toastty runs it in its own worktree.\n",
            "### Tasks\n\nDescribe work once.\n")
        result = self.publish(notes)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_highlights_stop_the_publish(self):
        notes = VALID_NOTES.replace(
            "## Highlights\n\n- Tasks: describe work once and Toastty runs it in its own worktree.\n\n", "")
        result = self.publish(notes)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no '## Highlights' section", result.stderr)

    def test_highlights_with_only_a_comment_stop_the_publish(self):
        notes = VALID_NOTES.replace(
            "- Tasks: describe work once and Toastty runs it in its own worktree.\n",
            "<!-- Say what is new.\n     Two lines. -->\n")
        result = self.publish(notes)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("section of the release notes is empty", result.stderr)

    def test_commented_out_highlights_stop_the_publish(self):
        notes = VALID_NOTES.replace(
            "## Highlights\n\n- Tasks: describe work once and Toastty runs it in its own worktree.\n",
            "<!--\n## Highlights\n\n- Hidden.\n-->\n")
        result = self.publish(notes)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no '## Highlights' section", result.stderr)

    def test_heading_inside_a_code_fence_is_not_a_section(self):
        example = "```markdown\n## Highlights\n```\n\n"
        only_example = VALID_NOTES.replace(
            "## Highlights\n\n- Tasks: describe work once and Toastty runs it in its own worktree.\n\n",
            "")
        result = self.publish(only_example.replace("## Changes", example + "## Changes"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no '## Highlights' section", result.stderr)

        result = self.publish(VALID_NOTES.replace("## Changes", example + "## Changes"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_repeated_highlights_stop_the_publish(self):
        notes = VALID_NOTES.replace("## Changes", "## Highlights\n\n- Again.\n\n## Changes")
        result = self.publish(notes)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("more than one", result.stderr)

    def test_template_placeholder_stops_the_publish(self):
        notes = VALID_NOTES.replace("- A change.", "- {{change_2}}")
        result = self.publish(notes)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("template placeholder", result.stderr)


if __name__ == "__main__":
    unittest.main()

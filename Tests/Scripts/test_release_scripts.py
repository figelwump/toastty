#!/usr/bin/env python3
"""Tests for the release checks that stop a release before it ships: the
Ghostty pin check, the third-party notices check, and the publish step's
release notes checks. Disposable directories and Git repositories with a fake
gh; never contacts GitHub.

Run: python3 Tests/Scripts/test_release_scripts.py
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[2]
PIN_SCRIPT = REPO / "scripts/release/check-ghostty-pin.sh"
PUBLISH_SCRIPT = REPO / "scripts/release/publish-github-release.sh"
FIRST_LAUNCH_SCRIPT = REPO / "scripts/release/first-launch.py"
HIGHLIGHTS_SCRIPT = REPO / "scripts/release/release_notes_highlights.py"
NOTICES_SCRIPT = REPO / "scripts/release/generate-third-party-notices.mjs"

sys.path.insert(0, str(HIGHLIGHTS_SCRIPT.parent))
import release_notes_highlights as highlights  # noqa: E402

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
        shutil.copy2(FIRST_LAUNCH_SCRIPT, script_dir / FIRST_LAUNCH_SCRIPT.name)
        shutil.copy2(HIGHLIGHTS_SCRIPT, script_dir / HIGHLIGHTS_SCRIPT.name)

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
        dmg = self.dmg = self.release_dir / f"Toastty-{self.VERSION}.dmg"
        dmg.write_bytes(b"dmg")
        self.evidence = self.release_dir / "first-launch/remote"
        self.evidence.mkdir(parents=True)
        self.receipt = dict(status="pass", sourceCommit=commit,
                            dmgSHA256=hashlib.sha256(dmg.read_bytes()).hexdigest())
        self.result = self.evidence / "result.json"
        self.result.write_text(json.dumps(self.receipt))
        self.admission = self.evidence / "admission.json"
        self.admission.write_text(json.dumps(dict(state="finished", exitCode=0, resource="desktop")))
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

    def publish(self, notes, *extra):
        self.notes.write_text(notes)
        result = run([str(self.root / "scripts/release/publish-github-release.sh"),
                      "--dry-run", "--create-tag", "--repo", "example/toastty", *extra],
                     env=self.env, cwd=self.root)
        calls = self.gh_log.read_text().splitlines() if self.gh_log.exists() else []
        # A dry run may only read the current feed, which the fake gh refuses.
        self.assertTrue(all(call.startswith("api repos/example/toastty-updates/contents/appcast.xml?")
                            for call in calls), calls)
        return result

    def test_feed_item_carries_the_highlights(self):
        result = self.publish(VALID_NOTES, "--publish")
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = ET.parse(self.release_dir / "appcast-dry-run.xml")
        item = feed.getroot().find("channel/item")
        sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
        release_url = "https://github.com/example/toastty/releases/tag/v0.10.0"
        self.assertIsNone(item.find(sparkle + "releaseNotesLink"),
                          "Sparkle shows the linked page instead of the description")
        self.assertEqual(item.findtext("description"),
                         "<ul><li>Tasks: describe work once and Toastty runs it in its own worktree.</li></ul>\n"
                         f'<p><a href="{release_url}">Full release notes on GitHub</a></p>')
        self.assertEqual(item.findtext("link"), release_url)
        self.assertEqual(item.findtext(sparkle + "fullReleaseNotesLink"),
                         "https://github.com/example/toastty/releases")

    def test_unsupported_highlights_stop_before_the_tag(self):
        notes = VALID_NOTES.replace("- Tasks:", "1. Tasks:")
        result = self.publish(notes, "--publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("only bullets", result.stderr)
        self.assertNotIn("Dry run tag command", result.stdout)

    def test_notes_with_highlights_pass(self):
        result = self.publish(VALID_NOTES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run release command", result.stdout)

    def assert_publication_blocked(self, diagnostic):
        result = self.publish(VALID_NOTES)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(diagnostic, result.stderr)
        self.assertNotIn("Dry run tag command", result.stdout)
        self.assertFalse(self.gh_log.exists(), "publication contacted GitHub")

    def test_missing_first_launch_evidence_blocks_publication(self):
        self.result.unlink()
        self.assert_publication_blocked("first-launch/remote/result.json")

    def test_unconfirmed_desktop_cleanup_blocks_publication(self):
        self.admission.write_text(json.dumps(dict(state="blocked", exitCode=78, resource="desktop")))
        self.assert_publication_blocked("no successful desktop first-launch check")

    def test_failed_first_launch_blocks_publication(self):
        self.receipt["status"] = "fail"
        self.result.write_text(json.dumps(self.receipt))
        self.assert_publication_blocked("no successful desktop first-launch check")

    def test_changed_dmg_blocks_publication(self):
        self.dmg.write_bytes(b"different dmg")
        self.assert_publication_blocked("does not match the candidate DMG and source commit")

    def test_evidence_from_another_commit_blocks_publication(self):
        self.receipt["sourceCommit"] = OTHER
        self.result.write_text(json.dumps(self.receipt))
        self.assert_publication_blocked("does not match the candidate DMG and source commit")

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

        # The same example in another section does not repeat the heading.
        result = self.publish(VALID_NOTES.replace("- A change.\n", "- A change.\n\n" + example))
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


class HighlightsHTMLTests(unittest.TestCase):
    """The prompt shows this HTML as is, so unsupported Markdown must stop."""

    URL = "https://github.com/example/toastty/releases/tag/v1"
    LINK = f'<p><a href="{URL}">Full release notes on GitHub</a></p>'

    def convert(self, section):
        return highlights.to_html(
            highlights.highlights_lines(f"# v1\n\n## Highlights\n\n{section}\n\n## Changes\n\n- x\n"),
            self.URL)

    def rejects(self, section, message):
        with self.assertRaises(highlights.NotesError) as raised:
            self.convert(section)
        self.assertIn(message, str(raised.exception))

    def test_bullets_subheadings_and_paragraphs(self):
        html = self.convert("### Tasks\n\nOne task per worktree,\nfrom start to merge.\n\n- First\n- Second\n  continues here\n* Third")
        self.assertEqual(html, "\n".join([
            "<h3>Tasks</h3>",
            "<p>One task per worktree, from start to merge.</p>",
            "<ul><li>First</li><li>Second continues here</li><li>Third</li></ul>",
            self.LINK]))

    def test_inline_code_bold_and_links(self):
        html = self.convert("- Press `<Opt>⌥⇧T` for **quick entry**; see [the docs](https://toastty.dev/#tasks).")
        self.assertIn("<code>&lt;Opt&gt;⌥⇧T</code>", html)
        self.assertIn("<strong>quick entry</strong>", html)
        self.assertIn('<a href="https://toastty.dev/#tasks">the docs</a>', html)

    def test_text_is_escaped(self):
        html = self.convert("- Fix <script>alert(1)</script> & \"quotes\"")
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("&amp;", html)

    def test_unsupported_markdown_stops(self):
        cases = {
            "1. Numbered": "only bullets",
            "#### Deep heading": "only bullets",
            "> Quote": "only bullets",
            "| a | b |": "only bullets",
            "<div>raw</div>": "only bullets",
            "- Item\n  - Nested": "nested lists",
            "```\ncode\n```": "code blocks",
            "- ![image](https://example.com/a.png)": "images",
            "- [mail](mailto:a@example.com)": "links in Highlights",
            "- Unmatched `tick": "unmatched backtick",
            "### Heading\n  indented": "indented text",
        }
        for section, message in cases.items():
            with self.subTest(section=section):
                self.rejects(section, message)


class NoticesGeneratorTests(unittest.TestCase):
    """Runs the real notices generator in a disposable tree with two production
    packages: "licensed" ships a LICENSE file and "bare" ships none."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="toastty-notices-"))
        release = self.root / "scripts/release"
        release.mkdir(parents=True)
        shutil.copy(NOTICES_SCRIPT, release)
        (self.root / "LICENSE").write_text("Toastty license\n")
        sparkle = self.root / "Tuist/.build/checkouts/Sparkle"
        sparkle.mkdir(parents=True)
        (sparkle / "LICENSE").write_text("Sparkle license\n")
        (self.root / "Tuist/Package.resolved").write_text(json.dumps({"pins": [
            {"identity": "sparkle", "state": {"version": "2.8.1", "revision": "abc"}},
        ]}))
        ghostty = self.root / "ghostty"
        (ghostty / "vendor/nerd-fonts").mkdir(parents=True)
        (ghostty / "LICENSE").write_text("Ghostty license\n")
        (ghostty / "vendor/nerd-fonts/LICENSE").write_text("Nerd Fonts license\n")
        self.web = self.root / "WebPanels/LocalDocumentApp"
        self.web.mkdir(parents=True)
        self.install("licensed", "1.0.0", license_text="Licensed license\n")
        self.install("bare", "1.0.0")

    def tearDown(self):
        shutil.rmtree(self.root)

    def install(self, name, version, license_text=None):
        package = self.web / "node_modules" / name
        package.mkdir(parents=True, exist_ok=True)
        (package / "package.json").write_text(json.dumps({"name": name, "version": version}))
        if license_text:
            (package / "LICENSE").write_text(license_text)
        lock_path = self.web / "package-lock.json"
        lock = json.loads(lock_path.read_text()) if lock_path.exists() else {"packages": {"": {}}}
        lock["packages"][f"node_modules/{name}"] = {"version": version}
        lock_path.write_text(json.dumps(lock))

    def override(self, entries):
        release = self.root / "scripts/release"
        for label in entries:
            entries[label] = {
                "license": "MIT",
                "file": f"third-party-licenses/{label}.txt",
                "source": f"https://example.invalid/{label}/License.md",
                "reason": "The package ships no license file.",
                **entries[label],
            }
            (release / "third-party-licenses").mkdir(exist_ok=True)
            (release / f"third-party-licenses/{label}.txt").write_text(f"Upstream license for {label}\n")
        (release / "third-party-license-overrides.json").write_text(json.dumps(entries))

    def generate(self, *args):
        env = {k: v for k, v in os.environ.items() if k != "GHOSTTY_COMMIT"}
        env["GHOSTTY_SOURCE_REPO"] = str(self.root / "ghostty")
        return run(["node", str(self.root / "scripts/release" / NOTICES_SCRIPT.name), *args], env=env)

    def test_package_without_a_license_file_stops_the_check(self):
        result = self.generate("--check")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("no license or notice file found for bare@1.0.0", result.stderr)
        self.assertIn("third-party-license-overrides.json", result.stderr)

    def test_entry_supplies_the_license_of_a_package_without_one(self):
        self.override({"bare@1.0.0": {}})
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        notices = (self.root / "Sources/App/Resources/ThirdPartyNotices.txt").read_text()
        self.assertIn("Packages: bare@1.0.0\n" + "=" * 80 + "\nUpstream license for bare@1.0.0", notices)
        self.assertIn("Packages: licensed@1.0.0\n" + "=" * 80 + "\nLicensed license", notices)
        check = self.generate("--check")
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_entry_names_one_exact_version(self):
        self.override({"bare@1.0.0": {}})
        self.install("bare", "1.0.1")
        result = self.generate("--check")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("no license or notice file found for bare@1.0.1", result.stderr)

    def test_entry_for_a_package_that_ships_a_license_stops(self):
        self.override({"bare@1.0.0": {}, "licensed@1.0.0": {}})
        result = self.generate("--check")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("licensed@1.0.0 ships a license file; remove its entry", result.stderr)

    def test_unused_entry_stops(self):
        self.override({"bare@1.0.0": {}, "gone@2.0.0": {}})
        result = self.generate("--check")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("gone@2.0.0 is not a production WebPanel package", result.stderr)

    def test_entry_without_a_source_stops(self):
        self.override({"bare@1.0.0": {"source": ""}})
        result = self.generate("--check")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('license override for bare@1.0.0 needs a "source"', result.stderr)


if __name__ == "__main__":
    unittest.main()

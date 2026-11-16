#!/usr/bin/env python3
"""Reads the "## Highlights" section of Toastty release notes.

The Sparkle update prompt shows the update feed item's <description> as HTML.
The publish step puts the Highlights there, so an updating user reads them
first. This helper checks the notes and converts the section.

Usage:
  release_notes_highlights.py check <notes.md>
  release_notes_highlights.py html <notes.md> <full-notes-url>

The section supports a small Markdown subset: "- " or "* " bullets,
"### " subheadings, paragraphs, `code`, **bold**, and [text](https://...)
links. Anything else stops the publish, so the prompt never shows raw
Markdown. HTML comments are ignored, and a heading inside a code fence is not
a section heading. Exit status 1 with an "error:" line on stderr on failure.
"""
import html
import re
import sys

HEADING = re.compile(r"^##\s+Highlights\s*$")
SECTION = re.compile(r"^##\s")
FENCE = re.compile(r"^\s*(```|~~~)")
PLACEHOLDER = re.compile(r"\{\{[^}]*\}\}")
LINK = re.compile(r"\[([^\]]+)\]\((https?://[^\s)]+)\)")
BOLD = re.compile(r"\*\*(.+?)\*\*")
BULLET = re.compile(r"^[-*]\s+(.*)$")
SUBHEADING = re.compile(r"^###\s+(.*)$")


class NotesError(Exception):
    pass


def highlights_lines(text):
    """Returns the lines of the one Highlights section, without comments."""
    for number, line in enumerate(text.splitlines(), 1):
        if PLACEHOLDER.search(line):
            raise NotesError(f"release notes still contain a template placeholder at line {number}")

    headings = 0
    section = []
    in_section = in_comment = in_fence = False
    for line in text.splitlines():
        line = line.rstrip("\r")
        if in_comment:
            if "-->" in line:
                in_comment = False
            continue
        if line.lstrip().startswith("<!--"):
            in_comment = "-->" not in line
            continue
        if FENCE.match(line):
            in_fence = not in_fence
            if in_section:
                section.append(line)
            continue
        if in_fence:
            if in_section:
                section.append(line)
            continue
        if HEADING.match(line):
            headings += 1
            in_section = True
            continue
        if SECTION.match(line):
            in_section = False
            continue
        if in_section:
            section.append(line)

    if headings == 0:
        raise NotesError("release notes have no '## Highlights' section; every release needs one (see .agents/skills/toastty-release/SKILL.md)")
    if headings > 1:
        raise NotesError("release notes have more than one '## Highlights' section")
    if not any(line.strip() for line in section):
        raise NotesError("the '## Highlights' section of the release notes is empty")
    return section


def inline(text):
    """Converts one line of inline Markdown to HTML."""
    parts = text.split("`")
    if len(parts) % 2 == 0:
        raise NotesError(f"unmatched backtick in Highlights: {text.strip()}")
    out = []
    for index, part in enumerate(parts):
        if index % 2:
            out.append(f"<code>{html.escape(part)}</code>")
            continue
        if "![" in part:
            raise NotesError(f"images are not supported in Highlights: {text.strip()}")
        pieces = []
        last = 0
        for match in LINK.finditer(part):
            pieces.append(html.escape(part[last:match.start()]))
            pieces.append(f'<a href="{html.escape(match.group(2))}">{html.escape(match.group(1))}</a>')
            last = match.end()
        pieces.append(html.escape(part[last:]))
        converted = BOLD.sub(r"<strong>\1</strong>", "".join(pieces))
        if "](" in converted:
            raise NotesError(f"links in Highlights must be [text](https://...): {text.strip()}")
        out.append(converted)
    return "".join(out)


def to_html(lines, full_notes_url):
    blocks = []  # (kind, [text, ...]); kind is "ul", "p", "h3" or "break"
    for line in lines:
        if not line.strip():
            if blocks:
                blocks.append(("break", []))
            continue
        if FENCE.match(line):
            raise NotesError("code blocks are not supported in Highlights")
        indented = line[:1].isspace()
        stripped = line.strip()
        if indented:
            if BULLET.match(stripped) or re.match(r"^\d+[.)]\s", stripped):
                raise NotesError(f"nested lists are not supported in Highlights: {stripped}")
            if not blocks or blocks[-1][0] in ("break", "h3"):
                raise NotesError(f"indented text must continue a bullet or paragraph: {stripped}")
            blocks[-1][1][-1] += " " + stripped
            continue
        if re.match(r"^(#{1,2}|#{4,})\s", stripped) or re.match(r"^\d+[.)]\s", stripped) \
                or stripped.startswith((">", "|", "<")):
            raise NotesError(f"only bullets, ### subheadings and paragraphs are supported in Highlights: {stripped}")
        bullet = BULLET.match(stripped)
        heading = SUBHEADING.match(stripped)
        if heading:
            blocks.append(("h3", [heading.group(1)]))
        elif bullet:
            if blocks and blocks[-1][0] == "ul":
                blocks[-1][1].append(bullet.group(1))
            else:
                blocks.append(("ul", [bullet.group(1)]))
        elif blocks and blocks[-1][0] == "p":
            blocks[-1][1][-1] += " " + stripped
        else:
            blocks.append(("p", [stripped]))

    out = []
    for kind, items in blocks:
        if kind == "ul":
            out.append("<ul>" + "".join(f"<li>{inline(item)}</li>" for item in items) + "</ul>")
        elif kind == "h3":
            out.append(f"<h3>{inline(items[0])}</h3>")
        elif kind == "p":
            out.append(f"<p>{inline(items[0])}</p>")
    out.append(f'<p><a href="{html.escape(full_notes_url)}">Full release notes on GitHub</a></p>')
    return "\n".join(out)


def main(argv):
    if len(argv) == 3 and argv[1] == "check":
        command, path, url = "check", argv[2], "https://example.invalid"
    elif len(argv) == 4 and argv[1] == "html":
        command, path, url = "html", argv[2], argv[3]
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        with open(path, encoding="utf-8") as notes:
            result = to_html(highlights_lines(notes.read()), url)
    except NotesError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if command == "html":
        print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

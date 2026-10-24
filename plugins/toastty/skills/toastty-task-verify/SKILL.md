---
name: toastty-task-verify
description: Use in a Toastty-managed task session when the task's work is ready for the user to review, such as after you open or update its pull request, or when Toastty or the user asks for a review packet. Writes a review packet (what changed, the one thing to look at, the checks you ran, what you did not verify, and before and after screenshots for UI changes) and publishes it with `toastty task packet publish`.
---

# Toastty Task Verify

A review packet is what the user reads before they look at your work. It must
let them decide in a minute where to look and how much to trust what you did.
Toastty stores each packet you publish as a new version, keeps it after the
worktree is gone, and moves the task to Needs you. Publish a new packet each
time the work is ready for another look, such as after you address review
notes; do not edit an old one.

Run the commands below with `"$TOASTTY_CLI_PATH"`. If it is not set, report that
this skill must run inside a Toastty-managed agent session, and stop.

A project can name its own verify skill with `verify_skill` in
`~/.toastty/tasks.toml`; `"$TOASTTY_CLI_PATH" task get` shows it as
`verifySkill`. When that names another skill, follow that skill instead. A
project skill that extends this one keeps the packet format below.

## 1. Verify first

Run the checks the repository asks for (its AGENTS.md, CONTRIBUTING, or verify
skill), and the ones that prove the change works through its real surface: the
UI, the CLI, or the API. Save each check's output to a file, such as under the
repository's ignored artifacts folder or a temporary directory, so the user can
open it.

For a change the user can see, take screenshots before and after the change at
widths of 390 and 1280 points: the same page, in the same state. Name the files
`before-390.png`, `after-390.png`, `before-1280.png` and `after-1280.png`, or
add a short subject, such as `after-1280-checkout.png`. Skip screenshots for a
change with nothing to see.

## 2. Write the packet

Write `packet.json` outside the repository, or in an ignored folder:

```json
{
  "summary": "Moves the order summary above payment on narrow screens.",
  "look_at": "The pinned totals bar at 390 px while you scroll the payment form.",
  "checks": [
    { "name": "npm test", "ok": true, "log": "/tmp/checkout-tests.log" },
    { "name": "e2e checkout with a coupon", "ok": false, "log": "/tmp/e2e.log: coupon total off by one cent" }
  ],
  "not_verified": ["Safari's sticky footer", "Right-to-left layouts"],
  "screenshots": [
    { "name": "before-390", "pair": "before", "width": 390 },
    { "name": "after-390", "pair": "after", "width": 390 },
    { "name": "before-1280", "pair": "before", "width": 1280 },
    { "name": "after-1280", "pair": "after", "width": 1280 }
  ]
}
```

- `summary`: what changed, in one line. Say what the user gets, not which files
  changed.
- `look_at`: the one specific place where a mistake is most likely or would
  matter most, such as a screen and state, a function, or an edge case. Not
  "the whole PR" or "everything".
- `checks`: each check you ran, with `ok` true or false and `log`, the path to
  its output, or a short excerpt. Include failed checks; do not leave them out.
- `not_verified`: what you did not check, or could not check, and would want
  checked. Be honest. Write `[]` only when you checked everything; Toastty
  refuses a packet without the field.
- `screenshots`: one entry per file. `name` is the file name without its
  extension. `pair` is `"before"`, `"after"`, or `null` for a screenshot that
  is not part of a comparison; a before and an after with the same `width`
  form a pair. Leave the list out, or write `[]`, when there are no
  screenshots.

## 3. Publish

```bash
"$TOASTTY_CLI_PATH" task packet publish --file packet.json \
  --screenshot before-390.png --screenshot after-390.png \
  --screenshot before-1280.png --screenshot after-1280.png
```

Pass every screenshot the packet names, and no others. Toastty refuses a packet
that is missing `summary`, `look_at` or `not_verified`, has an unknown key, or
whose screenshots do not match the files. Fix what the error names and publish
again. On success it prints the task with its `packetVersion`, and the task
waits for the user in Needs you. Do not also run `task ready-for-review`.

Read a published packet with `"$TOASTTY_CLI_PATH" task packet get`, adding
`--version <n>` for an older one. `stale: true` means commits landed in the
worktree after the newest packet: publish a new one when the work is ready
again.

Then end your turn with the packet's `summary` and `look_at`, so the user sees
them in the conversation too.

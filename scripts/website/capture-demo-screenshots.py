#!/usr/bin/env python3
"""Captures Toastty screenshots for the README and the website from a made-up
"lumen" demo with real tasks.

Run it through scripts/website/capture-demo-screenshots.sh, which can build
the app first. It launches an isolated Debug build in automation mode (its
own runtime home, home folder for both the shell and Foundation, temporary
directory, socket, settings, and Ghostty config), builds the demo through the
toastty CLI, and has the app draw each capture itself
(`automation.capture_screenshot`), so it needs no Screen Recording
permission. Nothing touches your normal Toastty data.

The demo holds real tasks. Each task's agent is a fake `claude` that prints a
canned transcript and waits; the script reports the agents' statuses through
the CLI. The coordinator is a fake `claude` too: it writes Claude Code
transcript records, which the coordinator chat shows. A fake `gh` answers that
PR #128 is open with passing checks. No real agent or GitHub account is used.

Clicks and keys go through Accessibility (scripts/automation/ax-drive.swift),
so the terminal that runs this needs Accessibility permission and an unlocked
screen. --hidpi-display adds a temporary 2x display for the run, for a Mac
whose display is 1x, such as the remote Mac mini: windows open on it, so the
captures are 2x. macOS makes that display the main display while it exists.

Writes to --out:
  window.png             the window: the lumen project with a split pair of
                         sessions and a Scratchpad in the right panel
  sidebar.png            the sidebar down to the lumen project card
  right-panel.png        the right panel's top
  coordinator-dock.png   the window with the coordinator chat in its dock
  tasks-view.png         the window with the Tasks view, a task selected
  quick-entry.png        the quick entry panel with a message
  raw/                   the captures before cropping, with layout.json
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WINDOW_SIZE = (1440, 900)


def fail(message):
    raise SystemExit(f'capture-demo-screenshots: {message}')


def wait_for(description, probe, timeout=60, interval=0.25):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = probe()
        if last:
            return last
        time.sleep(interval)
    fail(f'timed out waiting for {description}; last value: {last!r}')


# ---------------------------------------------------------------- demo files

B, D, Y, G, R, X = '\x1b[1m', '\x1b[2m', '\x1b[33m', '\x1b[32m', '\x1b[31m', '\x1b[0m'

TRANSCRIPTS = {
    'plan': f'''{B}●{X} Published Scratchpad {Y}"Checkout mockup"{X} (rev 3).
  {D}Summary card moves above payment; totals stay{X}
  {D}pinned while scrolling on mobile.{X}

{B}●{X} Plan agreed. Ready to build when you are.

{D}› make it a task{X}

{B}●{X} {B}Bash{X}(toastty task create --title checkout-redesign …)
  {D}⎿ Started task checkout-redesign in lumen{X}
  {D}⎿ Its agent works in its own worktree and opens the PR{X}

{B}●{X} Done. checkout-redesign shows in the sidebar.
''',
    'tests': f'''{B}●{X} {B}Bash{X}(npm test -- auth)
  {D}⎿{X} {R}FAIL{X} src/auth/expiry.test.ts
     token expiry › refreshes 30s before expiry
     Expected {G}"refreshed"{X}, received {R}"expired"{X}

{B}●{X} The refresh timer reads the server clock, which drifts
  from the client. Switching it to the token's {Y}exp{X} claim.

{B}●{X} {B}Edit{X} src/auth/refresh.ts {G}+7{X} {R}−4{X}
{B}●{X} {B}Bash{X}(npm test -- auth --runInBand)
''',
    'redesign': f'''{B}●{X} Read the task and the checkout mockup (rev 3).

{B}●{X} {B}Edit{X} src/checkout/SummaryCard.tsx {G}+86{X} {R}−41{X}
{B}●{X} {B}Edit{X} src/checkout/CheckoutPage.tsx {G}+12{X} {R}−30{X}

{B}●{X} {B}Bash{X}(npm test)
  {D}⎿{X} {G}✓ 214 passing{X} {D}(38s){X}

{B}●{X} Captured the checkout at 390 and 1280 px.
{B}●{X} Published verification report: {G}3/3 checks passed{X}
{B}●{X} Opened PR {Y}#128{X} feat/checkout-redesign → main
{B}●{X} Ready for your review.
''',
    'filters': f'''{B}●{X} {B}Edit{X} src/search/FilterBar.tsx {G}+52{X} {R}−9{X}
{B}●{X} {B}Bash{X}(npm test -- search)
  {D}⎿{X} {G}✓ 31 passing{X}

{B}●{X} Old {Y}?q={X} links drop the new filters. Should they
  keep working, or redirect to the new format?
''',
    'icons': f'''{B}●{X} {B}Edit{X} src/sidebar/icons.tsx {G}+40{X} {R}−22{X}
{B}●{X} {B}Bash{X}(npm run build:icons)
''',
    'docs': f'''{B}●{X} {B}Bash{X}(npm run dev)
  {D}⎿ Docs preview at localhost:3000{X}

{B}●{X} The reference pages build cleanly. Three endpoints
  still describe the v1 webhook payload. Want me to update them?
''',
    'infra': f'''{B}●{X} {B}Bash{X}(terraform plan -out staging.plan)
  {D}⎿ Plan: 2 to add, 1 to change, 0 to destroy.{X}

{B}●{X} Applying will rotate the staging API keys.
  {Y}Allow terraform apply staging.plan?{X}
''',
}

CHECKOUT_MOCKUP = '''<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;background:#fbf7ef;color:#2a241b;font:14px/1.5 -apple-system,system-ui,sans-serif;padding:24px}
h1{font-size:20px;margin:0 0 4px}.m{color:#8a7f6f;font-size:12px;margin-bottom:18px}
.row{display:flex;gap:18px;align-items:flex-start}.phone{width:170px;border:6px solid #1c1c1f;border-radius:22px;background:#fff;padding:12px 10px}
.desk{flex:1;border:1px solid #d8cdb9;border-radius:8px;background:#fff;padding:12px}
.sum{border:1px dashed #d8cdb9;border-radius:8px;padding:8px;margin-bottom:10px;background:#fdfaf4;font-size:11px}
.sum div{display:flex;justify-content:space-between}.sum b{font-size:12.5px}
.it{display:flex;gap:8px;align-items:center;margin-bottom:8px}.it i{width:24px;height:24px;border-radius:5px;background:#eadfcb}.it span{height:7px;border-radius:4px;background:#e6ded0;flex:1}
.pay{background:#c9b79b;color:#fff;text-align:center;border-radius:6px;padding:7px 0;font-weight:700;font-size:12px}
ol{color:#5d5346;font-size:13px;padding-left:20px;margin-top:18px}
</style></head><body>
<h1>Checkout mockup</h1><div class="m">rev 3 · mobile and desktop</div>
<div class="row"><div class="phone"><div class="sum"><div><span>Subtotal</span><span>$76.00</span></div><div><span>Shipping</span><span>$8.00</span></div><div><b>Total</b><b>$84.00</b></div></div>
<div class="it"><i></i><span></span></div><div class="it"><i></i><span></span></div><div class="it"><i></i><span></span></div><div class="pay">Pay</div></div>
<div class="desk"><div class="it"><i></i><span></span></div><div class="it"><i></i><span></span></div><div class="sum"><div><span>Subtotal</span><span>$76</span></div><div><b>Total</b><b>$84</b></div></div><div class="pay">Pay</div></div></div>
<ol><li>Summary card first on mobile</li><li>Totals stay pinned while scrolling</li><li>One primary action</li></ol>
</body></html>
'''

# A task's agent: shows the transcript whose key is in its first message and
# waits. The coordinator runs in its folder, <runtime home>/coordinator, and
# gets its own fake.
FAKE_AGENT = r'''#!/bin/sh
case "$1" in
  --version) echo "2.1.288 (Claude Code)"; exit 0 ;;
  plugin|mcp|config) exit 0 ;;
esac
dir="$(dirname "$0")"
case "$PWD" in
  */coordinator) exec /usr/bin/python3 "$dir/fake-coordinator" "$@" ;;
esac
for argument in "$@"; do message="$argument"; done
transcript=""
tab="$(printf '\t')"
while IFS="$tab" read -r key file; do
  case "$message" in *"$key"*) transcript="$file"; break ;; esac
done < "$dir/agent-map.tsv"
printf '\033]2;Claude Code\007\033[2J\033[H'
[ -n "$transcript" ] && cat "$transcript"
while IFS= read -r line; do :; done
'''

# The coordinator: writes the seeded conversation as Claude Code transcript
# records, reports the last turn's hooks so the chat shows it as ended, and
# then ignores what Toastty types, so no new turn changes the chat.
FAKE_COORDINATOR = r'''import json, os, subprocess, sys, time, uuid
here = os.path.dirname(os.path.abspath(__file__))
seed = json.load(open(os.path.join(here, 'coordinator-seed.json')))
session, panel, cli = (os.environ[n] for n in ('TOASTTY_SESSION_ID', 'TOASTTY_PANEL_ID', 'TOASTTY_CLI_PATH'))
native = str(uuid.uuid4())
folder = os.path.join(here, 'coordinator-transcripts')
os.makedirs(folder, exist_ok=True)
transcript = os.path.join(folder, native + '.jsonl')
parent = None
with open(transcript, 'w') as handle:
    for record in seed:
        stamp = time.gmtime(time.time() - record['minutesAgo'] * 60)
        record_id = str(uuid.uuid4())
        base = dict(sessionId=native, uuid=record_id, parentUuid=parent, isSidechain=False,
                    timestamp=time.strftime('%Y-%m-%dT%H:%M:%S.000Z', stamp))
        parent = record_id
        if record['role'] == 'user':
            base.update(type='user', promptId=str(uuid.uuid4()), message=dict(role='user', content=record['text']))
        else:
            base.update(type='assistant', message=dict(role='assistant', model='claude-opus-5', stop_reason='end_turn',
                                                       content=[dict(type='text', text=record['text'])]))
        handle.write(json.dumps(base) + '\n')
def hook(event, **fields):
    subprocess.run([cli, 'session', 'ingest-agent-event', '--source', 'claude-hooks', '--session', session,
                    '--panel', panel], input=json.dumps(dict(hook_event_name=event, session_id=native,
                    transcript_path=transcript, cwd=os.getcwd(), **fields)), text=True, capture_output=True)
hook('SessionStart', source='startup')
last_prompt = [r['text'] for r in seed if r['role'] == 'user'][-1]
hook('UserPromptSubmit', prompt=last_prompt)
hook('Stop')
subprocess.run([cli, 'session', 'status', '--session', session, '--kind', 'idle', '--summary', 'Waiting'],
               capture_output=True)
sys.stdout.write('\x1b]2;Claude Code\x07\x1b[2J\x1b[HToasty is following your tasks.\n')
sys.stdout.flush()
for _ in sys.stdin:
    pass
'''

# Answers Toastty's pull request questions: PR #128 is open, its checks pass.
FAKE_GH = r'''#!/usr/bin/python3
import json, sys
args = sys.argv[1:]
if args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": "lumen-app/lumen", "defaultBranchRef": {"name": "main"},
                      "mergeCommitAllowed": True}))
elif args[:2] == ["pr", "view"]:
    number = int(args[2].rstrip("/").split("/")[-1])
    view = {"number": number, "state": "OPEN", "isDraft": False, "headRefName": "feat/checkout-redesign",
            "headRefOid": "4f2c1d0e9b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d", "baseRefName": "main",
            "isCrossRepository": False, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
            "statusCheckRollup": [{"name": n, "status": "COMPLETED", "conclusion": "SUCCESS"}
                                  for n in ("build", "test", "lint", "e2e")],
            "url": f"https://github.com/lumen-app/lumen/pull/{number}", "body": "",
            "title": "Redesign the checkout summary card", "mergeCommit": None, "autoMergeRequest": None}
    if "--jq" in args:
        print(view[args[args.index("--jq") + 1].lstrip(".")])
    else:
        print(json.dumps(view))
elif args[:2] == ["auth", "status"]:
    print("Logged in to github.com")
else:
    sys.exit(f"fake gh: unexpected call {args}")
'''


def git(*arguments, cwd):
    subprocess.run(['git', '-c', 'user.name=Lumen Demo', '-c', 'user.email=demo@example.com',
                    '-c', 'init.defaultBranch=main', *arguments], cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def write_demo_home(home, demo):
    for directory in (demo / 'bin', demo / 'transcripts', home / '.config/ghostty', home / '.toastty',
                      home / 'origin'):
        directory.mkdir(parents=True, exist_ok=True)
    (home / '.config/ghostty/config').write_text(
        'font-size = 13\nbackground = #141416\nforeground = #d9d5cd\nwindow-padding-x = 14\nwindow-padding-y = 10\n')
    # The login shell keeps HOME at the real home but honors ZDOTDIR. The fake
    # gh goes first on PATH in .zprofile, which runs after /etc/zprofile's
    # path_helper; the app takes PATH from a login shell.
    (home / '.zprofile').write_text(f'export PATH="{demo / "bin"}:$PATH"\n')
    (home / '.zshrc').write_text("PROMPT='%F{244}%1~%f %F{214}❯%f '\n")
    for repo in ('lumen', 'docs-site', 'infra'):
        path = home / 'code' / repo
        path.mkdir(parents=True)
        git('init', '-q', cwd=path)
        (path / 'README.md').write_text(f'# {repo}\n')
        git('add', '.', cwd=path)
        git('commit', '-q', '-m', 'Initial commit', cwd=path)
    # Tasks start work from origin's main, so lumen gets a local origin.
    git('clone', '-q', '--bare', str(home / 'code/lumen'), str(home / 'origin/lumen.git'), cwd=home)
    git('remote', 'add', 'origin', str(home / 'origin/lumen.git'), cwd=home / 'code/lumen')
    git('fetch', '-q', 'origin', cwd=home / 'code/lumen')

    for name, text in TRANSCRIPTS.items():
        # An OSC 2 sequence first, so the pane's title names the agent.
        title = 'Codex' if name == 'docs' else 'Claude Code'
        (demo / 'transcripts' / f'{name}.txt').write_text(f'\x1b]2;{title}\x07' + text)
    (demo / 'checkout-mockup.html').write_text(CHECKOUT_MOCKUP)
    for name, text, mode in (('claude', FAKE_AGENT, 0o755), ('fake-coordinator', FAKE_COORDINATOR, 0o644),
                             ('gh', FAKE_GH, 0o755)):
        (demo / 'bin' / name).write_text(text)
        (demo / 'bin' / name).chmod(mode)
    (home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(demo / "bin/claude")])}\n')
    (home / '.toastty/tasks.toml').write_text(
        '[defaults]\nagent = "claude"\nmodel = "opus"\neffort = "high"\n')


# ---------------------------------------------------------------- the app

def defaults_suite(runtime_home):
    """Toastty keeps a runtime-isolated instance's settings in a defaults
    domain named for an FNV-1a hash of its runtime home (ToasttyRuntimePaths)."""
    value = 0xcbf29ce484222325
    for byte in str(runtime_home).encode():
        value = ((value ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return 'com.GiantThings.toastty.runtime.%016x' % value


class Demo:
    def __init__(self, app, out, tools):
        self.app, self.out, self.tools = app, out, tools
        self.home = out / 'home'
        self.demo = self.home / '.demo'
        self.runtime = out / 'runtime'
        self.raw = out / 'raw'
        self.binary = app / 'Contents/MacOS/Toastty'
        self.cli = app / 'Contents/Helpers/toastty'
        # A private, short temporary directory: the app writes its socket
        # and the shared socket discovery record under TMPDIR, so the
        # user's TMPDIR would redirect their CLI to the demo. Unix socket
        # paths are limited to 104 bytes, which rules out --out.
        self.tmp = Path(tempfile.mkdtemp(prefix='toastty-demo.', dir='/tmp'))
        self.process = None
        self.socket_path = None
        self.layout = {}

    def launch(self):
        self.raw.mkdir(parents=True)
        self.runtime.mkdir(parents=True)
        environment = dict(
            HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), ZDOTDIR=str(self.home),
            USER=os.environ.get('USER', 'demo'), LOGNAME=os.environ.get('USER', 'demo'),
            PATH='/usr/bin:/bin:/usr/sbin:/sbin', SHELL='/bin/zsh', TMPDIR=f'{self.tmp}/', LANG='en_US.UTF-8',
            TOASTTY_RUNTIME_HOME=str(self.runtime),
            TOASTTY_GHOSTTY_CONFIG_PATH=str(self.home / '.config/ghostty/config'),
            # Automation mode lets the app draw its own windows into PNGs.
            TOASTTY_AUTOMATION='1', TOASTTY_RUN_ID='demo', TOASTTY_ARTIFACTS_DIR=str(self.out / 'frames'),
        )
        arguments = [
            # Skip the first-launch question and the one-time skills banner.
            '-toastty.coordinator.startOfferAnswered', 'YES',
            '-toastty.claudeSkillsProvisionedNoticeDidShow', 'YES',
            '-toastty.codexSkillsProvisionedNoticeDidShow', 'YES',
        ]
        self.log = open(self.out / 'app.log', 'w')
        self.process = subprocess.Popen([str(self.binary), *arguments], cwd=self.home, env=environment,
                                        stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT)

        def instance():
            if self.process.poll() is not None:
                fail(f'the demo app exited during startup; see {self.out / "app.log"}')
            try:
                record = json.loads((self.runtime / 'instance.json').read_text())
            except (OSError, ValueError):
                return None
            return record if record.get('pid') == self.process.pid else None

        record = wait_for('the demo app to report its instance', instance, timeout=60)
        self.socket_path = record['socketPath']
        if not self.socket_path.startswith(str(self.tmp)):
            fail(f'unexpected socket path {self.socket_path}')
        wait_for('the socket', lambda: os.path.exists(self.socket_path), timeout=30)
        wait_for('the first workspace', lambda: self.query('workspace.list', check=False), timeout=60)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        shutil.rmtree(self.tmp, ignore_errors=True)
        suite = defaults_suite(self.runtime)
        subprocess.run(['defaults', 'delete', suite], capture_output=True)
        # cfprefsd leaves an empty plist behind after the domain is deleted.
        Path.home().joinpath('Library/Preferences', suite + '.plist').unlink(missing_ok=True)

    # The app's socket, directly and through the CLI.

    def request(self, command, payload, timeout=60):
        envelope = dict(protocolVersion='1.0', kind='request', requestID=str(uuid.uuid4()),
                        command=command, payload=payload)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(self.socket_path)
            connection.sendall(json.dumps(envelope).encode() + b'\n')
            data = b''
            while b'\n' not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
        return json.loads(data)

    def query(self, query_id, check=True, **args):
        response = self.request('app_control.run_query', dict(id=query_id, args=args))
        if not response.get('ok'):
            if check:
                fail(f'{query_id} failed: {response}')
            return None
        return response['result']

    def cli_json(self, *arguments, session=None, check=True):
        environment = dict(HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), TMPDIR=f'{self.tmp}/',
                           PATH='/usr/bin:/bin')
        if session:
            environment['TOASTTY_SESSION_ID'] = session
        result = subprocess.run([str(self.cli), '--socket-path', self.socket_path, '--json', *arguments],
                                env=environment, capture_output=True, text=True, timeout=180)
        try:
            response = json.loads(result.stdout)
        except ValueError:
            response = dict(ok=False, error=result.stdout + result.stderr)
        if result.returncode != 0 or response.get('ok') is False:
            if check:
                fail(f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
            return None
        return response.get('result') or {}

    def action(self, action_id, *pairs, **options):
        return self.cli_json('action', 'run', action_id, *pairs, **options)

    # Accessibility, for what the socket cannot do: menus, buttons, typing.

    def ax(self, *arguments, check=True):
        result = subprocess.run([str(self.tools / 'ax-drive'), str(self.process.pid), *map(str, arguments)],
                                capture_output=True, text=True, timeout=60)
        if check and result.returncode != 0:
            fail(f'ax-drive {" ".join(map(str, arguments))} failed ({result.returncode}): '
                 f'{result.stdout.strip()} {result.stderr.strip()}')
        return result.stdout.strip()

    def right_panel_frame(self):
        """The right panel's frame. Its identifier names its workspace and
        tab: right-panel.<workspace ID>.<tab ID>."""
        dump = subprocess.run([str(self.tools / 'ui-helper'), 'dump', str(self.process.pid)],
                              capture_output=True, text=True, timeout=60).stdout
        for line in dump.splitlines():
            identifier = line.split(' id=', 1)[1].split(' ', 1)[0] if ' id=' in line else ''
            parts = identifier.split('.')
            if len(parts) == 3 and parts[0] == 'right-panel' and all(len(p) == 36 for p in parts[1:]):
                origin, size = line.rsplit('frame=', 1)[1].split()
                x, y = map(float, origin.split(','))
                width, height = map(float, size.split('x'))
                return dict(x=x, y=y, width=width, height=height)
        (self.raw / 'ax-dump.txt').write_text(dump)
        fail('no right panel in the window; see raw/ax-dump.txt')

    def select_tasks_row(self, title):
        """Selects the Tasks view's row for `title` with the Down Arrow key, as
        a user can: the view starts on its first row. Keys, unlike a click,
        reach the app even when a system alert covers part of the screen."""
        dump = subprocess.run([str(self.tools / 'ui-helper'), 'dump', str(self.process.pid)],
                              capture_output=True, text=True, timeout=60).stdout
        rows = []
        for line in dump.splitlines():
            if ' id=tasks.view.row title=' in line:
                label = line.split(' title=', 1)[1].rsplit(' frame=', 1)[0]
                y = float(line.rsplit('frame=', 1)[1].split()[0].split(',')[1])
                rows.append((y, label))
        labels = [label for _, label in sorted(rows)]
        index = next((i for i, label in enumerate(labels) if label.startswith(title + ',')), None)
        if index is None:
            (self.raw / 'ax-dump.txt').write_text(dump)
            fail(f'no Tasks view row for {title} in {labels}; see raw/ax-dump.txt')
        self.ax('activate')
        for _ in range(index):
            self.ax('key', 'down')
            time.sleep(0.3)

    def frame(self, identifier):
        text = self.ax('frame', identifier, check=False)
        try:
            x, y, width, height = map(float, text.split())
        except ValueError:
            return None
        return dict(x=x, y=y, width=width, height=height)

    # Captures.

    def capture(self, name, window=None, frame=True, settle=1.5):
        time.sleep(settle)
        payload = dict(step=name, frame=frame)
        if window:
            payload['window'] = window
        response = self.request('automation.capture_screenshot', payload)
        if not response.get('ok'):
            fail(f'capture {name} failed: {response}')
        shutil.copyfile(response['result']['path'], self.raw / f'{name}.png')
        print(f'[demo] captured {name}', flush=True)


# ---------------------------------------------------------------- demo state

def build_demo(demo):
    home, files = demo.home, demo.demo

    def code(name):
        return home / 'code' / name

    def snapshot(workspace):
        return demo.query('workspace.snapshot', workspaceID=workspace)

    def focused_panel(workspace):
        return snapshot(workspace)['focusedPanelID']

    def run_in(panel, transcript, directory):
        """Shows a transcript in a pane and keeps its shell busy, so the
        fake session is not ended for sitting at a prompt. A new pane takes
        a moment to accept input."""
        command = (f"cd '{code(directory)}' && clear && cat '{files / 'transcripts' / (transcript + '.txt')}'"
                   f" && sleep 86400")
        wait_for(f'pane {panel} to accept input', lambda: demo.cli_json(
            'action', 'run', 'terminal.send-text', '--panel', panel, f'text={command}', 'submit=true',
            check=False) is not None, timeout=30, interval=0.5)

    def session(panel, session_id, name, directory, agent='claude'):
        """A fake session in a pane, named through a Claude-style transcript
        title record, the source Toastty reads for a real Claude Code session."""
        native = str(uuid.uuid4())
        transcript = files / f'{session_id}.jsonl'
        transcript.write_text(json.dumps(dict(type='ai-title', aiTitle=name, sessionId=native)) + '\n')
        demo.cli_json('session', 'start', '--agent', agent, '--panel', panel, '--session', session_id,
                      '--cwd', str(code(directory)))
        event = dict(hook_event_name='SessionStart', session_id=native, transcript_path=str(transcript),
                     cwd=str(code(directory)), source='startup')
        subprocess.run([str(demo.cli), '--socket-path', demo.socket_path, '--json', 'session', 'ingest-agent-event',
                        '--source', 'claude-hooks', '--session', session_id, '--panel', panel],
                       input=json.dumps(event), text=True, capture_output=True,
                       env=dict(HOME=str(home), TMPDIR=f'{demo.tmp}/', PATH='/usr/bin:/bin'))
        status(session_id, 'working', 'Thinking', panel=panel)

    def status(session_id, kind, text, panel=None):
        # Session rows show the detail line; task rows fall back to the
        # summary, so both carry the same text.
        arguments = ['session', 'status', '--session', session_id, '--kind', kind, '--summary', text, '--detail', text]
        if panel:
            arguments += ['--panel', panel]
        demo.cli_json(*arguments)

    workspaces = demo.query('workspace.list')['workspaces']
    window_id, lumen = workspaces[0]['windowID'], workspaces[0]['workspaceID']
    demo.ax('activate')
    demo.ax('window-set-frame', 60, 60, *WINDOW_SIZE)
    demo.action('workspace.rename', '--workspace', lumen, 'title=lumen')

    # lumen: a planning session above a session fixing a test, and the
    # plan's mockup in the right panel.
    plan_panel = focused_panel(lumen)
    run_in(plan_panel, 'plan', 'lumen')
    wait_for('lumen to be a project', lambda: any(
        os.path.realpath(c) == str(code('lumen').resolve()) for c in
        next(w for w in demo.query('workspace.list')['workspaces'] if w['workspaceID'] == lumen)['terminalCwds']),
        timeout=60)
    session(plan_panel, 'demo-plan', 'Plan checkout redesign', 'lumen')
    demo.action('workspace.split.down', '--workspace', lumen)
    tests_panel = focused_panel(lumen)
    run_in(tests_panel, 'tests', 'lumen')
    session(tests_panel, 'demo-tests', 'Fix flaky auth test', 'lumen')
    demo.action('panel.scratchpad.set-content', 'sessionID=demo-plan', 'title=Checkout mockup',
                f'filePath={files / "checkout-mockup.html"}')

    # Tasks in lumen, each with a fake agent that shows its transcript.
    tasks = {}
    agent_map = []
    for title, text, transcript in (
        ('checkout-redesign', 'Build the checkout redesign from the mockup. Check it at 390 and 1280 px.', 'redesign'),
        ('search-filters', 'Add price and rating filters to search.', 'filters'),
        ('sidebar-icons', 'Refresh the sidebar icons for dark mode.', 'icons'),
    ):
        agent_map.append(f'{text}\t{files / "transcripts" / (transcript + ".txt")}')
        (files / 'bin/agent-map.tsv').write_text('\n'.join(agent_map) + '\n')
        task = demo.cli_json('task', 'create', text, '--workspace', lumen, '--title', title,
                             '--agent', 'claude', '--model', 'opus', '--effort', 'high',
                             '--start-work', '--branch-prefix', 'feat', '--wait', '--timeout', '120')
        tasks[title] = task
        # Toastty ignores an idle or ready report until the agent reported
        # that it works: some agents report idle when they start.
        status(task['setup']['sessionID'], 'working', 'Reading the task')
        print(f'[demo] task {title}: {task["taskID"]}', flush=True)

    redesign, filters, icons = tasks['checkout-redesign'], tasks['search-filters'], tasks['sidebar-icons']
    # The finished turns arrive while lumen shows, so they stay unread.
    demo.action('workspace.select', '--workspace', lumen)
    time.sleep(0.5)
    status(icons['setup']['sessionID'], 'working', 'Editing icons.tsx')
    status(filters['setup']['sessionID'], 'ready', 'Asks: keep old ?q= links working?')
    status(redesign['setup']['sessionID'], 'ready', 'Ready for review')
    demo.action('workspace.set-annotation', '--workspace', redesign['setup']['taskSpaceWorkspaceID'],
                'key=github-pr', 'text=PR #128', 'url=https://github.com/lumen-app/lumen/pull/128', 'primary=true')

    def stage(task):
        return demo.cli_json('task', 'get', task['taskID'])['stage']

    wait_for('checkout-redesign to wait for review', lambda: stage(redesign).get('attention') == 'review', timeout=60)
    wait_for('search-filters to need you', lambda: stage(filters).get('group') == 'needsYou', timeout=60)

    # Two other projects, with plain sessions.
    def new_workspace(title):
        created = demo.action('workspace.create', '--window', window_id, f'title={title}', 'activate=false')
        return created.get('workspaceID') or next(
            w['workspaceID'] for w in demo.query('workspace.list')['workspaces'] if w['title'] == title)

    docs = new_workspace('docs-site')
    docs_panel = focused_panel(docs)
    run_in(docs_panel, 'docs', 'docs-site')
    session(docs_panel, 'demo-docs', 'Update API reference', 'docs-site')
    infra = new_workspace('infra')
    infra_panel = focused_panel(infra)
    run_in(infra_panel, 'infra', 'infra')
    session(infra_panel, 'demo-infra', 'Rotate staging keys', 'infra')
    status('demo-infra', 'needs_approval', 'Allow terraform apply staging.plan?', panel=infra_panel)
    status('demo-tests', 'working', 'Running auth tests…', panel=tests_panel)
    status('demo-plan', 'idle', 'Plan agreed · mockup rev 3', panel=plan_panel)
    status('demo-docs', 'idle', 'Updated the preview', panel=docs_panel)

    # The coordinator, with a conversation about the checkout task.
    link = f'[checkout-redesign](toastty://task/{redesign["taskID"]})'
    filters_link = f'[search-filters](toastty://task/{filters["taskID"]})'
    now = datetime.datetime.now(datetime.timezone.utc)
    # Earlier turns come first, so the chat opens scrolled to its latest
    # messages, as a coordinator that has run for a while does.
    seed = [
        dict(role='user', minutesAgo=200, text='Did the nightly e2e run pass?'),
        dict(role='assistant', minutesAgo=200, text='Yes. All four suites passed on main at 6:10.'),
        dict(role='user', minutesAgo=160, text='Morning. What needs me today?'),
        dict(role='assistant', minutesAgo=160, text=(
            'Two things. In infra, **Rotate staging keys** waits for your approval to apply `staging.plan`. '
            'In docs-site, three API pages still describe the v1 webhook payload. Nothing in lumen waits for you.')),
        dict(role='user', minutesAgo=150, text='Have docs-site update the webhook pages. I\'ll do the approval after lunch.'),
        dict(role='assistant', minutesAgo=150, text=(
            'Sent. I\'ll tell you when the docs preview shows the v2 payload.')),
        dict(role='user', minutesAgo=34, text=(
            'Build the checkout redesign from the mockup in lumen. Check it at 390 and 1280 px.')),
        dict(role='assistant', minutesAgo=34, text=(
            f'I made {link} in lumen with Claude Code, opus at high effort. I\'ll tell you when it\'s ready.')),
        dict(role='user', minutesAgo=6, text='\n'.join([
            '[Toastty] Wake: this message is from Toastty, not from the user.',
            f'- {link}: needsYou (review) at {(now - datetime.timedelta(minutes=6)).isoformat(timespec="seconds")}',
            f'- {filters_link}: needsYou (agentFinished) at '
            f'{(now - datetime.timedelta(minutes=7)).isoformat(timespec="seconds")}',
            'Read `toastty task list` for details.'])),
        dict(role='assistant', minutesAgo=6, text=(
            f'{link} is ready for your review: its report shows the summary card above payment at 390 px '
            'with the totals pinned, and all 4 checks passed. PR #128.\n\n'
            f'{filters_link} asks whether old `?q=` links should keep working.')),
    ]
    (files / 'bin/coordinator-seed.json').write_text(json.dumps(seed))
    demo.cli_json('coordinator', 'open', '--no-select')
    wait_for('the coordinator at its prompt', lambda: (demo.cli_json('coordinator', 'status', check=False) or {})
             .get('status') in ('idle', 'ready'), timeout=120, interval=1)

    # Visiting the other projects clears their "New" badges.
    for workspace in (docs, infra, lumen):
        demo.action('workspace.select', '--workspace', workspace)
        time.sleep(0.5)
    demo.action('workspace.focus-panel', '--workspace', lumen, f'panelID={plan_panel}')
    return dict(window=window_id, lumen=lumen, tasks={k: v['taskID'] for k, v in tasks.items()})


def capture_all(demo, ids):
    demo.ax('activate')
    window = demo.ax('window-frame').split()
    demo.layout['window'] = dict(zip(('x', 'y', 'width', 'height'), map(float, window)))

    # 1. The lumen project, with the Scratchpad in the right panel.
    demo.capture('window', settle=4)
    for identifier in ('sidebar.segment.all', 'sidebar.segment.needsYou', 'sidebar.workspace.2'):
        demo.layout[identifier] = demo.frame(identifier)
    demo.layout['right-panel'] = demo.right_panel_frame()

    # 2. The coordinator's chat in its dock beside lumen. The title bar's
    # Toasty button opens and hides it.
    demo.ax('click', 'titlebar.toggle.coordinator-dock')
    wait_for('the dock', lambda: demo.frame('coordinator.dock'), timeout=15, interval=0.5)
    demo.capture('coordinator-dock', settle=3)
    demo.ax('click', 'titlebar.toggle.coordinator-dock')
    wait_for('the dock to close', lambda: demo.frame('coordinator.dock') is None, timeout=15, interval=0.5)

    # 3. The Tasks view, with checkout-redesign selected.
    demo.action('window.tasks.show', '--window', ids['window'])
    time.sleep(1.5)
    demo.select_tasks_row('checkout-redesign')
    demo.capture('tasks-view', settle=2)
    demo.action('window.tasks.hide', '--window', ids['window'])

    # 4. Quick entry with a message for the coordinator.
    demo.ax('menu', 'File', 'New Task…')
    wait_for('the quick entry panel', lambda: demo.request('automation.capture_screenshot', dict(
        step='quick-entry-probe', window='quick-entry.panel')).get('ok'), timeout=15, interval=0.5)
    demo.ax('type', 'The coupon row hides under the totals bar at 390 px.')
    demo.capture('quick-entry', window='quick-entry.panel', frame=False, settle=1)
    demo.ax('key', 'escape', check=False)
    (demo.raw / 'layout.json').write_text(json.dumps(demo.layout, indent=2))


# ---------------------------------------------------------------- crops

def post_process(out, tools):
    raw = out / 'raw'
    layout = json.loads((raw / 'layout.json').read_text())
    subprocess.run([str(tools / 'demo-images'), str(raw), str(out)], check=True,
                   input=json.dumps(layout), text=True)


def build_tools(tools, hidpi):
    tools.mkdir(parents=True, exist_ok=True)
    subprocess.run(['swiftc', '-O', str(ROOT / 'scripts/automation/ax-drive.swift'), '-o', str(tools / 'ax-drive')],
                   check=True)
    subprocess.run(['swiftc', '-O', str(ROOT / 'scripts/automation/task-stages-ui-helper.swift'),
                    '-o', str(tools / 'ui-helper')], check=True)
    subprocess.run(['swiftc', '-O', str(HERE / 'demo-images.swift'), '-o', str(tools / 'demo-images')], check=True)
    if hidpi:
        subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'CoreGraphics',
                        str(HERE / 'hidpi-display.m'), '-o', str(tools / 'hidpi-display')], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', required=True, help='Toastty.app to launch')
    parser.add_argument('--out', required=True, help='new or empty output directory')
    parser.add_argument('--keep', action='store_true', help='leave the demo app running after capturing')
    parser.add_argument('--hidpi-display', metavar='WIDTHxHEIGHT',
                        help='add a temporary 2x display of that size in points, such as 1600x1000')
    parser.add_argument('--crop-only', action='store_true',
                        help='only crop the captures in --out/raw again')
    options = parser.parse_args()
    out = Path(options.out).resolve()
    tools = out / 'tools'
    if options.crop_only:
        build_tools(tools, False)
        post_process(out, tools)
        return
    if out.exists() and any(out.iterdir()):
        fail(f'{out} is not empty; pass a new --out directory')
    app = Path(options.app).resolve()
    if not (app / 'Contents/MacOS/Toastty').is_file():
        fail(f'Toastty.app not found at {app}')
    out.mkdir(parents=True, exist_ok=True)
    build_tools(tools, options.hidpi_display)

    status = subprocess.run([str(tools / 'ax-drive'), str(os.getpid()), 'status'],
                            capture_output=True, text=True).stdout.split()
    if 'trusted=true' not in status or 'locked=false' not in status:
        fail(f'needs Accessibility permission and an unlocked screen: {" ".join(status)}')

    display = None
    demo = None
    try:
        if options.hidpi_display:
            width, height = options.hidpi_display.lower().split('x')
            display = subprocess.Popen([str(tools / 'hidpi-display'), width, height, '1800'],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            line = display.stdout.readline()
            if not line:
                fail('the HiDPI display did not start')
            print(f'[demo] display {line.strip()}', flush=True)
            time.sleep(2)
        write_demo_home(out / 'home', out / 'home/.demo')
        demo = Demo(app, out, tools)
        demo.launch()
        ids = build_demo(demo)
        capture_all(demo, ids)
        (out / 'demo.json').write_text(json.dumps(ids, indent=2))
    finally:
        if demo and not options.keep:
            demo.stop()
        if display and not options.keep:
            display.stdin.close()
            display.wait(timeout=10)
    post_process(out, tools)
    print(f'[demo] wrote {", ".join(sorted(p.name for p in out.glob("*.png")))} to {out}', flush=True)


if __name__ == '__main__':
    main()

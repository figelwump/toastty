#!/usr/bin/env python3
"""Create the first tasks on a fresh install, through the CLI, the real quick
entry panel and the real Claude CLI as the coordinator.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-fresh-install-check.py --gui-session'.
The run uses subscription usage, takes about ten minutes, and needs the
remote Mac's screen unlocked.

A fresh install has no ~/.toastty/agents.toml and no ~/.toastty/tasks.toml.
The check starts its own instance of the wrapper's build, with a throwaway
runtime home and a throwaway user home that has neither file, and does not
answer the first-launch question in advance. It reuses the setup of
remote-coordinator-quick-entry-check.py: `claude` on the instance's PATH is
the real, authenticated Claude CLI in the coordinator's folder and a fake
task agent anywhere else; GitHub is a fake `gh`. The other agents installed
on the remote Mac stay on the PATH, as on a user's Mac. The user home is a
git repository, so the first workspace starts in a project.

Every action a person makes goes through the real UI: the first-launch
question, File > New Task…, the quick entry keys and Agent > Open
Coordinator. Each surface is a check of its own and the check goes on after
one fails, so a build from before the fix shows where each surface stops.
From the task records, the task agents' events and Claude's transcript it
proves that:
- the first launch asks whether to start the coordinator, and Not Now
  starts nothing;
- `toastty task create` with no agent creates a task, and it starts with
  Claude Code; so does `toastty task create --agent claude`;
- an agent that is not installed fails at once and names the installed
  agents;
- the quick entry panel starts on Claude Code and Command+Return creates the
  task, which starts;
- the coordinator, sent a request from quick entry with the project chosen
  and the agent left to it, creates a task that starts.

Evidence goes to the artifacts directory under remote-fresh-install-check:
result.json, the app log, Claude's transcript, the task agents' events and,
when the build can capture its windows, PNG frames under frames/.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
NAME = 'remote-fresh-install-check'
QUESTION = 'Start the coordinator?'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


qe = load('quick_entry_check', 'remote-coordinator-quick-entry-check.py')
skill, steer = qe.skill, qe.steer
require, wait_for = qe.require, qe.wait_for


def say(*parts):
    print(f'[{NAME}]', *parts, flush=True)


class Run(qe.Run):
    """The quick entry check's app instance, as a fresh install."""

    def write_tools(self):
        super().write_tools()
        # The dispatcher stays first on the PATH as `claude`; the profile
        # that points at it goes, with the rest of ~/.toastty.
        shutil.rmtree(self.user_home / '.toastty')
        # The app makes the coordinator's folder when it starts the
        # coordinator, and asks the first-launch question only before that.
        shutil.rmtree(self.folder)
        subprocess.run(['git', 'init', '-q', str(self.user_home)], check=True)

    def write_config(self):
        """A fresh install has no tasks.toml."""

    def start_instance(self):
        self.environment['TOASTTY_EVIDENCE_DIR'] = str(self.frames)
        # No answer to the first-launch question in advance.
        self.instance = skill.Instance(self.binary, self.environment, self.environment['TOASTTY_SOCKET_PATH'],
                                       self.runtime_home, self.artifacts / 'app.log', arguments=())
        self.workspaces = self.instance.wait_until_ready()
        self.pid = self.instance.process.pid
        self.ui = qe.UI(self.artifacts, self.pid)

    def task(self, task_id):
        return self.cli('task', 'get', task_id)

    def started(self, task_id, timeout=120):
        """The task once its setup ends, and whether its agent started."""
        record = wait_for('the task setup to end', lambda: (lambda t: t if t['setup']['state'] != 'settingUp' else None)(
            self.task(task_id)), timeout=timeout)
        session = record.get('sessionID')
        agent_started = session is not None and wait_for(
            'the task agent to start', lambda: any(e['event'] == 'started' and e['session'] == session
                                                   for e in self.agent_events()), timeout=30)
        return record, agent_started

    def summary(self, record):
        return {key: record.get(key) for key in ('taskID', 'title', 'source', 'agent', 'model', 'effort', 'projectRoot')} | dict(
            setup=record['setup']['state'], setupReason=record['setup'].get('reason'))

    def tool_results(self, fragment):
        """The output of the coordinator's commands that contain `fragment`."""
        found = []
        for record in self.records():
            content = (record.get('message') or {}).get('content')
            for part in content if isinstance(content, list) else []:
                if isinstance(part, dict) and part.get('type') == 'tool_result':
                    inner = part.get('content')
                    text = inner if isinstance(inner, str) else '\n'.join(
                        p.get('text', '') for p in inner or [] if isinstance(p, dict))
                    if fragment in text:
                        found.append(text[-800:])
        return found


def run_check(run):
    step, check, ui = run.step, run.check, run.ui
    _, trust = ui.ax('status')
    require('trusted=true' in trust and 'locked=false' in trust,
            f'The UI driver cannot act: {trust}. Unlock the screen, or run with --gui-session over SSH')
    toastty = run.user_home / '.toastty'
    workspace = run.workspaces[0]
    workspace_id, title = workspace['workspaceID'], workspace['title']

    def known():
        return {task['taskID'] for task in run.tasks_now()}

    # 0. The first launch asks about the coordinator; Not Now starts nothing.
    def question():
        code, output = ui.ax('sheet-texts', check=False)
        return output if code == 0 and QUESTION in output else ''

    # The app asks when its window first gets the keyboard.
    ui.activate()
    asked = wait_for('the first-launch question', question, timeout=60)
    # Keep the window clear of the right half of the screen, where a system
    # prompt can wait for the user.
    ui.ax('window-set-frame', '-100', '40', '980', '1000', check=False)
    run.capture('first-launch-question')
    ui.ax('click-label', 'Not Now')
    wait_for('the question to go', lambda: not question(), timeout=30)
    check('a fresh install: no agents.toml and no tasks.toml',
          not (toastty / 'agents.toml').exists() and not (toastty / 'tasks.toml').exists(),
          sorted(p.name for p in toastty.iterdir()) if toastty.is_dir() else [])
    check('Not Now started no coordinator', not run.coordinator().get('exists'), run.coordinator())
    step('the first launch asked about the coordinator', question=asked, workspace=workspace)

    # 1. The CLI, with no agent and with --agent claude.
    for name, extra in (('no agent', []), ('--agent claude', ['--agent', 'claude'])):
        done = run.run_cli('task', 'create', f'First task from the CLI, {name}', '--workspace', workspace_id, *extra,
                           '--wait', '--timeout', '120')
        output = (done.stdout + done.stderr).strip()
        created = done.returncode == 0 and (json.loads(done.stdout).get('result') or {}).get('taskID')
        record, agent_started = run.started(created) if created else (None, False)
        check(f'toastty task create with {name} creates a task that starts with Claude Code',
              bool(record) and record['agent'] == 'claude' and record['setup']['state'] == 'started' and agent_started,
              run.summary(record) if record else output[-600:])
        step(f'CLI task create, {name}', exit=done.returncode, task=run.summary(record) if record else None,
             output=None if record else output[-600:])

    # An agent that is not installed fails at once and names the installed ones.
    before = known()
    done = run.run_cli('task', 'create', 'Not for an absent agent', '--workspace', workspace_id, '--agent', 'nosuchagent')
    output = (done.stdout + done.stderr).strip()
    check('an agent that is not installed fails at once and names the installed agents',
          done.returncode != 0 and 'available: claude' in output and known() == before, output[-600:])
    step('CLI task create with an absent agent', exit=done.returncode, output=output[-600:])

    # 2. Quick entry, opened from the menu as a new user finds it.
    before = known()
    run.select(workspace_id)
    ui.activate()
    ui.ax('menu', 'File', 'New Task…')
    wait_for('the quick entry panel', lambda: ui.has_window(qe.PANEL), timeout=20)
    state = run.panel_state() | dict(hint=ui.value('quick-entry.missing-choice'))
    run.capture('quick-entry-open')
    ui.key(qe.KEY_2, 'cmd')
    wait_for('the Agent list', lambda: ui.has_window(qe.PICKER), timeout=15)
    time.sleep(0.5)
    _, agent_list = ui.ax('texts', qe.PICKER, check=False)
    run.capture('quick-entry-agent-list')
    ui.key(qe.KEY_ESCAPE)
    wait_for('the Agent list to close', lambda: not ui.has_window(qe.PICKER), timeout=15)
    check('quick entry starts on Claude Code in the workspace',
          state['agent'] == 'Claude Code' and state['workspace'] == title and not state['hint'], state)
    check('the Agent list offers Claude Code', 'Claude Code' in agent_list, agent_list[-600:])
    ui.type('First task from quick entry')
    wait_for('the typed text', lambda: ui.value('quick-entry.text') == 'First task from quick entry', timeout=20)
    run.capture('quick-entry-typed')
    ui.key(qe.KEY_RETURN, 'cmd')
    try:
        wait_for('the panel to close', ui.panel_closed, timeout=15)
    except AssertionError:
        run.capture('quick-entry-not-created')
        ui.key(qe.KEY_ESCAPE)
    new = [task for task in run.tasks_now() if task['taskID'] not in before]
    record, agent_started = run.started(new[0]['taskID']) if len(new) == 1 else (None, False)
    check('Command+Return created the task, and it starts with Claude Code',
          bool(record) and record['source'] == 'quickEntry' and record['agent'] == 'claude'
          and record['setup']['state'] == 'started' and agent_started,
          run.summary(record) if record else dict(panelOpen=ui.has_window(qe.PANEL), tasks=len(new)))
    step('quick entry', panel=state, agentList=agent_list[-600:], task=run.summary(record) if record else None)

    # 3. The coordinator, from the Agent menu; the request from quick entry,
    # with the project chosen and the agent left to the coordinator.
    ui.activate()
    ui.ax('menu', 'Agent', 'Open Coordinator')
    wait_for('the coordinator to run', lambda: run.coordinator().get('agentState') == 'running', timeout=60)
    ui.dismiss_notice()
    run.wait_idle(timeout=240)
    run.seen_turns = len(run.turns())
    before = known()
    request = 'Add a --verbose flag to the import command. It should print each file it reads.'
    ui.activate()
    ui.ax('menu', 'File', 'New Task…')
    wait_for('the quick entry panel', lambda: ui.has_window(qe.PANEL), timeout=20)
    run.pick(qe.KEY_1, typed=title)
    to_coordinator = run.panel_state()
    ui.type(request)
    wait_for('the typed text', lambda: ui.value('quick-entry.text') == request, timeout=20)
    run.capture('to-coordinator')
    ui.key(qe.KEY_RETURN, 'cmd')
    wait_for('the panel to close', ui.panel_closed, timeout=20)
    turns = run.new_turns(wake=False)
    new = [task for task in run.tasks_now() if task['taskID'] not in before]
    record, agent_started = run.started(new[0]['taskID']) if new else (None, False)
    commands = [c for turn in turns for c in turn['commands'] if 'task create' in c]
    check('the coordinator created a task from the request, and it starts with Claude Code',
          bool(record) and record['agent'] == 'claude' and record['setup']['state'] == 'started' and agent_started,
          dict(task=run.summary(record) if record else None, commands=commands, said=run.said(turns)[-800:]))
    run.capture('coordinator-done')
    step('coordinator', panel=to_coordinator, commands=commands, results=run.tool_results('task')[-3:],
         task=run.summary(record) if record else None, said=run.said(turns)[-1200:])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        qe.run_in_gui_session([argument for argument in sys.argv[1:] if argument != '--gui-session'],
                              name=NAME, script=__file__)
    # A fresh install names no coordinator model or effort.
    options.model = options.effort = None

    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR']) / NAME
    artifacts.mkdir(parents=True, exist_ok=True)
    host = {key: value for key, value in os.environ.items()
            if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    claude = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
    require(Path(claude).is_file(), 'Claude CLI is not installed; install and authenticate it on the remote host')
    version = subprocess.check_output([claude, '--version'], text=True, timeout=30, env=host).strip()
    say('plan', json.dumps(dict(claude=version, path=host.get('PATH'))))

    run = Run(options, artifacts, bundle, claude)
    run.steps = []

    def step(name, **facts):
        run.steps.append(dict(step=name, at=time.time(), **facts))
        say('step', name, json.dumps(facts, default=str)[:1500])

    run.step = step
    failure = None
    try:
        steer.set_directory_trust(run.folder, True)
        run.boot()
        run_check(run)
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        failure = f'{error!r}\n{traceback.format_exc()[-3000:]}'
        say('STOPPED', failure)
        try:
            run.capture('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
    for check in run.checks:
        say('CHECK', 'PASSED' if check['passed'] else 'FAILED', check['check'])
    passed = qe.finish(run, failure)
    steer.set_directory_trust(run.folder, False)
    say('passed' if passed else 'FAILED')
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()

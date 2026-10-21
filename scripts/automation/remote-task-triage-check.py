#!/usr/bin/env python3
"""Route tasks through triage in a disposable app, through the real CLI.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-triage-check.py' for a scripted
triage command, or with '--model claude --gui-session' to ask the real
`claude -p` instead (subscription usage is consumed; on a remote host the
Claude login is readable only in the GUI session).

The check starts its own instance of the wrapper's build with a throwaway
runtime home and a throwaway Toastty home (`CFFIXED_USER_HOME`), which is a git
repository and the open workspace's project. Its
`agents.toml` maps `claude` to a fake agent that records its first message. It never selects a workspace or moves focus.

Scripted triage (default):
- `task create <text> --wait` with no workspace or agent: triage receives the
  task and the open workspace, its answer places the task, renames it, and its
  first prompt reaches the agent before the text as written;
- a task triage cannot place fails `--wait` with "needs a workspace";
  `task workspace-choices` lists the open workspace and a recently closed one;
  `task set-workspace --recent` reopens that one without selecting it, triage
  runs again with it fixed, and the agent starts in its directory;
- a task whose triage is still running when the app is killed is routed again
  after the relaunch;
- a task about a project that is not open (a `[workspace."…"]` root that was
  never open): triage suggests it, the task waits with `suggestedWorkspace`,
  `task workspace-choices <task-id>` offers it under `suggested`, nothing opens
  on its own, and `task set-workspace --root` opens it without selecting it.

Real model (`--model claude`): one task with workspace guidelines that give bugs
model `opus` at effort `low` (not the defaults); the answer must be readable and
follow them. Then a task about the closed website project; the real model must
suggest it.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

_spec = importlib.util.spec_from_file_location(
    'task_create_check', Path(__file__).with_name('remote-task-create-check.py'))
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
require, wait_for, Instance, FAKE_AGENT = base.require, base.wait_for, base.Instance, base.FAKE_AGENT

# Saves its stdin, then answers from the task text and the INPUT JSON.
FAKE_TRIAGE = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
prompt = sys.stdin.read()
inputs = Path(__file__).parent / 'triage-inputs'
inputs.mkdir(exist_ok=True)
(inputs / f'{len(list(inputs.iterdir())):02d}.txt').write_text(prompt)
data = json.loads(prompt.split('INPUT:\n', 1)[1])
text = data['task']['text']
fixed = data['fixed']
if 'slow' in text and not (Path(__file__).parent / 'answer-slow').exists():
    time.sleep(60)
if 'pricing' in text:
    answer = {'agent': 'claude', 'first_prompt': 'TRIAGE: open the pricing page.', 'title': 'Pricing page typo',
              'slug': 'pricing-typo'}
    if 'workspace' not in fixed:
        closed = [w for w in data.get('closed_workspaces', []) if w['title'] == 'website']
        answer.update(workspace=closed[0]['root'] if closed else None, reason='It is about the website, which is not open.')
elif 'billing' in text:
    answer = {'first_prompt': 'TRIAGE: check the plan cache.', 'title': 'Billing page shows the old plan',
              'slug': 'billing-old-plan', 'agent': 'claude'}
    if 'workspace' not in fixed:
        answer.update(workspace=None, reason='No billing project is open.')
else:
    answer = {'workspace': data['workspaces'][0]['id'], 'agent': 'claude',
              'first_prompt': 'TRIAGE: start with the unread dot code.',
              'title': 'Unread dot stays on', 'slug': 'unread-dot', 'reason': 'A toastty bug.'}
print('Thinking it over...')
print(json.dumps(answer))
'''

TASK_TEXT = 'fix the unread dot\nIt stays on after reading.'


def main():
    model = sys.argv[sys.argv.index('--model') + 1] if '--model' in sys.argv else None
    if '--gui-session' in sys.argv[1:]:
        _queue = importlib.util.spec_from_file_location(
            'queue_steer_check', Path(__file__).with_name('remote-queue-steer-check.py'))
        queue_check = importlib.util.module_from_spec(_queue)
        _queue.loader.exec_module(queue_check)
        arguments = [argument for argument in sys.argv[1:] if argument != '--gui-session']
        queue_check.run_in_gui_session('remote-task-triage-check', __file__, arguments)

    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    artifacts.mkdir(parents=True, exist_ok=True)
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-triage-check-', dir='/tmp')).resolve()
    runtime_home, fake_bin = root / 'runtime-home', root / 'bin'
    # The throwaway Toastty home is also the project: a new terminal starts in
    # NSHomeDirectory(), which CFFIXED_USER_HOME sets.
    project = toastty_home = root / 'project'
    billing = root / 'billing-service'
    website = root / 'website'
    for directory in (runtime_home, toastty_home / '.toastty', fake_bin, billing, website):
        directory.mkdir(parents=True)
    for repository in (project, billing, website):
        subprocess.run(['git', 'init', '-q', str(repository)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (toastty_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    triage_script = fake_bin / 'triage.py'
    triage_script.write_text(FAKE_TRIAGE)
    triage_script.chmod(0o755)

    if model == 'claude':
        claude = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
        require(Path(claude).is_file(), 'Claude CLI is not installed')
        command = f"{claude} -p --model sonnet --tools '' --setting-sources= --strict-mcp-config"
        guidelines = ('Bugs with a repro go to agent claude with model opus and effort low. '
                      'Everything else goes to agent claude with model sonnet and effort high.')
    elif model is None:
        command = f'/usr/bin/python3 {triage_script}'
        guidelines = 'Scripted triage for the live check.'
    else:
        raise SystemExit(f'unknown --model {model}')
    (toastty_home / '.toastty/tasks.toml').write_text(
        f'[triage]\ncommand = {json.dumps(command)}\ntimeout_seconds = 180\n\n'
        f'[defaults]\nagent = "claude"\n\n'
        f'[workspace.{json.dumps(str(project))}]\nguidelines = {json.dumps(guidelines)}\n\n'
        # Never open in the check: triage may only suggest it.
        f'[workspace.{json.dumps(str(website))}]\n'
        f'guidelines = "The marketing website: the landing page, the pricing page and the docs."\n')
    recent_id = '6B2D8E0C-1E3F-4A5B-9C7D-0E1F2A3B4C5D'
    (runtime_home / 'recent-workspaces.json').write_text(json.dumps(dict(version=1, items=[dict(
        id=recent_id, title='billing-service', rootDirectory=str(billing), closedAt='2026-10-17T12:00:00Z')])))

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    # HOME stays real so a real triage CLI finds its login; Toastty reads
    # ~/.toastty from the throwaway home and starts terminals there.
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-triage-check',
        TOASTTY_SOCKET_PATH=socket_path,
        CFFIXED_USER_HOME=str(toastty_home),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', mode=model or 'scripted', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, **facts))
        print(f'[triage-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=300)
        return result.returncode, result.stdout, result.stderr

    def task(task_id):
        code, out, err = run_cli('task', 'get', task_id)
        require(code == 0, f'task get failed: {out} {err}')
        return json.loads(out)['result']

    def agent_message(record):
        session_id = record['setup']['sessionID']
        message_file = fake_bin / 'sessions' / f'{session_id}.message'
        wait_for('the fake agent to record its message', message_file.is_file)
        session = json.loads((fake_bin / 'sessions' / f'{session_id}.json').read_text())
        return message_file.read_text(), session

    app_log = artifacts / 'remote-task-triage-check-app.log'

    def launch():
        launched = Instance(binary, environment, socket_path, runtime_home, app_log)
        listed = launched.wait_until_ready()
        return launched, listed

    def suggest_closed_project(text):
        """Creates a task about the website, which is not open, and checks that
        it waits with the website suggested and nothing opened."""
        before = len(instance.query('workspace.list')['workspaces'])
        code, out, err = run_cli('task', 'create', text, '--wait', '--timeout', '240')
        require(code == 1 and 'needs a workspace' in err, f'Expected a wait for a workspace: {code} {out} {err}')
        waiting = json.loads(out)['result']
        suggestion = waiting.get('suggestedWorkspace')
        require(suggestion and os.path.realpath(suggestion['rootDirectory']) == str(website)
                and suggestion['title'] == 'website', f'Website not suggested: {waiting}')
        require(len(instance.query('workspace.list')['workspaces']) == before, 'A workspace opened on its own')
        code, out, err = run_cli('task', 'workspace-choices', waiting['taskID'])
        require(code == 0, f'workspace-choices failed: {out} {err}')
        choices = json.loads(out)['result']
        offered = choices.get('suggested') or {}
        require(os.path.realpath(offered.get('rootDirectory', '')) == str(website), f'Not offered: {choices}')
        require(not any(os.path.realpath(w.get('rootDirectory', '')) == str(website) for w in choices['open']),
                f'Website listed as open: {choices}')
        return waiting

    instance, workspaces = launch()
    try:
        workspace_id = workspaces[0]['workspaceID']

        def terminal_in_project():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return cwds if str(project) in [os.path.realpath(cwd) for cwd in cwds] else None

        wait_for('the first terminal in the project', terminal_in_project, interval=1)
        step('booted', workspaceID=workspace_id)

        if model == 'claude':
            text = ('The unread dot in the sidebar stays on after I read the session. '
                    'Repro: open a session with unread output, read it, switch away; the dot is still there.')
            code, out, err = run_cli('task', 'create', text, '--wait', '--timeout', '240')
            require(code == 0, f'task create --wait failed ({code}): {out} {err}')
            record = json.loads(out)['result']
            message, session = agent_message(record)
            step('real triage answered', title=record['title'], slug=record['slug'], agent=record['agent'],
                 effort=record['effort'], prompt=record['prompt'], triageNote=record['triageNote'])
            require(record['workspaceID'] == workspace_id, f'Not placed in the open workspace: {record}')
            require((record['agent'], record['model'], record['effort']) == ('claude', 'opus', 'low'),
                    f'Triage did not follow the workspace guidelines: {record}')
            require(record['triageNote'] is None, f'Triage answer was not used in full: {record}')
            require(text in message and (record['prompt'] or '') in message, f'Prompt not delivered: {message!r}')
            suggested = suggest_closed_project(
                'The pricing page on the marketing website shows the wrong monthly price for the Team plan.')
            step('real triage suggested the closed project', suggestedWorkspace=suggested['suggestedWorkspace'],
                 reason=suggested['setup']['reason'])
            evidence['status'] = 'passed'
            return

        # 1. Triage places a task that names no workspace or agent.
        code, out, err = run_cli('task', 'create', TASK_TEXT, '--wait', '--timeout', '90')
        require(code == 0, f'task create --wait failed ({code}): {out} {err}')
        record = json.loads(out)['result']
        require(record['setup']['state'] == 'started', f'Task did not start: {record}')
        require(record['workspaceID'] == workspace_id and record['agent'] == 'claude', f'Not routed: {record}')
        require((record['title'], record['slug']) == ('Unread dot stays on', 'unread-dot'), f'Not renamed: {record}')
        message, session = agent_message(record)
        require(message.startswith('TRIAGE: start with the unread dot code.'), f'First prompt missing: {message!r}')
        require(TASK_TEXT in message, f'Task text not delivered as written: {message!r}')
        require(os.path.realpath(session['cwd']) == str(project), f'Agent not in the project: {session}')
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        task_space = listed[record['setup']['taskSpaceWorkspaceID']]
        require(task_space['title'] == 'unread-dot', f'Task space not named from triage: {task_space}')
        triage_input = (fake_bin / 'triage-inputs/00.txt').read_text()
        data = json.loads(triage_input.split('INPUT:\n', 1)[1])
        require(data['task']['text'] == TASK_TEXT, f'Triage did not get the text: {data}')
        require([(w['id'], os.path.realpath(w['root']), w.get('guidelines')) for w in data['workspaces']]
                == [(workspace_id, str(project), 'Scripted triage for the live check.')], f'Workspaces: {data}')
        require([a['id'] for a in data['agents']] == ['claude'], f'Agents: {data}')
        step('triage placed and started a task', title=record['title'], message=message, triageInput=data)

        # 2. Triage cannot place the next one; the user reopens a recent one.
        code, out, err = run_cli('task', 'create', 'billing page shows the old plan after upgrade',
                                 '--wait', '--timeout', '90')
        require(code == 1 and 'needs a workspace: No billing project is open.' in err, f'Expected a wait: {code} {out} {err}')
        billing_task = json.loads(out)['result']
        require(billing_task['setup']['state'] == 'needsWorkspace', f'Not waiting: {billing_task}')
        code, out, err = run_cli('task', 'workspace-choices')
        choices = json.loads(out)['result']
        require([w['workspaceID'] for w in choices['open']] == [workspace_id], f'Open choices: {choices}')
        require([w['recentWorkspace'] for w in choices['recent']] == [recent_id], f'Recent choices: {choices}')
        step('triage could not place a task', reason=billing_task['setup']['reason'], choices=choices)

        code, out, err = run_cli('task', 'set-workspace', billing_task['taskID'], '--recent', recent_id)
        require(code == 0, f'set-workspace failed: {out} {err}')
        placed = wait_for('the billing task to start',
                          lambda: (lambda t: t if t['setup']['state'] == 'started' else None)(task(billing_task['taskID'])))
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        reopened = listed[placed['workspaceID']]
        require(reopened['title'] == 'billing-service' and not reopened['isSelected'], f'Reopened: {reopened}')
        require(listed[workspace_id]['isSelected'], 'The original workspace lost selection')
        message, session = agent_message(placed)
        require(os.path.realpath(session['cwd']) == str(billing), f'Agent not in the reopened project: {session}')
        require(message.startswith('TRIAGE: check the plan cache.'), f'Second triage prompt missing: {message!r}')
        second = json.loads((fake_bin / 'triage-inputs/02.txt').read_text().split('INPUT:\n', 1)[1])
        require(second['fixed'].get('workspace') == placed['workspaceID'], f'Workspace not fixed: {second}')
        step('reopened a recent workspace and started there', workspace=reopened, cwd=session['cwd'])

        # 3. Kill the app while triage runs; the relaunch routes the task.
        code, out, err = run_cli('task', 'create', 'slow task about the unread dot')
        require(code == 0, f'task create failed: {out} {err}')
        slow_id = json.loads(out)['result']['taskID']
        wait_for('the slow triage to start', lambda: (fake_bin / 'triage-inputs/03.txt').exists())
        require(task(slow_id)['setup']['state'] == 'routing', 'The slow task is not routing')
        instance.kill()
        (fake_bin / 'answer-slow').touch()
        step('killed during triage')
        instance, _ = launch()
        restarted = wait_for('the slow task to start after the relaunch',
                             lambda: (lambda t: t if t['setup']['state'] == 'started' else None)(task(slow_id)))
        require(restarted['slug'] == 'unread-dot-2', f'Slug not made unique: {restarted}')
        step('relaunch routed the unfinished task', slug=restarted['slug'])

        # 4. Triage suggests a project that is not open; the user opens it.
        workspace_id = next(w['workspaceID'] for w in instance.query('workspace.list')['workspaces'] if w['isSelected'])
        waiting = suggest_closed_project('pricing page has a typo in the Team plan')
        inputs = sorted((fake_bin / 'triage-inputs').iterdir())
        pricing_input = next(json.loads(path.read_text().split('INPUT:\n', 1)[1]) for path in inputs
                             if 'pricing' in path.read_text())
        closed = {w['title']: w for w in pricing_input.get('closed_workspaces', [])}
        require(os.path.realpath(closed.get('website', {}).get('root', '')) == str(website)
                and 'pricing page' in closed['website'].get('guidelines', ''), f'Closed projects: {pricing_input}')
        step('triage suggested a project that is not open', suggestedWorkspace=waiting['suggestedWorkspace'],
             closedWorkspaces=pricing_input['closed_workspaces'])

        code, out, err = run_cli('task', 'set-workspace', waiting['taskID'], '--root', waiting['suggestedWorkspace']['rootDirectory'])
        require(code == 0, f'set-workspace --root failed: {out} {err}')
        placed = wait_for('the pricing task to start',
                          lambda: (lambda t: t if t['setup']['state'] == 'started' else None)(task(waiting['taskID'])))
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        opened = listed[placed['workspaceID']]
        require(opened['title'] == 'website' and not opened['isSelected'], f'Opened: {opened}')
        require(listed[workspace_id]['isSelected'], 'The selected workspace lost selection')
        require(placed['suggestedWorkspace'] is None, f'Suggestion kept after placing: {placed}')
        message, session = agent_message(placed)
        require(os.path.realpath(session['cwd']) == str(website), f'Agent not in the website project: {session}')
        step('opened the suggested project and started there', workspace=opened, cwd=session['cwd'])

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-task-triage-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[triage-check] passed', flush=True)


if __name__ == '__main__':
    main()

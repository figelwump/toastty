#!/usr/bin/env python3
"""Wake the coordinator for task changes and for its timer in a real app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-wake-check.py'. Add
'--provider claude --gui-session' to run the timer wake against the real,
authenticated Claude CLI; that run uses subscription usage.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home. It never moves focus to another app, and it does
not touch the installed production app.

With the default fake agent, a script stands in for Claude Code, for the
coordinator and for every task: it reports its start as Claude's
SessionStart hook does, turns on bracketed paste as Claude does, records
each message it reads, and reports a turn for it. A turn lasts a second, or
as long as its hold file exists. Through the real CLI the check then proves
that:
- with no coordinator, a task's changes are saved nowhere, and a
  coordinator opened later is not told about them;
- one stage change of a task gives one digest, typed at the coordinator's
  prompt, with one line for the task in the documented form;
- changes made while the coordinator works are not typed; after its turn
  they arrive as one digest with one line for each task and its newest
  stage;
- a stage that returns in under 3 seconds wakes nothing;
- `coordinator wake --in` sets the timer, `coordinator status` shows it,
  `--clear` returns to the default, and the timer wake arrives at its time
  as a digest with the scheduled-check line;
- after the app is killed with a digest waiting and a timer set, and stays
  down until the timer's time passed, the relaunched app types the waiting
  change once and the scheduled check once; a second relaunch repeats
  neither.

With '--provider claude', the coordinator is the real CLI. The check sets the
timer and proves from Claude's transcript that the typed digest started a
turn.

Evidence goes to remote-coordinator-wake-check-<provider>.json and the app
log in the artifacts directory.
"""

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coordinator_check = load('coordinator_check', 'remote-coordinator-check.py')
require, wait_for, Instance = coordinator_check.require, coordinator_check.wait_for, coordinator_check.Instance

HEADER = '[Toastty] Wake: this message is from Toastty, not from the user.'
FOOTER = 'Read `toastty task list` for details.'
TASK_LINE = re.compile(r'^- \[(?P<title>.*)\]\(toastty://task/(?P<id>[0-9A-F-]{36})\): (?P<stage>.*) at (?P<at>\S+)$')
REQUESTED_CHECK = re.compile(r'^- Scheduled check: the time you set, (?P<at>\S+), has come\.$')
# Toastty counts a stage that an agent's status decides after 3 seconds.
SETTLE = 3

# Reads one message for each line, or for each bracketed paste. A turn lasts
# a second, or as long as `hold` or `hold-<session>` exists. `/exit` ends it.
# A task's first prompt comes as the last argument and is a turn too.
FAKE_AGENT = r'''#!__PYTHON__
import json, os, subprocess, sys, time, uuid

arguments = sys.argv[1:]
if arguments[:1] == ['--version']:
    print('2.1.288 (Claude Code)')
    sys.exit(0)
if arguments[:1] and arguments[0] in ('plugin', 'mcp', 'config'):
    sys.exit(0)
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent')
os.makedirs(here, exist_ok=True)
session, panel, cli = (os.environ[name] for name in ('TOASTTY_SESSION_ID', 'TOASTTY_PANEL_ID', 'TOASTTY_CLI_PATH'))
resumed = '--resume' in arguments
native = arguments[arguments.index('--resume') + 1] if resumed else str(uuid.uuid4())
transcript = os.path.join(here, native + '.jsonl')
open(transcript, 'a').close()


def record(event, **facts):
    with open(os.path.join(here, 'events.jsonl'), 'a') as log:
        log.write(json.dumps(dict(event=event, session=session, at=time.time(), **facts)) + '\n')


def status(kind, summary):
    subprocess.run([cli, 'session', 'status', '--session', session, '--kind', kind, '--summary', summary],
                   capture_output=True)


record('started', panel=panel, cwd=os.getcwd(), native=native, resumed=resumed, argv=arguments)
subprocess.run(
    [cli, 'session', 'ingest-agent-event', '--source', 'claude-hooks', '--session', session, '--panel', panel],
    input=json.dumps(dict(hook_event_name='SessionStart', session_id=native, transcript_path=transcript, cwd=os.getcwd())),
    text=True, capture_output=True)
sys.stdout.write('\033[?2004h')
sys.stdout.flush()


def turn(message, **facts):
    status('working', 'Working')
    record('message', text=message, **facts)
    while os.path.exists(os.path.join(here, 'hold')) or os.path.exists(os.path.join(here, 'hold-' + session)):
        time.sleep(0.2)
    time.sleep(1)
    record('turn ended')
    # A finished turn that nobody has read: the task needs the user.
    status('ready', 'Ready')


# Only a prompt has a space; the options before it are names and paths.
if arguments and ' ' in arguments[-1] and not resumed:
    turn(arguments[-1], firstPrompt=True)
else:
    status('idle', 'Waiting')
START, END = '\033[200~', '\033[201~'
lines, pasting = [], False
for raw in sys.stdin:
    line = raw.rstrip('\n')
    if START in line:
        pasting = True
    if END in line:
        pasting = False
    lines.append(line.replace(START, '').replace(END, ''))
    if pasting:
        continue
    message, lines = '\n'.join(lines), []
    if message.strip() == '/exit':
        break
    turn(message)
'''


class WakeCheck(coordinator_check.Check):
    def __init__(self, provider):
        super().__init__(provider)
        self.prefix = f'remote-coordinator-wake-check-{provider}'


def parse_time(text):
    return datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()


def parse_digest(text):
    """The task lines of a digest by task ID, and the time of a timer line."""
    lines = text.split('\n')
    require(lines[0] == HEADER and lines[-1] == FOOTER, f'A digest has the wrong first or last line: {text!r}')
    tasks, requested_check, other = {}, None, []
    for line in lines[1:-1]:
        task, check = TASK_LINE.match(line), REQUESTED_CHECK.match(line)
        if task:
            require(task['id'] not in tasks, f'A digest names a task twice: {text!r}')
            tasks[task['id']] = dict(title=task['title'], stage=task['stage'], at=task['at'])
        elif check:
            requested_check = check['at']
        else:
            other.append(line)
    return dict(tasks=tasks, requestedCheck=requested_check, other=other, text=text)


def stage_text(task):
    stage = task['stage']
    text = stage['group'] + (f" ({stage['attention']})" if stage.get('attention') else '')
    return text + (', merged' if task.get('mergedAt') else '')


def read_outbox(runtime_home):
    path = runtime_home / 'task-webhook-outbox.json'
    return json.loads(path.read_text()) if path.is_file() else None


# MARK: - Fake agent


def run_fake(check):
    fake_bin = check.root / 'bin'
    fake_bin.mkdir()
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT.replace('__PYTHON__', sys.executable))
    agent.chmod(0o755)
    records = fake_bin / 'agent'
    records.mkdir()
    runtime_home, user_home = check.home('main', [str(agent)])
    # The first terminal starts in the user home, which is the tasks' project.
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    environment = check.environment('main', runtime_home, user_home)
    run_cli, cli = check.cli_runner(environment)
    socket_path = environment['TOASTTY_SOCKET_PATH']
    app_log = check.artifacts / f'{check.prefix}-app.log'
    instance = Instance(check.binary, environment, socket_path, runtime_home, app_log)
    step = check.step

    def events():
        log = records / 'events.jsonl'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.is_file() else []

    def digests():
        """Every digest any agent received, in order, with its arrival time."""
        return [dict(parse_digest(event['text']), receivedAt=event['at'], session=event['session'])
                for event in events() if event['event'] == 'message' and event['text'].startswith('[Toastty] Wake')]

    def status():
        return cli('coordinator', 'status')

    def at_prompt():
        current = status()
        return current.get('status') in ('idle', 'ready') and current.get('agentState') == 'running' and current

    def task(task_id):
        return cli('task', 'get', task_id)

    def create(title):
        """A task whose agent ran its first turn, which nobody has read."""
        created = cli('task', 'create', title, '--workspace', project_id, '--wait', '--timeout', '90')
        require(created['setup']['state'] == 'started', f'The task did not start: {created}')
        wait_for_stage(created['taskID'], 'needsYou', 'agentFinished')
        return created['taskID'], created['setup']['sessionID']

    def told_at_rest(task_id):
        return any(d['tasks'].get(task_id, {}).get('stage') == 'needsYou (agentFinished)' for d in digests())

    def turns(session):
        return sum(1 for event in events() if event['event'] == 'turn ended' and event['session'] == session)

    def hold(session, on=True):
        path = records / f'hold-{session}'
        path.write_text('') if on else path.unlink()

    def wait_for_stage(task_id, group, attention=None):
        def reached():
            stage = task(task_id)['stage']
            return stage['group'] == group and (attention is None or stage.get('attention') == attention) and stage
        return wait_for(f'task {task_id} to be {group} {attention or ""}', reached)

    def new_digests(seen, count=1, timeout=45):
        wait_for(f'{count} more digest(s)', lambda: len(digests()) >= seen + count, timeout=timeout)
        return digests()[seen:]

    def quiet(seen, seconds, why):
        time.sleep(seconds)
        require(len(digests()) == seen, f'A digest arrived {why}: {digests()[seen:]}')

    try:
        workspaces = instance.wait_until_ready()
        project_id = workspaces[0]['workspaceID']

        def terminal_in_home():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == project_id)['terminalCwds']
            return str(user_home) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the user home', terminal_in_home, interval=1)
        actions = subprocess.run([str(check.cli), 'action', 'list'], env=environment, capture_output=True, text=True, timeout=60).stdout
        require('coordinator.wake' in actions, 'The coordinator.wake action is not listed')
        step('booted', projectWorkspace=project_id)

        # 1. With no coordinator, nothing is saved for one, and a coordinator
        # opened later is not told about earlier changes.
        early_id, _ = create('Before the coordinator')
        time.sleep(SETTLE + 3)
        require(status() == dict(exists=False, queuedCount=0), f'A new instance has a coordinator: {status()}')
        outbox = read_outbox(runtime_home)
        require(outbox is None or 'coordinator' not in outbox, f'Changes were saved for a coordinator that does not exist: {outbox}')
        refused = run_cli('coordinator', 'wake', '--in', '20m')
        require(refused.returncode != 0 and 'no coordinator' in refused.stdout + refused.stderr,
                f'The timer was set with no coordinator: {refused.stdout} {refused.stderr}')
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start the coordinator: {opened}')
        wait_for('the coordinator at its prompt', at_prompt)
        first_status = status()
        require(first_status['wake']['pendingTaskCount'] == 0 and first_status['wake']['nextWakeSource'] == 'default',
                f'Unexpected first wake status: {first_status}')
        quiet(0, 12, 'for a change made before the coordinator existed')
        step('no coordinator, nothing queued', outboxBefore=outbox, status=first_status)

        # 2. One stage change, one digest at the open prompt.
        task_a, session_a = create('Fix the unread [dot]')
        # A new task is told with the stage it has, and again when that moves.
        wait_for('the digest for the new task', lambda: told_at_rest(task_a))
        wait_for('the coordinator at its prompt', at_prompt)
        time.sleep(SETTLE + 3)
        seen = len(digests())
        hold(session_a)
        cli('task', 'send', task_a, 'work on it')
        wait_for_stage(task_a, 'running')
        (running,) = new_digests(seen)
        require(list(running['tasks']) == [task_a] and running['tasks'][task_a]['stage'] == 'running'
                and running['tasks'][task_a]['title'] == r'Fix the unread \[dot\]'
                and not running['other'] and running['requestedCheck'] is None,
                f'Unexpected digest for one stage change: {running}')
        require(running['session'] == status()['sessionID'], f'The digest went to another agent: {running}')
        quiet(seen + 1, SETTLE + 3, 'although nothing changed')
        step('one stage change gave one digest', digest=running['text'])

        seen = len(digests())
        hold(session_a, on=False)
        finished = wait_for_stage(task_a, 'needsYou', 'agentFinished')
        (needs_you,) = new_digests(seen)
        require(list(needs_you['tasks']) == [task_a] and needs_you['tasks'][task_a]['stage'] == stage_text(task(task_a)),
                f'The digest does not use the stage task get reports: {needs_you} {finished}')
        step('the next stage gave the next digest', digest=needs_you['text'])

        # 3. A busy coordinator gets nothing typed; several changes then
        # arrive as one digest.
        task_b, _ = create('Add the export API')
        wait_for('the digest for the second task', lambda: told_at_rest(task_b))
        wait_for('the coordinator at its prompt', at_prompt)
        time.sleep(SETTLE + 3)
        coordinator_session = status()['sessionID']
        hold(coordinator_session)
        time.sleep(1.5)
        answer = cli('coordinator', 'send', 'hold this turn')
        require(answer['delivery'] == 'sent', f'The message was not typed at the open prompt: {answer}')
        wait_for('the held turn to run', lambda: status().get('status') == 'working')
        seen = len(digests())
        hold(session_a)
        cli('task', 'send', task_a, 'more work')
        wait_for_stage(task_a, 'running')
        wait_for('the first change to wait for the digest', lambda: status()['wake']['pendingTaskCount'] == 1)
        cli('task', 'mark-done', task_b)
        wait_for('two tasks to wait for the digest', lambda: status()['wake']['pendingTaskCount'] == 2)
        hold(session_a, on=False)
        wait_for_stage(task_a, 'needsYou', 'agentFinished')
        time.sleep(SETTLE + 3)
        waiting = status()
        require(waiting['wake']['pendingTaskCount'] == 2 and waiting['status'] == 'working' and waiting['queuedCount'] == 0,
                f'Unexpected status while the coordinator works: {waiting}')
        require(len(digests()) == seen, f'A digest was typed while the coordinator worked: {digests()[seen:]}')
        saved = read_outbox(runtime_home)['coordinator']
        require({change['taskID'] for change in saved['changes']} == {task_a, task_b},
                f'The waiting changes are not saved: {saved}')
        hold(coordinator_session, on=False)
        (burst,) = new_digests(seen)
        require(set(burst['tasks']) == {task_a, task_b}
                and burst['tasks'][task_a]['stage'] == 'needsYou (agentFinished)'
                and burst['tasks'][task_b]['stage'] == 'done' and not burst['other'],
                f'Unexpected digest after the turn: {burst}')
        wait_for('nothing to wait', lambda: status()['wake']['pendingTaskCount'] == 0)
        quiet(seen + 1, SETTLE + 3, 'after the burst was told')
        step('a busy coordinator got one digest after its turn', whileBusy=waiting, digest=burst['text'])

        # 4. A stage that returns in under 3 seconds wakes nothing.
        wait_for('the coordinator at its prompt', at_prompt)
        seen = len(digests())
        before = stage_text(task(task_a))
        ended = turns(session_a)
        cli('task', 'send', task_a, 'a quick look')
        wait_for('the short turn to end', lambda: turns(session_a) == ended + 1)
        quiet(seen, SETTLE + 6, 'for a stage that flickered')
        require(stage_text(task(task_a)) == before and status()['wake']['pendingTaskCount'] == 0,
                f'The flicker changed the stage or left something waiting: {task(task_a)["stage"]} {status()}')
        step('a flicker under 3 seconds woke nothing', stage=before)

        # 5. The timer: set, read, cleared, and fired at its time.
        refused = run_cli('coordinator', 'wake', '--in', '30s')
        require(refused.returncode != 0 and 'at least 1 minute' in refused.stdout + refused.stderr,
                f'A time under a minute was accepted: {refused.stdout} {refused.stderr}')
        far = cli('coordinator', 'wake', '--in', '2h')['wake']
        require(far['nextWakeSource'] == 'coordinator' and 7100 < parse_time(far['nextWakeAt']) - time.time() < 7300,
                f'Unexpected timer: {far}')
        cleared = cli('coordinator', 'wake', '--clear')['wake']
        require(cleared['nextWakeSource'] == 'default'
                and abs(parse_time(cleared['nextWakeAt']) - parse_time(cleared['lastWakeAt']) - 3600) < 2,
                f'Clear did not return to the default: {cleared}')
        seen = len(digests())
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        due = parse_time(timer['nextWakeAt'])
        require(status()['wake'] == timer and timer['nextWakeSource'] == 'coordinator', f'Status does not show the timer: {status()}')
        (scheduled,) = new_digests(seen, timeout=100)
        require(scheduled['requestedCheck'] == timer['nextWakeAt'] and not scheduled['tasks'] and not scheduled['other'],
                f'Unexpected timer digest: {scheduled}')
        require(due - 1 <= scheduled['receivedAt'] <= due + 15, f'The timer fired at the wrong time: due {due}, {scheduled}')
        after_timer = wait_for('the timer to be gone', lambda: (w := status()['wake'])['nextWakeSource'] == 'default' and w)
        quiet(seen + 1, 6, 'after the timer fired once')
        step('the timer fired at its time', timer=timer, digest=scheduled['text'], after=after_timer)

        # 6. Kill with a digest waiting and a timer set; stay down past the
        # timer's time; relaunch.
        wait_for('the coordinator at its prompt', at_prompt)
        coordinator_session = status()['sessionID']
        native = next(event['native'] for event in events()
                      if event['event'] == 'started' and event['session'] == coordinator_session)
        hold(coordinator_session)
        time.sleep(1.5)
        cli('coordinator', 'send', 'hold until the quit')
        wait_for('the held turn to run', lambda: status().get('status') == 'working')
        cli('task', 'mark-done', task_a)
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        wait_for('the change to wait', lambda: status()['wake']['pendingTaskCount'] == 1)
        saved = read_outbox(runtime_home)['coordinator']
        require([change['taskID'] for change in saved['changes']] == [task_a] and saved.get('requestedWakeAt'),
                f'The waiting digest and the timer are not saved: {saved}')
        instance.request('app_control.run_action', dict(id='workspace.select', args=dict(workspaceID=project_id)))
        coordinator_check.wait_for_layout(runtime_home, '"isCoordinator"', native)
        time.sleep(2)
        seen = len(digests())
        before = status()
        instance.kill()
        hold(coordinator_session, on=False)
        step('killed with a digest waiting', status=before, saved=saved)
        time.sleep(max(0, parse_time(timer['nextWakeAt']) - time.time()) + 5)

        instance = Instance(check.binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        restored = status()
        require(restored['exists'] and restored['workspaceID'] == before['workspaceID']
                and restored['wake']['pendingTaskCount'] >= 1
                and restored['wake']['nextWakeAt'] == timer['nextWakeAt'] and restored['wake']['nextWakeSource'] == 'coordinator',
                f'The waiting digest or the timer was not restored: {restored}')
        resumed = wait_for('the agent to be resumed', lambda: (s := status()).get('sessionID') and s, timeout=90)
        require(resumed['sessionID'] != before['sessionID'], 'The resumed agent should have a new session')
        wait_for('the waiting change to be typed', lambda: any(task_a in d['tasks'] for d in digests()[seen:]), timeout=90)
        wait_for('nothing to wait', lambda: status()['wake']['pendingTaskCount'] == 0 and at_prompt(), timeout=60)
        time.sleep(SETTLE + 12)
        after_relaunch = digests()[seen:]
        told = [d for d in after_relaunch if task_a in d['tasks']]
        checks = [d for d in after_relaunch if d['requestedCheck']]
        require(len(told) == 1 and told[0]['tasks'][task_a]['stage'] == 'done', f'The waiting change was not typed once: {after_relaunch}')
        require(len(checks) == 1 and checks[0]['requestedCheck'] == timer['nextWakeAt'],
                f'The timer that came due while Toastty was quit did not fire once: {after_relaunch}')
        require(all(d['session'] == resumed['sessionID'] for d in after_relaunch), f'A digest went to another agent: {after_relaunch}')
        step('the relaunch typed what waited once', restored=restored, digests=[d['text'] for d in after_relaunch])

        # A second relaunch repeats nothing.
        wait_for('the coordinator at its prompt', at_prompt)
        native = next(event['native'] for event in events()
                      if event['event'] == 'started' and event['session'] == resumed['sessionID'])
        coordinator_check.wait_for_layout(runtime_home, '"isCoordinator"', native)
        time.sleep(2)
        seen = len(digests())
        instance.kill()
        instance = Instance(check.binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        wait_for('the agent to be resumed', lambda: (s := status()).get('sessionID') and s, timeout=90)
        wait_for('the coordinator at its prompt', at_prompt)
        time.sleep(25)
        repeated = [d for d in digests()[seen:] if task_a in d['tasks'] or d['requestedCheck']]
        require(not repeated, f'A second relaunch repeated a digest: {repeated}')
        step('a second relaunch repeated nothing', digests=[d['text'] for d in digests()[seen:]], status=status())
        check.evidence['digests'] = [d['text'] for d in digests()]
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        check.copy_instance_log(runtime_home, 'main')
        events_log = records / 'events.jsonl'
        if events_log.is_file():
            shutil.copyfile(events_log, check.artifacts / f'{check.prefix}-agent-events.jsonl')
        outbox = runtime_home / 'task-webhook-outbox.json'
        if outbox.is_file():
            shutil.copyfile(outbox, check.artifacts / f'{check.prefix}-outbox.json')


# MARK: - Real Claude


def run_claude(check):
    steer = load('queue_steer_check', 'remote-queue-steer-check.py')
    host_environment = {key: value for key, value in os.environ.items()
                        if not key.startswith('TOASTTY_')
                        and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    claude = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
    require(Path(claude).is_file(), 'Claude CLI is not installed; install and authenticate it on the remote host')
    version = subprocess.check_output([claude, '--version'], text=True, timeout=30, env=host_environment).strip()
    auth = subprocess.run([claude, '--safe-mode', '--setting-sources', '', 'auth', 'status', '--json'],
                          capture_output=True, text=True, timeout=30, env=host_environment)
    require(auth.returncode == 0 and json.loads(auth.stdout).get('loggedIn'),
            'Claude CLI needs an interactive login on the remote host; add --gui-session over SSH')
    check.evidence['cliVersion'] = version

    # Only this disposable app sees the profile, which names `sleep` as the
    # one command allowed without a prompt. The digest suggests
    # `toastty task list`. Where Claude's permission mode lets it run that
    # read-only command, it reads this instance; elsewhere the turn stops at
    # Claude's permission prompt. The check accepts both.
    argv = [claude, '--setting-sources=', '--allowedTools', 'Bash(sleep:*)', '--tools', 'Bash', '--strict-mcp-config']
    runtime_home, user_home = check.home('claude', argv)
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')
    environment = check.environment('claude', runtime_home, user_home, real_home=True)
    _, cli = check.cli_runner(environment)
    directory = runtime_home / 'coordinator'
    directory.mkdir(parents=True)
    # Typed text cannot answer the folder-trust dialog, so trust only this
    # run's folder for the run.
    steer.set_directory_trust(directory, True)
    app_log = check.artifacts / f'{check.prefix}-app.log'
    instance = Instance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log)
    step = check.step
    project = steer.claude_project_directory(directory)

    def status():
        return cli('coordinator', 'status')

    def transcript_records():
        records = []
        for path in sorted(project.glob('*.jsonl')) if project.is_dir() else []:
            for line in path.read_text().splitlines():
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        return records

    def text_of(record):
        content = (record.get('message') or {}).get('content')
        if isinstance(content, str):
            return content
        parts = [part for part in content or [] if isinstance(part, dict)]
        return '\n'.join(part.get('text') or (f"[tool {part.get('name')}: {json.dumps(part.get('input'))}]"
                                              if part.get('type') == 'tool_use' else '') for part in parts)

    def turn_for_digest():
        """The digest as Claude's user message, and what Claude did next."""
        records = transcript_records()
        for index, record in enumerate(records):
            if record.get('type') == 'user' and text_of(record).startswith('[Toastty] Wake'):
                replies = [text_of(later) for later in records[index + 1:] if later.get('type') == 'assistant' and text_of(later).strip()]
                if replies:
                    return dict(digest=text_of(record), reply=replies)
        return None

    try:
        instance.wait_until_ready()
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        step('open started Claude and the timer is set', opened=opened, version=version, timer=timer)

        turn = wait_for('Claude to answer the digest', turn_for_digest, timeout=300, interval=2)
        digest = parse_digest(turn['digest'].strip())
        require(digest['requestedCheck'] == timer['nextWakeAt'] and not digest['tasks'],
                f'Claude did not get the timer digest as typed: {turn}')
        # The turn ends, or stops at a permission prompt for a command.
        after = wait_for('the turn to end or ask',
                         lambda: (s := status()).get('status') in ('idle', 'ready', 'needs_approval') and s, timeout=180)
        require(after['wake']['nextWakeSource'] != 'coordinator' and after['wake']['pendingTaskCount'] == 0,
                f'The typed digest did not clear the timer: {after}')
        turn = turn_for_digest()
        step('the digest started a turn', digest=turn['digest'], reply=[text[:600] for text in turn['reply']], status=after)
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        check.copy_instance_log(runtime_home, 'claude')
        steer.set_directory_trust(directory, False)
        if project.is_dir():
            capture = check.artifacts / f'{check.prefix}-transcripts'
            capture.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, capture / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(project, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--provider', choices=('fake', 'claude'), default='fake')
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        steer = load('queue_steer_check', 'remote-queue-steer-check.py')
        steer.run_in_gui_session(f'remote-coordinator-wake-check-{options.provider}', __file__, ['--provider', options.provider])
    check = WakeCheck(options.provider)
    check.evidence['startedAt'] = datetime.now(timezone.utc).isoformat()
    try:
        (run_claude if options.provider == 'claude' else run_fake)(check)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[coordinator-check] passed ({options.provider})', flush=True)


if __name__ == '__main__':
    main()

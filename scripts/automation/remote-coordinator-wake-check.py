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
each message it reads, and reports a turn for it as Claude's
UserPromptSubmit and Stop hooks do. A turn lasts a second, or
as long as its hold file exists. Through the real CLI the check then proves
that:
- with no coordinator, a task's changes are saved nowhere, and a
  coordinator opened later is not told about them; with open tasks and no
  time set, no timer runs;
- a task that only starts running types no digest, also at the
  coordinator's open prompt; its next stage gives one digest, with one line
  for the task in the documented form;
- changes made while the coordinator works are not typed; after its turn
  they arrive as one digest with one line for each task and its newest
  stage, also a task that only started running;
- a stage that returns in under 3 seconds wakes nothing;
- `coordinator wake --in` sets the timer, `coordinator status` shows it,
  `--clear` removes it, and the timer wake arrives at its time as a digest
  with the scheduled-check line;
- a busy task agent whose transcript last changed 31 minutes ago wakes the
  coordinator once, by the clock alone, with the silent alert in its line;
  the agent writing clears the alert and wakes nothing; silence again wakes
  it again. The check moves the transcript's modification time back, so the
  real 30-minute limit applies and no setting is changed;
- after the app is killed with a digest waiting, a timer set and a task's
  agent in the middle of a turn, and stays down until the timer's time
  passed, the relaunched app types the waiting change once and the
  scheduled check once, and tells once that the quit cut off the task's
  turn: the restored agent idles at its prompt, `task get` reports
  `interruptedAtQuit`, and the task's digest line ends with the interrupted
  alert; a second relaunch, with the
  saved last wake moved two hours back, no time set and the file stripped
  of alerts as the build before them wrote it, types neither and no
  scheduled check of its own.

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
TASK_LINE = re.compile(r'^- \[(?P<title>.*)\]\(toastty://task/(?P<id>[0-9A-F-]{36})\): (?P<stage>.*?) '
                       r'at (?P<at>\d{4}-\d\d-\d\dT[\d:.]+Z)(?P<alerts>(?:; .+)?)$')
SILENT = 'busy, no output for 30 minutes'
INTERRUPTED = 'interrupted by the quit'

REQUESTED_CHECK = re.compile(r'^- Scheduled check: the time you set, (?P<at>\S+), has come\.$')
# Toastty counts a stage that an agent's status decides after 3 seconds.
SETTLE = 3

# Reads one message for each line, or for each bracketed paste. A turn lasts
# a second, or as long as `hold` or `hold-<session>` exists. `/exit` ends it.
# A task's first prompt comes as the last argument and is a turn too.
#
# The agent reports each turn as Claude Code does, with the UserPromptSubmit
# and the Stop hook. Toastty types a digest through the coordinator's
# conversation, and that conversation opens the prompt again only when the
# provider reports that the turn ended. A turn reported with
# `toastty session status` alone would leave the prompt closed for good.
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


def hook(event, **fields):
    subprocess.run(
        [cli, 'session', 'ingest-agent-event', '--source', 'claude-hooks', '--session', session, '--panel', panel],
        input=json.dumps(dict(hook_event_name=event, session_id=native, transcript_path=transcript, cwd=os.getcwd(),
                              **fields)),
        text=True, capture_output=True)


record('started', panel=panel, cwd=os.getcwd(), native=native, resumed=resumed, argv=arguments)
hook('SessionStart')
sys.stdout.write('\033[?2004h')
sys.stdout.flush()


def turn(message, **facts):
    # Sets the status to working, and starts the turn in the conversation.
    hook('UserPromptSubmit', prompt=message)
    record('message', text=message, **facts)
    while os.path.exists(os.path.join(here, 'hold')) or os.path.exists(os.path.join(here, 'hold-' + session)):
        time.sleep(0.2)
    time.sleep(1)
    record('turn ended')
    # Sets the status to ready, and ends the turn in the conversation. A
    # finished turn that nobody has read: the task needs the user.
    hook('Stop')


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
            tasks[task['id']] = dict(title=task['title'], stage=task['stage'], at=task['at'],
                                     alerts=task['alerts'].split('; ')[1:])
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

    def open_tasks():
        return [t['taskID'] for t in cli('task', 'list')['tasks'] if t['stage']['group'] not in ('done', 'archived')]

    def saved_changes():
        """Each waiting change: its task, its group, and whether it wakes."""
        return [(change['taskID'], change['group'], change.get('wakes') or bool(change.get('newAlerts')))
                for change in read_outbox(runtime_home)['coordinator']['changes']]

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
        # The early task is open, and no time is set: no timer.
        require(first_status['wake']['pendingTaskCount'] == 0 and first_status['wake']['nextWakeAt'] is None
                and 'nextWakeSource' not in first_status['wake'] and open_tasks(),
                f'Unexpected first wake status: {first_status} {open_tasks()}')
        quiet(0, 12, 'for a change made before the coordinator existed')
        step('no coordinator, nothing queued', outboxBefore=outbox, status=first_status)

        # 2. A task that only starts running types no digest, also at the
        # open prompt. Its next stage gives one digest.
        task_a, session_a = create('Fix the unread [dot]')
        # A new task starts running, which wakes nothing; the end of its
        # first turn does.
        wait_for('the digest for the new task', lambda: told_at_rest(task_a))
        wait_for('the coordinator at its prompt', at_prompt)
        time.sleep(SETTLE + 3)
        seen = len(digests())
        hold(session_a)
        cli('task', 'send', task_a, 'work on it')
        wait_for_stage(task_a, 'running')
        wait_for('the running change to wait', lambda: status()['wake']['pendingTaskCount'] == 1)
        quiet(seen, SETTLE + 6, 'for a task that only started running')
        quiet_status = at_prompt()
        require(quiet_status and quiet_status['wake']['pendingTaskCount'] == 1 and quiet_status['wake']['nextWakeAt'] is None,
                f'The coordinator is not at its prompt with the running change waiting: {status()}')
        require(saved_changes() == [(task_a, 'running', False)], f'The running change is not saved as quiet: {saved_changes()}')
        step('a task that started running typed no digest at the open prompt', status=quiet_status,
             saved=read_outbox(runtime_home)['coordinator'])

        hold(session_a, on=False)
        finished = wait_for_stage(task_a, 'needsYou', 'agentFinished')
        (needs_you,) = new_digests(seen)
        require(list(needs_you['tasks']) == [task_a] and needs_you['tasks'][task_a]['stage'] == stage_text(task(task_a))
                and needs_you['tasks'][task_a]['title'] == r'Fix the unread \[dot\]'
                and not needs_you['other'] and needs_you['requestedCheck'] is None,
                f'Unexpected digest for the next stage: {needs_you} {finished}')
        require(needs_you['session'] == status()['sessionID'], f'The digest went to another agent: {needs_you}')
        quiet(seen + 1, SETTLE + 3, 'although nothing changed')
        step('the next stage gave one digest', digest=needs_you['text'])

        # 2b. A task that the user finished wakes nothing: its line waits.
        wait_for('the coordinator at its prompt', at_prompt)
        seen = len(digests())
        cli('task', 'mark-done', early_id)
        wait_for('the finished task to wait', lambda: status()['wake']['pendingTaskCount'] == 1)
        quiet(seen, SETTLE + 6, 'for a task the user finished')
        require(saved_changes() == [(early_id, 'done', False)], f'The finished task is not saved as quiet: {saved_changes()}')
        step('a task the user finished typed no digest', saved=read_outbox(runtime_home)['coordinator'])

        # 3. A busy coordinator gets nothing typed; several changes then
        # arrive as one digest, with a task that only started running.
        task_b, _ = create('Add the export API')
        wait_for('the digest for the second task', lambda: told_at_rest(task_b))
        # The finished task's line waited for this digest.
        carried = next(d for d in digests() if task_b in d['tasks'])
        require(carried['tasks'].get(early_id, {}).get('stage') == 'done',
                f"The finished task's line did not go with the next digest: {carried}")
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
        # The coordinator watches the second task: its end wakes it.
        watched = cli('coordinator', 'watch', '--task', task_b)['wake']
        require(watched['watchedTaskIDs'] == [task_b], f'The watch is not shown: {watched}')
        cli('task', 'mark-done', task_b)
        wait_for('two tasks to wait for the digest', lambda: status()['wake']['pendingTaskCount'] == 2)
        time.sleep(SETTLE + 3)
        waiting = status()
        require(waiting['wake']['pendingTaskCount'] == 2 and waiting['status'] == 'working' and waiting['queuedCount'] == 0,
                f'Unexpected status while the coordinator works: {waiting}')
        require(len(digests()) == seen, f'A digest was typed while the coordinator worked: {digests()[seen:]}')
        require(sorted(saved_changes()) == sorted([(task_a, 'running', False), (task_b, 'done', True)]),
                f'The waiting changes are not saved: {saved_changes()}')
        require(waiting['wake']['watchedTaskIDs'] == [], f"The task's end did not end its watch: {waiting}")
        hold(coordinator_session, on=False)
        (burst,) = new_digests(seen)
        require(set(burst['tasks']) == {task_a, task_b}
                and burst['tasks'][task_a]['stage'] == 'running'
                and burst['tasks'][task_b]['stage'] == 'done' and not burst['other'],
                f'Unexpected digest after the turn: {burst}')
        wait_for('nothing to wait', lambda: status()['wake']['pendingTaskCount'] == 0)
        step("a busy coordinator got one digest after its turn, for the watched task's end, with the quiet changes",
             whileBusy=waiting, digest=burst['text'])

        # The running task's turn ends: that stage wakes the coordinator.
        wait_for('the coordinator at its prompt', at_prompt)
        seen = len(digests())
        hold(session_a, on=False)
        wait_for_stage(task_a, 'needsYou', 'agentFinished')
        (rested,) = new_digests(seen)
        require(list(rested['tasks']) == [task_a] and rested['tasks'][task_a]['stage'] == 'needsYou (agentFinished)',
                f'Unexpected digest for the end of the turn: {rested}')
        quiet(seen + 1, SETTLE + 3, 'after the turn was told')
        step('the end of the running task\'s turn gave one digest', digest=rested['text'])

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
        require(far.get('nextWakeAt') and 7100 < parse_time(far['nextWakeAt']) - time.time() < 7300,
                f'Unexpected timer: {far}')
        cleared = cli('coordinator', 'wake', '--clear')['wake']
        require(cleared['nextWakeAt'] is None and open_tasks(),
                f'Clear left a timer, or no task is open: {cleared} {open_tasks()}')
        seen = len(digests())
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        due = parse_time(timer['nextWakeAt'])
        require(status()['wake'] == timer, f'Status does not show the timer: {status()}')
        (scheduled,) = new_digests(seen, timeout=100)
        require(scheduled['requestedCheck'] == timer['nextWakeAt'] and not scheduled['tasks'] and not scheduled['other'],
                f'Unexpected timer digest: {scheduled}')
        require(due - 1 <= scheduled['receivedAt'] <= due + 15, f'The timer fired at the wrong time: due {due}, {scheduled}')
        after_timer = wait_for('the timer to be gone', lambda: (w := status()['wake'])['nextWakeAt'] is None and w)
        quiet(seen + 1, 6, 'after the timer fired once')
        step('the timer fired at its time', timer=timer, digest=scheduled['text'], after=after_timer)

        # 6. A busy agent that writes nothing for 30 minutes wakes the
        # coordinator once, by the clock alone. The fake agent writes its
        # transcript only when it starts, so moving that file's
        # modification time back is the agent's silence.
        wait_for('the coordinator at its prompt', at_prompt)
        native_a = next(event['native'] for event in events()
                        if event['event'] == 'started' and event['session'] == session_a)
        transcript = records / f'{native_a}.jsonl'
        hold(session_a)
        cli('task', 'send', task_a, 'think for a long time')
        wait_for_stage(task_a, 'running')
        wait_for('Toastty to read the transcript', lambda: task(task_a)['agentState'].get('lastOutputAt'))
        wait_for('the running change to wait', lambda: status()['wake']['pendingTaskCount'] == 1)
        seen = len(digests())
        quiet(seen, SETTLE + 3, 'for a busy agent that wrote recently')

        def go_silent():
            moved_to = time.time() - 31 * 60
            os.utime(transcript, (moved_to, moved_to))
            return wait_for('the silence to show', lambda: (t := task(task_a))['agentState'].get('lastOutputAt')
                            and time.time() - parse_time(t['agentState']['lastOutputAt']) > 30 * 60 and t)

        silent_task = go_silent()
        silent_at = time.time()
        (silent,) = new_digests(seen, timeout=30)
        require(list(silent['tasks']) == [task_a] and silent['tasks'][task_a]['stage'] == 'running'
                and silent['tasks'][task_a]['alerts'] == [SILENT] and not silent['other'] and silent['requestedCheck'] is None,
                f'Unexpected digest for a silent agent: {silent}')
        require(silent['receivedAt'] - silent_at < SETTLE + 8, f'The silent alert came late: {silent_at} {silent}')
        wait_for('the coordinator at its prompt', at_prompt)
        quiet(seen + 1, SETTLE + 6, 'while the agent stayed silent')

        # The agent writes: the alert clears and wakes nothing.
        os.utime(transcript, None)
        wait_for('the cleared alert to wait', lambda: saved_changes() == [(task_a, 'running', False)])
        quiet(seen + 1, SETTLE + 3, 'when the silent agent wrote')
        cleared_status = status()
        # Silent again: one more wake.
        go_silent()
        (again,) = new_digests(seen + 1, timeout=30)
        require(list(again['tasks']) == [task_a] and again['tasks'][task_a]['alerts'] == [SILENT],
                f'Unexpected digest for the second silence: {again}')
        wait_for('the coordinator at its prompt', at_prompt)
        quiet(seen + 2, SETTLE + 3, 'after the second silence was told')
        # The turn ends: a stage change, and no alert.
        hold(session_a, on=False)
        wait_for_stage(task_a, 'needsYou', 'agentFinished')
        (ended,) = new_digests(seen + 2)
        require(ended['tasks'][task_a]['stage'] == 'needsYou (agentFinished)' and ended['tasks'][task_a]['alerts'] == [],
                f'Unexpected digest for the end of the silent turn: {ended}')
        step('a silent busy agent woke the coordinator once per silence', task=silent_task['agentState'],
             digests=[silent['text'], again['text'], ended['text']], afterWriting=cleared_status)

        # 7. Kill with a digest waiting, a timer set and a task's agent in a
        # turn; stay down past the timer's time; relaunch. The early task's
        # agent works when the app goes down. Its start is a quiet change.
        wait_for('the coordinator at its prompt', at_prompt)
        early_session = task(early_id)['agentState']['sessionID']
        early_native = next(event['native'] for event in events()
                            if event['event'] == 'started' and event['session'] == early_session)
        hold(early_session)
        cli('task', 'send', early_id, 'work until the quit')
        wait_for_stage(early_id, 'running')
        coordinator_check.wait_for_layout(runtime_home, early_native)
        coordinator_session = status()['sessionID']
        native = next(event['native'] for event in events()
                      if event['event'] == 'started' and event['session'] == coordinator_session)
        hold(coordinator_session)
        time.sleep(1.5)
        cli('coordinator', 'send', 'hold until the quit')
        wait_for('the held turn to run', lambda: status().get('status') == 'working')
        cli('task', 'mark-done', task_a)
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        wait_for('the changes to wait', lambda: status()['wake']['pendingTaskCount'] == 2)
        saved = read_outbox(runtime_home)['coordinator']
        require(sorted(change['taskID'] for change in saved['changes']) == sorted([task_a, early_id])
                and saved.get('requestedWakeAt'),
                f'The waiting digest and the timer are not saved: {saved}')
        instance.request('app_control.run_action', dict(id='workspace.select', args=dict(workspaceID=project_id)))
        coordinator_check.wait_for_layout(runtime_home, '"isCoordinator"', native)
        time.sleep(2)
        seen = len(digests())
        before = status()
        early_before = task(early_id)['agentState']
        require(early_before['state'] == 'busy', f'The early task is not in a turn: {early_before}')
        instance.kill()
        hold(coordinator_session, on=False)
        hold(early_session, on=False)
        step('killed with a digest waiting', status=before, saved=saved, earlyTask=early_before)
        time.sleep(max(0, parse_time(timer['nextWakeAt']) - time.time()) + 5)

        instance = Instance(check.binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        restored = status()
        require(restored['exists'] and restored['workspaceID'] == before['workspaceID']
                and restored['wake']['pendingTaskCount'] >= 1
                and restored['wake']['nextWakeAt'] == timer['nextWakeAt'],
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
        interrupted = [d for d in after_relaunch if INTERRUPTED in d['tasks'].get(early_id, {}).get('alerts', [])]
        early_after = task(early_id)
        require(len(interrupted) == 1 and interrupted[0]['tasks'][early_id]['alerts'] == [INTERRUPTED],
                f'The cut-off turn was not told once: {after_relaunch}')
        require(early_after['agentState']['state'] == 'idle' and early_after['agentState']['interruptedAtQuit'] is True
                and early_after['agentState']['sessionID'] != early_session,
                f'The early task was not restored idle with its turn cut off: {early_after["agentState"]}')
        step('the relaunch typed what waited once', restored=restored, digests=[d['text'] for d in after_relaunch],
             interruptedTask=early_after['agentState'])

        # The coordinator continues the cut-off turn: the alert clears, and
        # the next quit cuts nothing off.
        wait_for('the coordinator at its prompt', at_prompt)
        restored_early = early_after['agentState']['sessionID']
        ended = turns(restored_early)
        cli('task', 'send', early_id, '[coordinator] Toastty restarted while you worked. Continue where you stopped.')
        wait_for('the continued turn to end', lambda: turns(restored_early) == ended + 1)
        wait_for('the cut-off mark to clear', lambda: task(early_id)['agentState']['interruptedAtQuit'] is False)
        wait_for('the continued task to be told', lambda: any(
            early_id in d['tasks'] and d['tasks'][early_id]['alerts'] == [] for d in digests()[seen:]), timeout=60)
        require(sum(INTERRUPTED in d['tasks'].get(early_id, {}).get('alerts', []) for d in digests()[seen:]) == 1,
                f'The cut-off turn was told again: {digests()[seen:]}')
        step('continuing the cut-off turn cleared the alert', task=task(early_id)['agentState'])

        # A second relaunch repeats nothing. Its saved last wake is moved two
        # hours back, with no time set and a task open: a default timer
        # would fire at once. The file is also stripped of alerts, as the
        # build before them wrote it: it must still load.
        wait_for('the coordinator at its prompt', at_prompt)
        native = next(event['native'] for event in events()
                      if event['event'] == 'started' and event['session'] == resumed['sessionID'])
        coordinator_check.wait_for_layout(runtime_home, '"isCoordinator"', native)
        time.sleep(2)
        seen = len(digests())
        instance.kill()
        outbox_path = runtime_home / 'task-webhook-outbox.json'
        outbox = json.loads(outbox_path.read_text())
        require(outbox['coordinator'].get('requestedWakeAt') is None, f'A time is still set: {outbox["coordinator"]}')
        two_hours_ago = datetime.fromtimestamp(time.time() - 7200, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        outbox['coordinator']['lastWakeAt'] = two_hours_ago

        def as_earlier_build(value):
            if isinstance(value, dict):
                return {key: as_earlier_build(item) for key, item in value.items()
                        if key not in ('alerts', 'newAlerts', 'alertsSince', 'releaseAfterMerge', 'watchedTaskIDs',
                                       'watchedProjectRoots', 'lastDigestKey', 'quietDigestKeys')}
            return [as_earlier_build(item) for item in value] if isinstance(value, list) else value

        outbox = as_earlier_build(outbox)
        outbox_path.write_text(json.dumps(outbox, indent=2, sort_keys=True))
        instance = Instance(check.binary, environment, socket_path, runtime_home, app_log)
        instance.wait_until_ready()
        moved = status()
        require(moved['wake']['lastWakeAt'] == two_hours_ago and moved['wake']['nextWakeAt'] is None and open_tasks(),
                f'The moved last wake was not restored, a timer runs, or no task is open: {moved} {open_tasks()}')
        wait_for('the agent to be resumed', lambda: (s := status()).get('sessionID') and s, timeout=90)
        wait_for('the coordinator at its prompt', at_prompt)
        time.sleep(25)
        repeated = [d for d in digests()[seen:] if task_a in d['tasks'] or d['requestedCheck'] or d['other']]
        require(not repeated, f'A second relaunch repeated a digest or fired a timer: {repeated}')
        step('a second relaunch repeated nothing and fired no timer', restored=moved, openTasks=open_tasks(),
             digests=[d['text'] for d in digests()[seen:]], status=status())
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
        require(after['wake']['nextWakeAt'] is None and after['wake']['pendingTaskCount'] == 0,
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

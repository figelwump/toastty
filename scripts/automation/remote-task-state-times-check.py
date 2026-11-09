#!/usr/bin/env python3
"""Check the times `task get` reports for a task's state, across a crash and a quit.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-state-times-check.py'.

The check starts its own instance of the wrapper's build with a throwaway
runtime home and user home (a git repository), a fake agent, and a fake `gh`
first on the instance's login-shell PATH. It never selects a workspace or
moves focus. Through the real CLI it checks that:
- `stage.changedAt` and `agentState.changedAt` stay while the agent reports
  the same state again, and move when the state changes;
- a status that flickers and returns within 3 seconds keeps the stage time;
- `agentState.lastOutputAt` follows the transcript file's modification time;
- `task send` does not move `lastUserInputAt`;
- `pullRequest` reports pending checks with `checksPendingSince`, and the
  result once they finish;
- after the app is killed while an agent is busy and relaunched, that task
  reports `interruptedAtQuit` until its agent starts a turn, and that turn
  is a new Running stage; the other task is not marked, a stage that is the
  same keeps its earlier time, and pending checks keep theirs;
- after a quit through AppKit while the agent is busy, the task reports
  `interruptedAtQuit` again. When the quit cannot be delivered, as on a
  locked screen, the step is recorded as unavailable, not failed.
A real key press, which moves `lastUserInputAt`, needs a focused window; the
app tests cover it.
"""

import importlib.util
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import tempfile
import time

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load('task_create_check', 'remote-task-create-check.py')
merge_check = load('task_merge_check', 'remote-task-merge-check.py')
require, wait_for, Instance, FAKE_AGENT = base.require, base.wait_for, base.Instance, base.FAKE_AGENT
SLUG = 'toastty-check/project'
# Longer than the 3 seconds a stage must hold before it counts.
SETTLE = 4

QUIT_HELPER = '''import AppKit
guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
exit(app.terminate() ? 0 : 1)
'''


def parse(value):
    return datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc).timestamp() if value else None


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary = bundle / 'Contents/MacOS/Toastty'
    cli = bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-state-times-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin, zdotdir = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'zdotdir'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, zdotdir):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT)
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')

    # The fake gh serves one pull request from a state file.
    gh_state = root / 'gh-state.json'
    prs = {}

    def save_prs():
        gh_state.write_text(json.dumps(dict(slug=SLUG, project=str(user_home), prs=prs)))

    save_prs()
    (fake_bin / 'gh').write_text(merge_check.FAKE_GH)
    (fake_bin / 'gh').chmod(0o755)
    (fake_bin / 'state-path').write_text(str(gh_state))
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text('')
    (zdotdir / '.zshrc').write_text(f'export PATH="{fake_bin}:$PATH"\n')

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-state-times-check',
        TOASTTY_SOCKET_PATH=socket_path,
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        ZDOTDIR=str(zdotdir),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', steps=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[state-times-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments, stdin=None):
        return subprocess.run([str(cli), '--json', *arguments], env=environment, input=stdin,
                              capture_output=True, text=True, timeout=120)

    def cli_json(*arguments, stdin=None):
        result = run_cli(*arguments, stdin=stdin)
        require(result.returncode == 0, f'toastty {" ".join(arguments)} failed: {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {} if result.stdout.strip() else {}

    def task(task_id):
        return cli_json('task', 'get', task_id)

    def report(session, kind, detail=None):
        arguments = ['session', 'status', '--session', session, '--kind', kind, '--summary', kind.capitalize()]
        cli_json(*arguments, *(['--detail', detail] if detail else []))

    def times(record):
        return dict(
            stage=record['stage'].get('group'), attention=record['stage'].get('attention'),
            stageChangedAt=record['stage'].get('changedAt'), agentState=record['agentState']['state'],
            agentChangedAt=record['agentState'].get('changedAt'),
            interruptedAtQuit=record['agentState'].get('interruptedAtQuit'),
            lastOutputAt=record['agentState'].get('lastOutputAt'), lastUserInputAt=record.get('lastUserInputAt'),
            pullRequest=record.get('pullRequest'))

    app_log = artifacts / 'remote-task-state-times-check-app.log'
    instance = Instance(binary, environment, socket_path, runtime_home, app_log)

    def boot():
        workspaces = instance.wait_until_ready()
        return workspaces[0]['workspaceID'], workspaces[0]['windowID']

    def refresh_pull_requests(window_id):
        # Opening the Tasks view asks GitHub about every open pull request.
        cli_json('action', 'run', 'window.tasks.show', '--window', window_id)
        time.sleep(0.5)
        run_cli('action', 'run', 'window.tasks.hide', '--window', window_id)

    try:
        workspace_id, window_id = boot()
        wait_for('the first terminal in the user home', lambda: str(user_home) in [
            os.path.realpath(cwd) for cwd in next(
                w for w in instance.query('workspace.list')['workspaces'] if w['workspaceID'] == workspace_id
            )['terminalCwds']], interval=1)
        step('booted', workspaceID=workspace_id)

        # 1. Two tasks. The first stays busy; the second ends its turn.
        busy = cli_json('task', 'create', 'Port the importer', '--workspace', workspace_id, '--wait', '--timeout', '90')
        quiet = cli_json('task', 'create', 'Fix the signup email', '--workspace', workspace_id, '--wait', '--timeout', '90')
        busy_id, busy_session = busy['taskID'], busy['setup']['sessionID']
        quiet_id, quiet_session = quiet['taskID'], quiet['setup']['sessionID']
        busy_panel = instance.query('workspace.snapshot', workspaceID=busy['setup']['taskSpaceWorkspaceID'])['slotPanelIDs'][0]

        # The busy agent's conversation, as its SessionStart hook reports it.
        # Toastty then knows the transcript, and restores the agent after a
        # relaunch.
        transcript = root / 'transcript.jsonl'
        transcript.write_text('{"type":"summary"}\n')
        cli_json('session', 'ingest-agent-event', '--source', 'claude-hooks', '--session', busy_session, '--panel', busy_panel,
                 stdin=json.dumps(dict(hook_event_name='SessionStart', session_id='11111111-2222-4333-8444-555555555555',
                                       transcript_path=str(transcript), cwd=str(user_home))))

        # 2. A state that is reported again keeps its times.
        report(busy_session, 'working')
        first = wait_for('the busy task to run', lambda: (t := times(task(busy_id)))['agentState'] == 'busy' and t)
        require(first['stage'] == 'running' and first['interruptedAtQuit'] is False, f'Unexpected start: {first}')
        require(first['stageChangedAt'] and first['agentChangedAt'], f'No times: {first}')
        time.sleep(SETTLE)
        report(busy_session, 'working', detail='Running the tests')
        again = times(task(busy_id))
        require(again['stageChangedAt'] == first['stageChangedAt'] and again['agentChangedAt'] == first['agentChangedAt'],
                f'A repeated report moved a time: {first} -> {again}')
        step('a repeated status keeps the times', first=first, again=again)

        # 3. The transcript's modification time is the last output.
        output = wait_for('the transcript to be known', lambda: task(busy_id)['agentState'].get('lastOutputAt'))
        require(abs(parse(output) - transcript.stat().st_mtime) < 1.5, f'lastOutputAt is not the file time: {output}')
        time.sleep(1.2)
        with transcript.open('a') as file:
            file.write('{"type":"assistant"}\n')
        later = task(busy_id)['agentState']['lastOutputAt']
        require(parse(later) > parse(output) and abs(parse(later) - transcript.stat().st_mtime) < 1.5,
                f'lastOutputAt did not follow the transcript: {output} -> {later}')
        step('last output follows the transcript', before=output, after=later)

        # 4. A message from another agent is not the user's input.
        sent = cli_json('task', 'send', busy_id, 'Also port the exporter')
        require(sent.get('delivered') is True, f'task send was not delivered: {sent}')
        require(task(busy_id).get('lastUserInputAt') is None, f'task send counted as user input: {task(busy_id)}')
        step('task send is not user input', lastUserInputAt=task(busy_id).get('lastUserInputAt'))

        # 5. The second task's turn ends: its stage and agent times move.
        report(quiet_session, 'working')
        started = wait_for('the quiet task to run', lambda: (t := times(task(quiet_id)))['agentState'] == 'busy' and t)
        time.sleep(SETTLE)
        report(quiet_session, 'idle')
        idle = wait_for('the quiet task to be idle', lambda: (t := times(task(quiet_id)))['stage'] == 'idle' and t)
        require(parse(idle['stageChangedAt']) > parse(started['stageChangedAt']), f'The stage time did not move: {started} -> {idle}')
        require(parse(idle['agentChangedAt']) > parse(started['agentChangedAt']), f'The agent time did not move: {started} -> {idle}')
        step('the end of a turn moves the times', running=started, idle=idle)

        # 6. A status that flickers and returns keeps the stage time.
        time.sleep(SETTLE)
        report(quiet_session, 'working')
        report(quiet_session, 'idle')
        flickered = times(task(quiet_id))
        require(flickered['stage'] == 'idle' and flickered['stageChangedAt'] == idle['stageChangedAt'],
                f'A flicker moved the stage time: {idle} -> {flickered}')
        step('a flicker keeps the stage time', before=idle, after=flickered)

        # 7. The second task gets a pull request whose checks are pending.
        prs['1'] = dict(number=1, state='OPEN', branch='fix-signup', head=f'{1:040d}', pending=True)
        save_prs()
        cli_json('action', 'run', 'workspace.set-annotation', '--workspace', quiet['setup']['taskSpaceWorkspaceID'],
                 'key=github-pr', 'text=PR #1', f'url=https://github.com/{SLUG}/pull/1')
        refresh_pull_requests(window_id)
        pending = wait_for('pending checks', lambda: (t := times(task(quiet_id)))['pullRequest']
                           and t['pullRequest'].get('checks') == 'pending' and t)
        require(pending['pullRequest']['mergeStateStatus'] == 'BLOCKED' and pending['pullRequest']['checksPendingSince'],
                f'Unexpected pull request: {pending}')
        require(pending['stage'] == 'needsYou' and pending['attention'] == 'review', f'Expected a review: {pending}')
        step('pending checks are reported', task=pending)
        time.sleep(SETTLE)

        # 8. Crash while the first agent is busy, then relaunch.
        before_kill = times(task(busy_id))
        require(before_kill['agentState'] == 'busy', f'The agent should be busy at the crash: {before_kill}')
        killed_at = time.time()
        instance.kill()
        step('killed while busy', task=before_kill)
        instance = Instance(binary, environment, socket_path, runtime_home, app_log)
        _, window_id = boot()
        cut = wait_for('the interrupted turn to be reported',
                       lambda: (t := times(task(busy_id)))['interruptedAtQuit'] is True and t)
        require(cut['stage'] != 'running' and cut['agentState'] in ('idle', 'notRunning'), f'Unexpected state after relaunch: {cut}')
        require(parse(cut['stageChangedAt']) >= int(killed_at), f'The new stage should start at the relaunch: {cut}')
        other = times(task(quiet_id))
        require(other['interruptedAtQuit'] is False, f'An idle agent was reported as interrupted: {other}')
        require(other['stage'] == 'needsYou' and other['attention'] == 'review'
                and other['stageChangedAt'] == pending['stageChangedAt'],
                f'The same stage should keep its time across the relaunch: {pending} -> {other}')
        step('relaunched after the crash', interrupted=cut, sameStage=other)

        refresh_pull_requests(window_id)
        kept = wait_for('pending checks after the relaunch', lambda: (t := times(task(quiet_id)))['pullRequest'] and t)
        require(kept['pullRequest']['checksPendingSince'] == pending['pullRequest']['checksPendingSince'],
                f'Pending checks should keep their time: {pending} -> {kept}')
        prs['1']['pending'] = False
        save_prs()
        refresh_pull_requests(window_id)
        passed = wait_for('passing checks', lambda: (t := times(task(quiet_id)))['pullRequest']
                          and t['pullRequest'].get('checks') == 'passing' and t)
        require(passed['pullRequest']['checksPendingSince'] is None and passed['pullRequest']['mergeStateStatus'] == 'CLEAN',
                f'Unexpected pull request after the checks: {passed}')
        step('checks kept their time, then passed', kept=kept['pullRequest'], passed=passed['pullRequest'])

        # 9. The restored agent's next turn clears the mark.
        restored = wait_for('the agent to be restored', lambda: task(busy_id)['agentState'].get('sessionID'), timeout=90)
        require(restored != busy_session, 'The restored agent should have a new session')
        report(restored, 'working')
        cleared = wait_for('the mark to clear', lambda: (t := times(task(busy_id)))['interruptedAtQuit'] is False and t)
        require(cleared['agentState'] == 'busy' and cleared['stage'] == 'running', f'Unexpected state in the new turn: {cleared}')
        # Running again is a new stage, not the one the crash cut off.
        require(parse(cleared['stageChangedAt']) >= int(killed_at), f'The new turn kept the old stage time: {cleared}')
        step('the next turn clears the mark', task=cleared)

        # 10. Quit through AppKit while the agent is busy. The quit question
        # is turned off for this throwaway instance first.
        suite = json.loads((runtime_home / 'instance.json').read_text()).get('userDefaultsSuiteName')
        helper = root / 'quit-helper'
        (root / 'quit-helper.swift').write_text(QUIT_HELPER)
        built = subprocess.run(['swiftc', '-O', str(root / 'quit-helper.swift'), '-o', str(helper)],
                               capture_output=True, text=True)
        quit_done = False
        if suite and built.returncode == 0:
            subprocess.run(['defaults', 'write', suite, 'toastty.askBeforeQuitting', '-bool', 'false'], env=environment, check=False)
            instance.kill()
            instance = Instance(binary, environment, socket_path, runtime_home, app_log)
            _, window_id = boot()
            session = wait_for('the agent to be restored again', lambda: task(busy_id)['agentState'].get('sessionID'), timeout=90)
            report(session, 'working')
            wait_for('the agent to be busy', lambda: task(busy_id)['agentState']['state'] == 'busy')
            asked = subprocess.run([str(helper), str(instance.process.pid)], capture_output=True, text=True, timeout=30)
            try:
                instance.process.wait(timeout=30)
                instance.log.close()
                quit_done = True
            except subprocess.TimeoutExpired:
                step('quit unavailable', helper=asked.returncode, stderr=asked.stderr.strip())
        else:
            step('quit unavailable', suite=suite, swiftc=built.stderr.strip()[-400:])
        if quit_done:
            instance = Instance(binary, environment, socket_path, runtime_home, app_log)
            boot()
            after_quit = wait_for('the turn the quit cut off',
                                  lambda: (t := times(task(busy_id)))['interruptedAtQuit'] is True and t)
            step('relaunched after the quit', task=after_quit)

        evidence['status'] = 'passed'
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / 'remote-task-state-times-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print('[state-times-check] passed', flush=True)


if __name__ == '__main__':
    main()

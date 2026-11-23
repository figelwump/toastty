#!/usr/bin/env python3
"""Move a task into its own git worktree with a real agent, in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-start-work-check.py [--provider codex|claude] [--gui-session]'.

The check starts its own second instance of the wrapper's build, with a
throwaway runtime home. Its user home is a git repository with a bare
`origin` beside it, so the first terminal starts in the repository and it
becomes the workspace's project root. `agents.toml` holds the real provider
CLI, and `tasks.toml` makes it the default and sets a `create_hook`. A commit
pushed to the remote after the clone checks that the worktree starts from a
fresh fetch. Subscription usage is consumed. Claude's login lives in the GUI
session on a host driven over SSH, so add --gui-session for Claude.

It checks that:
- the task's agent, told to run `toastty task start-work`, ends its turn, and
  Toastty makes the worktree from the fetched remote tip, runs the hook, forks
  the conversation into a new tab in the worktree, confirms the fork's own
  conversation, and closes the old pane; the fork still knows the instructions
  from before the move. While the move runs, the task lists with Running,
  keeps its one task space, and the sidebar shows no Inbox and one row for
  it, whose summary names the move's step;
- `task create --start-work` starts a fresh agent in a new worktree;
- a move that fails, here on a base that does not exist, keeps the old session;
- a task's agent that runs `task create --fork --start-work` keeps running and
  unchanged, while the new task's agent starts in its own worktree as a fork
  of that conversation: it knows a code word that only the parent's
  conversation holds, and its provider transcript contains the parent's
  first message.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

MOVE_REPLY = 'MOVING'
FORK_REPLY = 'MOVED-INTO-WORKTREE'
TASK_TEXT = (
    'This is an automated Toastty check. Do not edit files.\n'
    f'1. Now: run exactly this one shell command, and no other command: "$TOASTTY_CLI_PATH" task start-work --branch-prefix live\n'
    f'   Then reply with exactly {MOVE_REPLY} and end your turn.\n'
    f'2. Later, when a message says Toastty moved this conversation into a worktree: run no command, '
    f'and reply with exactly {FORK_REPLY}.'
)
FRESH_TEXT = 'This is an automated Toastty check. Run no command and edit no file. Reply with exactly STARTED.'
FORK_CODE = f'KIWI-{uuid.uuid4().hex[:6].upper()}'
FORKING_REPLY = 'FORKING'
FORK_CHILD_TITLE = 'This is an automated Toastty check child'
FORK_CHILD_TEXT = 'This is an automated Toastty check. Run no command and edit no file. Follow the earlier instructions for a fork.'
FORK_PARENT_TEXT = (
    'This is an automated Toastty check. Do not edit files.\n'
    f'Remember this code word: {FORK_CODE}\n'
    '1. Now: run exactly this one shell command, and no other command: '
    f'"$TOASTTY_CLI_PATH" task create "{FORK_CHILD_TEXT}" --fork --start-work --branch-prefix live --title "{FORK_CHILD_TITLE}"\n'
    f'   Then reply with exactly {FORKING_REPLY} and end your turn.\n'
    '2. Later, if a message says that you are now the agent of another task: run no command, '
    'and reply with exactly FORKED- followed by the code word.'
)


def git(*arguments, cwd):
    return subprocess.run(['git', *arguments], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('codex', 'claude'), default='codex')
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    provider = options.provider
    if options.gui_session:
        queue_check.run_in_gui_session(f'remote-task-start-work-{provider}', __file__, ['--provider', provider])

    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')
    prefix = f'remote-task-start-work-{provider}'

    root = Path(tempfile.mkdtemp(prefix='toastty-start-work-check-', dir='/tmp')).resolve()
    runtime_home = root / 'runtime-home'
    runtime_home.mkdir()
    # Codex trusts the host home's subfolders, and worktrees land next to the
    # repository, so both stay inside it. Claude trusts only marked folders.
    parent = Path.home() / 'toastty-queue-steer-checks' / f'start-work-{uuid.uuid4().hex[:8]}'
    parent.mkdir(parents=True)
    repository, remote, seed = parent / 'project', root / 'origin.git', root / 'seed'
    git('init', '-q', '-b', 'main', str(seed), cwd=root)
    git('-c', 'user.name=Check', '-c', 'user.email=check@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'first', cwd=seed)
    git('clone', '-q', '--bare', str(seed), str(remote), cwd=root)
    git('clone', '-q', str(remote), str(repository), cwd=root)
    git('remote', 'add', 'origin', str(remote), cwd=seed)
    git('-c', 'user.name=Check', '-c', 'user.email=check@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'upstream', cwd=seed)
    git('push', '-q', 'origin', 'main', cwd=seed)
    remote_tip = git('rev-parse', 'HEAD', cwd=seed)
    project_head = git('rev-parse', 'HEAD', cwd=repository)
    (repository / '.git/info/exclude').write_text('.toastty/\n.codex\n.claude\n')
    toastty_dir = repository / '.toastty'
    toastty_dir.mkdir()
    # The app's home is the repository, so that its first terminal starts
    # there, but Toastty finds a session's conversation in the provider's
    # files under the home folder; link the real ones, which the agents use.
    for name in ('.codex', '.claude'):
        if (Path.home() / name).exists():
            (repository / name).symlink_to(Path.home() / name)

    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    version, argv = provider_profile(provider, environment, repository)
    (toastty_dir / 'agents.toml').write_text(
        f'[{provider}]\ndisplayName = "{provider}"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n')
    (toastty_dir / 'tasks.toml').write_text(
        f'[defaults]\nagent = "{provider}"\n\n'
        f'[workspace.{json.dumps(str(repository))}]\ncreate_hook = "touch hook-ran"\n')
    trusted = [repository, parent / 'project-this-is-an-automated-toastty-check-do', parent / 'project-this-is-an-automated-toastty-check-run',
               parent / 'project-this-is-an-automated-toastty-check-child']
    if provider == 'claude':
        for directory in trusted:
            queue_check.set_directory_trust(directory, True)

    socket_path = str(root / 'socket.sock')
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-start-work-check',
        TOASTTY_SOCKET_PATH=socket_path,
        CFFIXED_USER_HOME=str(repository),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', provider=provider, cliVersion=version, remoteTip=remote_tip, steps=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, **facts))
        print(f'[start-work-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments, session=None):
        cli_environment = dict(environment)
        if session:
            cli_environment['TOASTTY_SESSION_ID'] = session
        result = subprocess.run([str(cli), '--json', *arguments], env=cli_environment,
                                capture_output=True, text=True, timeout=600)
        return result.returncode, result.stdout, result.stderr

    answered = []

    def answer_dialogs():
        """Answers Codex's folder trust and update prompts as a person would,
        and records each one: a trust prompt in the fork's worktree would mean
        a real move stops there."""
        for workspace in instance.query('workspace.list')['workspaces']:
            for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
                try:
                    text = instance.query('terminal.visible-text', panelID=panel, tail=40).get('text', '')
                except AssertionError:
                    continue
                if 'Trust this folder?' in text and 'Trust and continue' in text:
                    choice, kind = '1', 'trust'
                elif 'Update available' in text and 'Skip' in text:
                    choice, kind = '3', 'update'
                else:
                    continue
                folder = next((line.strip() for line in text.splitlines() if line.strip().startswith('/')), None)
                if (panel, kind, folder) in [(a['panel'], a['kind'], a['folder']) for a in answered]:
                    continue
                answered.append(dict(panel=panel, kind=kind, folder=folder, at=time.time()))
                step('answered a dialog', panel=panel, kind=kind, folder=folder)
                instance.request('app_control.run_action', dict(
                    id='terminal.send-text', args=dict(panelID=panel, text=choice, submit=True)))

    def answering(probe):
        def wrapped():
            answer_dialogs()
            return probe()
        return wrapped

    def task(task_id):
        code, out, err = run_cli('task', 'get', task_id)
        require(code == 0, f'task get failed: {out} {err}')
        return json.loads(out)['result']

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{prefix}-app.log')
    try:
        workspace_id = instance.wait_until_ready()[0]['workspaceID']

        def terminal_in_repository():
            listed = instance.query('workspace.list')['workspaces']
            cwds = next(w for w in listed if w['workspaceID'] == workspace_id)['terminalCwds']
            return str(repository) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the repository', terminal_in_repository, interval=1)
        step('booted', workspaceID=workspace_id)

        # 1. The agent moves its own task into a worktree.
        code, out, err = run_cli('task', 'create', TASK_TEXT, '--title', 'This is an automated Toastty check do',
                                 '--workspace', workspace_id, '--wait', '--timeout', '120')
        require(code == 0, f'task create failed ({code}): {out} {err}')
        created = json.loads(out)['result']
        task_id, task_space = created['taskID'], created['setup']['taskSpaceWorkspaceID']
        source_session, source_panel = created['setup']['sessionID'], None
        snapshot = instance.query('workspace.snapshot', workspaceID=task_space)
        source_panel = next(iter(panel_ids(snapshot)))
        step('task started', taskID=task_id, taskSpace=task_space, sourceSession=source_session, sourcePanel=source_panel)

        # While the move runs, sample the task's stage, the sidebar's
        # accessibility labels and the workspace count.
        driver = root / 'quick-entry-ui-driver'
        subprocess.run(['swiftc', '-O', str(Path(__file__).with_name('quick-entry-ui-driver.swift')), '-o', str(driver)], check=True)
        locked = subprocess.run([str(driver), 'locked'], capture_output=True, text=True, timeout=60).stdout.strip()
        require(locked == '0', 'The remote screen is locked; unlock it to read the sidebar')
        listed = instance.query('workspace.list')['workspaces']
        space_title = next(w['title'] for w in listed if w['workspaceID'] == task_space)
        workspace_count = len(listed)
        samples = []

        def sample_move():
            current = task(task_id)
            result = subprocess.run([str(driver), 'labels', str(instance.process.pid), '*'],
                                    capture_output=True, text=True, timeout=60)
            labels = json.loads(result.stdout) if result.returncode == 0 else []
            samples.append(dict(
                at=time.time(),
                move=current.get('worktree', {}).get('state'),
                stage=current['stage'],
                workspaces=len(instance.query('workspace.list')['workspaces']),
                rows=[label for label in labels if label.startswith(f'{space_title}, ')],
                inbox=[label for label in labels if 'Inbox' in label],
            ))
            return current if current.get('worktree', {}).get('state') in ('finished', 'failed') else None

        moved = wait_for('the move to finish', answering(sample_move), timeout=600, interval=1)
        evidence['dialogs'] = answered
        evidence['moveSamples'] = samples
        worktree = moved['worktree']
        step('move ended', worktree=worktree)
        during = [sample for sample in samples if sample['move'] == 'running']
        step('move samples', total=len(samples), whileRunning=len(during),
             groups=sorted({sample['stage']['group'] for sample in samples}),
             rowsWhileRunning=sorted({row for sample in during for row in sample['rows']}))
        require(during, 'No sample caught the move while it ran')
        require(all(sample['stage']['group'] == 'running' and sample['stage']['needsUser'] is False for sample in during),
                f'The task left Running while it moved: {[sample["stage"] for sample in during]}')
        require(all(sample['inbox'] == [] for sample in samples), f'An Inbox showed: {[s["inbox"] for s in samples if s["inbox"]]}')
        require(all(len(sample['rows']) <= 1 for sample in samples), f'The task showed more than one row: {[s["rows"] for s in samples if len(s["rows"]) > 1]}')
        require(all(sample['workspaces'] == workspace_count for sample in samples), 'The move made or closed a workspace')
        require(any('Moving to worktree' in row for sample in during for row in sample['rows']),
                f'No row named the move: {[sample["rows"] for sample in during]}')
        require(worktree['state'] == 'finished', f'The move did not finish: {worktree}')
        require(worktree['forked'] is True and worktree['conversationConfirmed'] is True, f'Fork not confirmed: {worktree}')
        require(worktree['source'] == 'closed', f'The old session was not closed: {worktree}')
        require(worktree['baseSHA'] == remote_tip and worktree['baseFetched'] is True, f'Base is not the fetched tip: {worktree}')
        require(worktree['branch'].startswith('live/'), f'Unexpected branch: {worktree}')
        path = Path(worktree['path'])
        require(path.parent == parent and git('rev-parse', 'HEAD', cwd=path) == remote_tip, f'Worktree is not at the tip: {path}')
        require(git('rev-parse', '--abbrev-ref', 'HEAD', cwd=path) == worktree['branch'], 'Worktree is on the wrong branch')
        require((path / 'hook-ran').is_file(), 'create_hook did not run in the worktree')
        # The move must leave the project checkout where it was: same branch,
        # same commit, no tracked changes. Untracked files are recorded.
        evidence['projectUntracked'] = git('status', '--porcelain', '--untracked-files=all', cwd=repository)
        require(git('rev-parse', '--abbrev-ref', 'HEAD', cwd=repository) == 'main', 'The project checkout left main')
        require(git('rev-parse', 'HEAD', cwd=repository) == project_head, 'The project checkout moved')
        require(git('status', '--porcelain', '--untracked-files=no', cwd=repository) == '',
                f"The project checkout has changes: {git('status', '--porcelain', cwd=repository)}")

        snapshot = instance.query('workspace.snapshot', workspaceID=task_space)
        panels = panel_ids(snapshot)
        require(source_panel not in panels, f'The old pane is still there: {panels}')
        fork_text = wait_for('the fork to reply', answering(lambda: visible_text_with(instance, snapshot, FORK_REPLY)), timeout=300, interval=3)
        evidence['forkScreen'] = fork_text[-3000:]
        step('fork continued the conversation', sessionID=worktree['sessionID'], panels=sorted(panels))
        listed = {w['workspaceID']: w for w in instance.query('workspace.list')['workspaces']}
        require(listed[workspace_id]['isSelected'], 'The original workspace lost selection')

        # 2. A task created straight into a worktree starts there fresh.
        code, out, err = run_cli('task', 'create', FRESH_TEXT, '--start-work', '--title', 'This is an automated Toastty check run',
                                 '--workspace', workspace_id)
        require(code == 0, f'task create --start-work failed ({code}): {out} {err}')
        fresh_id = json.loads(out)['result']['taskID']
        fresh = wait_for('the fresh task to start', answering(lambda: (lambda t: t if t['setup']['state'] != 'settingUp' else None)(task(fresh_id))),
                         timeout=300, interval=2)
        require(fresh['worktree']['state'] == 'finished' and fresh['worktree']['baseSHA'] == remote_tip, f'Fresh task: {fresh}')
        fresh_snapshot = instance.query('workspace.snapshot', workspaceID=fresh['setup']['taskSpaceWorkspaceID'])
        require(fresh['worktree']['path'] in json.dumps(fresh_snapshot), 'The fresh task space terminal is not in its worktree')
        step('created into a worktree', worktree=fresh['worktree'])

        # 3. A move that fails keeps the old session. The check sends the
        # request as a plain task's agent, once that agent is idle.
        code, out, err = run_cli('task', 'create', FRESH_TEXT, '--workspace', workspace_id, '--wait', '--timeout', '120')
        require(code == 0, f'plain task create failed ({code}): {out} {err}')
        plain = json.loads(out)['result']
        plain_session = plain['setup']['sessionID']
        plain_snapshot = instance.query('workspace.snapshot', workspaceID=plain['setup']['taskSpaceWorkspaceID'])
        plain_panels = panel_ids(plain_snapshot)
        wait_for('the plain agent to reply', answering(lambda: visible_text_with(instance, plain_snapshot, 'STARTED')), timeout=300, interval=3)
        code, out, err = run_cli('task', 'start-work', '--base', 'does-not-exist', session=plain_session)
        require(code == 0, f'start-work request was refused at once: {out} {err}')
        failed = wait_for('the bad move to fail', lambda: (lambda t: t if t['worktree']['state'] != 'running' else None)(task(plain['taskID'])),
                          timeout=120, interval=1)
        require(failed['worktree']['state'] == 'failed', f'A bad base did not fail: {failed}')
        require('does-not-exist' in failed['worktree']['reason'], f'Unexpected reason: {failed}')
        require(failed['worktree']['source'] is None, f'The old session was touched: {failed}')
        require(panel_ids(instance.query('workspace.snapshot', workspaceID=plain['setup']['taskSpaceWorkspaceID'])) == plain_panels,
                'The old pane changed after a failed move')
        require(failed['sessionID'] == plain_session, 'The task lost its session')
        step('failed move kept the session', reason=failed['worktree']['reason'])

        # 4. A task's agent forks its conversation into a new task, in its own
        # worktree, and keeps running.
        code, out, err = run_cli('task', 'create', FORK_PARENT_TEXT, '--title', 'This is an automated Toastty check fork',
                                 '--workspace', workspace_id, '--wait', '--timeout', '120')
        require(code == 0, f'fork parent task create failed ({code}): {out} {err}')
        fork_parent = json.loads(out)['result']
        parent_id, parent_session = fork_parent['taskID'], fork_parent['setup']['sessionID']
        parent_space = fork_parent['setup']['taskSpaceWorkspaceID']
        parent_panels = panel_ids(instance.query('workspace.snapshot', workspaceID=parent_space))
        step('fork parent started', taskID=parent_id, sessionID=parent_session, panels=sorted(parent_panels))

        def children():
            code, out, err = run_cli('task', 'list', '--parent', parent_id)
            require(code == 0, f'task list failed: {out} {err}')
            return json.loads(out)['result']['tasks']

        child_id = wait_for('the forked task', answering(lambda: next((t['taskID'] for t in children()), None)),
                            timeout=300, interval=2)
        child = wait_for('the fork to start', answering(lambda: (lambda t: t if t['setup']['state'] != 'settingUp' else None)(task(child_id))),
                         timeout=600, interval=2)
        step('forked task set up', child=child)
        require(child['setup']['state'] == 'started', f'The forked task did not start: {child}')
        require(child['parentTaskID'] == parent_id, f'The forked task has the wrong parent: {child}')
        require(child['fork']['sourceSessionID'] == parent_session and child['fork']['conversationConfirmed'] is True,
                f'Fork not confirmed: {child}')
        require(child['agent'] == provider and child['title'] == FORK_CHILD_TITLE, f'Unexpected forked task: {child}')
        child_path = Path(child['worktree']['path'])
        require(child['worktree']['state'] == 'finished' and child['worktree']['branch'].startswith('live/'), f'Fork worktree: {child}')
        require(child_path.parent == parent and git('rev-parse', 'HEAD', cwd=child_path) == remote_tip, f'Fork worktree is not at the tip: {child_path}')
        child_snapshot = instance.query('workspace.snapshot', workspaceID=child['setup']['taskSpaceWorkspaceID'])
        require(str(child_path) in json.dumps(child_snapshot), 'The forked task space terminal is not in its worktree')
        require(child['sessionID'] != parent_session, 'The forked task reuses the parent session')

        # The fork knows the code word, which only the parent's conversation
        # holds: Toastty's first message to it does not contain it.
        reply = wait_for('the fork to reply with the code word',
                         answering(lambda: (lambda r: r if r and FORK_CODE in r.get('text', '') else None)(task(child_id).get('lastReply'))),
                         timeout=300, interval=3)
        require(reply['text'].strip() == f'FORKED-{FORK_CODE}', f'Unexpected fork reply: {reply}')
        transcript = fork_transcript(provider, child_id)
        require(transcript is not None, f'No {provider} transcript names the forked task {child_id}')
        transcript_text = transcript.read_text(errors='replace')
        require(FORK_CODE in transcript_text and 'Remember this code word' in transcript_text,
                f'The fork transcript {transcript} lacks the parent conversation')
        evidence['forkTranscript'] = str(transcript)
        step('fork continued the parent conversation', reply=reply, transcript=str(transcript))

        # The parent keeps running, unchanged: same session and panes, and
        # nothing new typed into it after its own reply.
        parent_now = task(parent_id)
        require(parent_now['sessionID'] == parent_session, f'The parent session changed: {parent_now}')
        require(parent_now['agentState']['state'] in ('idle', 'busy', 'waiting'), f'The parent stopped: {parent_now}')
        require((parent_now.get('lastReply') or {}).get('text', '').strip() == FORKING_REPLY,
                f'The parent got another message: {parent_now.get("lastReply")}')
        require(panel_ids(instance.query('workspace.snapshot', workspaceID=parent_space)) == parent_panels,
                'The parent pane changed after the fork')
        step('fork parent kept running', agentState=parent_now['agentState'])

        evidence['status'] = 'passed'
    except Exception as error:  # Always keep the failure evidence.
        evidence['failure'] = repr(error)
        try:
            screens = {}
            for workspace in instance.query('workspace.list')['workspaces']:
                snapshot = instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])
                for panel in panel_ids(snapshot):
                    try:
                        screens[panel] = instance.query('terminal.visible-text', panelID=panel, tail=40).get('text', '')[-2000:]
                    except AssertionError:
                        pass
            evidence['screens'] = screens
            evidence['tasks'] = json.loads(run_cli('task', 'list')[1])['result']['tasks']
        except Exception as diagnostics_error:
            evidence['diagnosticsError'] = repr(diagnostics_error)
        raise
    finally:
        instance_log = runtime_home / 'logs/toastty.log'
        if instance_log.is_file():
            shutil.copyfile(instance_log, artifacts / f'{prefix}-instance.log')
            evidence['logLines'] = [line for line in instance_log.read_text().splitlines()
                                    if 'task' in line.lower() and ('worktree' in line.lower() or 'move' in line.lower())]
        (artifacts / f'{prefix}.json').write_text(json.dumps(evidence, indent=2, sort_keys=True, default=str))
        try:
            instance.kill()
        except Exception:
            pass
        if provider == 'claude':
            for directory in trusted:
                queue_check.set_directory_trust(directory, False)
        else:
            forget_codex_trust(parent)
        shutil.rmtree(parent, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps(evidence, indent=2, sort_keys=True, default=str))


def provider_profile(provider, environment, repository):
    if provider == 'codex':
        cli = shutil.which('codex', path=environment.get('PATH'))
        require(cli, 'Codex CLI is not installed on the remote host')
        version = subprocess.check_output([cli, '--version'], text=True, timeout=30).strip()
        # The host's default sandbox asks before the socket call, and nobody
        # is there to answer; this run-owned profile skips that.
        return version, [cli, '--dangerously-bypass-approvals-and-sandbox']
    cli = shutil.which('claude', path=environment.get('PATH')) or str(Path.home() / '.local/bin/claude')
    require(Path(cli).is_file(), 'Claude CLI is not installed on the remote host')
    version = subprocess.check_output([cli, '--version'], text=True, timeout=30, env=environment).strip()
    # The plain command, as a user's profile has it: Toastty adds a fork's
    # arguments only to argv it can read, and refuses tool and settings
    # restrictions there.
    return version, [cli]


def fork_transcript(provider, task_id):
    """The provider transcript whose first message names `task_id`: the
    forked agent's own conversation file."""
    if provider == 'claude':
        roots, pattern = [Path.home() / '.claude/projects'], '*.jsonl'
    else:
        roots, pattern = [Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')) / 'sessions'], 'rollout-*.jsonl'
    cutoff = time.time() - 3600
    for root in roots:
        for path in sorted(root.rglob(pattern), key=lambda p: p.stat().st_mtime, reverse=True):
            if path.stat().st_mtime < cutoff:
                break
            if f'task ID {task_id}' in path.read_text(errors='replace'):
                return path
    return None


def forget_codex_trust(parent):
    """Removes the trust entries this run saved for its folders from the
    host's Codex config, leaving every other line alone."""
    config = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')) / 'config.toml'
    if not config.is_file():
        return
    kept, skipping = [], False
    for line in config.read_text().splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith('['):
            skipping = stripped.startswith(f'[projects."{parent}')
        if not skipping:
            kept.append(line)
    temporary = config.with_name(config.name + '.toastty-check')
    temporary.write_text(''.join(kept))
    os.replace(temporary, config)


def panel_ids(snapshot):
    """Every panel ID in a workspace snapshot, wherever the shape keeps it."""
    found = set()

    def walk(value):
        if isinstance(value, dict):
            if isinstance(value.get('panelID'), str):
                found.add(value['panelID'])
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(snapshot)
    return found


def visible_text_with(instance, snapshot, marker):
    """The screen of a panel where the agent replied with `marker` on a line
    of its own. The instructions quote the marker too, so a mention inside
    them does not count."""
    for panel in panel_ids(snapshot):
        try:
            text = instance.query('terminal.visible-text', panelID=panel, tail=60).get('text', '')
        except AssertionError:
            continue
        for line in text.splitlines():
            if line.strip() in (f'• {marker}', f'⏺ {marker}'):
                return text
    return None


if __name__ == '__main__':
    main()

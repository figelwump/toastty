#!/usr/bin/env python3
"""Merge, release, archive and cancel tasks with a real agent, in a disposable app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-task-merge-check.py'. It needs an unlocked
screen: it presses the sidebar's buttons and menus in its own app instance
and captures its window. A real Codex agent runs the merge prompt (subscription
usage is consumed).

The check starts its own instance of the wrapper's build, with a throwaway
runtime home, a repository whose origin is a local bare repository, and a fake
`gh` first on the instance's login-shell PATH. The fake `gh` serves one pull
request per task and merges by pushing the accepted commit to origin's main.
Through the real UI and CLI it checks that:
- Merge, then Merge again to confirm, on the task's Needs you row in the
  sidebar sends the project's merge_prompt to the task's
  agent, which runs `task merge` mid-turn; Toastty merges at the checked
  commit, and once the agent's turn ends closes the task space, removes the
  worktree and deletes both branches; the task is To ship;
- `task release` starts a release task in a worktree on no branch at
  origin's main; a tag pushed to origin ships the task and the
  release, and the release's task space and worktree are cleaned up;
- `task archive` refuses uncommitted changes, then with --discard-changes
  removes the worktree and keeps a branch with unpushed commits;
- Merge Without Checks, from the Needs you row's menu, waits for a pending
  check, and Cancel Merge, from the task space row's menu, ends the wait
  without merging.
The coordinator runs a fake agent: opening its chat reads tasks.toml again,
asks GitHub, and looks for release tags.
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

HERE = Path(__file__).parent


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
start_work_check = _load('remote_task_start_work_check', 'remote-task-start-work-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance
panel_ids, visible_text_with = start_work_check.panel_ids, start_work_check.visible_text_with

PREFIX = 'remote-task-merge'
SLUG = 'toastty-check/project'

# Serves `gh` for the pull requests in $FAKE_GH_STATE: {"<number>": {...}}.
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
path = os.environ.get("FAKE_GH_STATE") or open(os.path.join(os.path.dirname(__file__), "state-path")).read().strip()
state = json.load(open(path))
args = sys.argv[1:]
with open(path + ".log", "a") as log:
    log.write(json.dumps(args) + "\n")
def save():
    json.dump(state, open(path, "w"))
def number_of(value):
    return value.rstrip("/").split("/")[-1]
def view(pr):
    checks = [{"name": "CI gate", "status": "IN_PROGRESS" if pr["pending"] else "COMPLETED",
               "conclusion": None if pr["pending"] else "SUCCESS"}]
    return {"number": int(pr["number"]), "state": pr["state"], "isDraft": False, "headRefName": pr["branch"],
            "headRefOid": pr["head"], "baseRefName": "main", "isCrossRepository": False, "mergeable": "MERGEABLE",
            "mergeStateStatus": "BLOCKED" if pr["pending"] else "CLEAN", "statusCheckRollup": checks,
            "url": f"https://github.com/%s/pull/{pr['number']}" % state["slug"], "body": "",
            "mergeCommit": {"oid": pr["head"]} if pr["state"] == "MERGED" else None, "autoMergeRequest": None}
if args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": state["slug"], "defaultBranchRef": {"name": "main"}, "mergeCommitAllowed": True}))
elif args[:2] == ["pr", "view"]:
    pr = state["prs"][number_of(args[2])]
    out = view(pr)
    if "--jq" in args:
        print(out[args[args.index("--jq") + 1].lstrip(".")])
    else:
        print(json.dumps(out))
elif args[:2] == ["api", "--method"] and args[2] == "PUT":
    number = args[3].split("/")[-2]
    pr = state["prs"][number]
    sha = next(a.split("=", 1)[1] for a in args if a.startswith("sha="))
    if sha != pr["head"] or pr["pending"]:
        sys.exit("merge refused")
    subprocess.run(["git", "-C", state["project"], "push", "--quiet", "origin", f"{sha}:refs/heads/main"], check=True)
    pr["state"] = "MERGED"
    save()
elif args[:2] == ["pr", "close"]:
    state["prs"][number_of(args[2])]["state"] = "CLOSED"
    save()
else:
    sys.exit(f"unexpected gh call: {args}")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('codex', 'claude'), default='codex')
    options = parser.parse_args()
    provider = options.provider
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-merge-check-', dir='/tmp')).resolve()
    helper, driver = root / 'task-stages-ui-helper', root / 'quick-entry-ui-driver'
    for source, output in ((HERE / 'task-stages-ui-helper.swift', helper), (HERE / 'quick-entry-ui-driver.swift', driver)):
        subprocess.run(['swiftc', '-O', str(source), '-o', str(output)], check=True)

    def run_tool(tool, *arguments, check=True):
        result = subprocess.run([str(tool), *map(str, arguments)], capture_output=True, text=True, timeout=60)
        if check:
            require(result.returncode == 0, f'{tool.name} {arguments[0]} failed: {result.stderr.strip()}')
        return result

    require(run_tool(driver, 'locked').stdout.strip() == '0', 'The remote screen is locked; unlock it to press buttons')

    runtime_home = root / 'runtime-home'
    runtime_home.mkdir()
    # Codex trusts the host home's subfolders, so the repository stays there.
    parent = Path.home() / 'toastty-queue-steer-checks' / f'merge-{uuid.uuid4().hex[:8]}'
    parent.mkdir(parents=True)
    origin, repository = parent / 'origin.git', parent / 'project'

    def git(*arguments, cwd=repository):
        return subprocess.run(['git', '-C', str(cwd), *arguments], check=True, capture_output=True, text=True).stdout.strip()

    subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(origin)], check=True)
    subprocess.run(['git', 'clone', '-q', str(origin), str(repository)], check=True, capture_output=True)
    git('config', 'user.name', 'Merge Check')
    git('config', 'user.email', 'merge-check@example.invalid')
    (repository / 'README.md').write_text('merge check\n')
    git('add', '.')
    git('commit', '-q', '-m', 'base')
    git('push', '-q', 'origin', 'main')
    (repository / '.git/info/exclude').write_text('.toastty/\n.codex\n.claude\n')
    toastty_dir = repository / '.toastty'
    toastty_dir.mkdir()
    for name in ('.codex', '.claude'):
        if (Path.home() / name).exists():
            (repository / name).symlink_to(Path.home() / name)

    # The fake gh, first on the PATH the instance's login shell reports.
    fake_bin, zdotdir = parent / 'bin', parent / 'zdotdir'
    fake_bin.mkdir()
    zdotdir.mkdir()
    gh_state = parent / 'gh-state.json'
    gh_state.write_text(json.dumps(dict(slug=SLUG, project=str(repository), prs={})))
    (fake_bin / 'gh').write_text(FAKE_GH)
    (fake_bin / 'gh').chmod(0o755)
    (fake_bin / 'state-path').write_text(str(gh_state))
    for name in ('.zshenv', '.zprofile'):
        (zdotdir / name).write_text(f'[ -f "$HOME/{name}" ] && source "$HOME/{name}"\n')
    (zdotdir / '.zshrc').write_text(f'[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"\nexport PATH="{fake_bin}:$PATH"\n')

    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    version, argv = start_work_check.provider_profile(provider, environment, repository)
    if provider == 'codex':
        argv = [argv[0], '-c', 'check_for_update_on_startup=false', *argv[1:]]
    coordinator_agent = fake_bin / 'coordinator-agent'
    coordinator_agent.write_text(create_check.FAKE_AGENT)
    coordinator_agent.chmod(0o755)
    (toastty_dir / 'agents.toml').write_text(
        f'[{provider}]\ndisplayName = "{provider}"\nargv = {json.dumps(argv)}\ninitialPromptPlacement = "trailing"\n\n'
        f'[coordinator-check]\ndisplayName = "Coordinator check"\nargv = {json.dumps([str(coordinator_agent)])}\n')
    merge_prompt = ('This is an automated Toastty check. Run exactly this one shell command, with no arguments '
                    'added, and no other command:\n"$TOASTTY_CLI_PATH" task merge\n'
                    'Then reply with exactly MERGE-REQUESTED and end your turn.')
    release_prompt = 'This is an automated Toastty check. Run no command and edit no file. Reply with exactly RELEASE-READY.'
    (toastty_dir / 'tasks.toml').write_text(
        f'[defaults]\nagent = "{provider}"\n\n[coordinator]\nagent = "coordinator-check"\n\n'
        f'[workspace.{json.dumps(str(repository))}]\nrelease_tags = "v*"\n'
        f'release_prompt = {json.dumps(release_prompt)}\nmerge_prompt = {json.dumps(merge_prompt)}\n')

    socket_path = str(root / 'socket.sock')
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL='remote-task-merge-check',
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        TOASTTY_AUTOMATION='1',
        TOASTTY_ARTIFACTS_DIR=str(artifacts),
        CFFIXED_USER_HOME=str(repository),
        ZDOTDIR=str(zdotdir),
        DISABLE_AUTOUPDATER='1',
    )
    evidence = dict(status='failed', provider=provider, cliVersion=version, steps=[], captures=[])

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[merge-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def run_cli(*arguments, timeout=300):
        result = subprocess.run([str(cli), '--json', *arguments], env=environment,
                                capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr

    def cli_result(*arguments):
        code, out, err = run_cli(*arguments)
        require(code == 0, f'{" ".join(arguments[:3])} failed ({code}): {out} {err}')
        return json.loads(out)['result']

    def task(task_id):
        return cli_result('task', 'get', task_id)

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')
    pid = instance.process.pid

    def action(action_id, **args):
        response = instance.request('app_control.run_action', dict(id=action_id, args=args))
        require(response.get('ok'), f'{action_id} failed: {response}')
        return response.get('result')

    def capture(name):
        """Evidence only: a capture that cannot be made is recorded, not
        failed. `automation.capture_screenshot` renders in the app, which
        works over SSH but needs automation mode; a window capture needs
        Screen Recording."""
        path = artifacts / f'{PREFIX}-{name}.png'
        # The first agent launch announces Toastty's skills over the content;
        # dismiss it so the capture shows the sidebar.
        if run_tool(helper, 'exists', pid, 'xmark', check=False).returncode == 0:
            run_tool(helper, 'press', pid, 'xmark', check=False)
        time.sleep(0.8)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        if response.get('ok'):
            shutil.copyfile(response['result']['path'], path)
        else:
            result = run_tool(helper, 'capture', pid, path, check=False)
            if result.returncode != 0:
                step('capture unavailable', file=path.name, app=response.get('error'), window=result.stderr.strip())
                return
        evidence['captures'].append(path.name)

    def press(identifier):
        wait_for(f'{identifier} on screen', lambda: run_tool(helper, 'exists', pid, identifier, check=False).returncode == 0,
                 timeout=30, interval=0.5)
        run_tool(helper, 'press', pid, identifier)
        step('pressed', button=identifier)

    def answer_dialogs():
        """Answers Codex's folder trust prompt, as a person would, once per panel."""
        for workspace in instance.query('workspace.list')['workspaces']:
            for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
                try:
                    text = instance.query('terminal.visible-text', panelID=panel, tail=40).get('text', '')
                except AssertionError:
                    continue
                trust = text.rfind('Trust this folder?')
                if trust >= 0 and 'Trust and continue' in text[trust:] and panel not in evidence.setdefault('trusted', []):
                    evidence['trusted'].append(panel)
                    instance.request('app_control.run_action', dict(
                        id='terminal.send-text', args=dict(panelID=panel, text='1', submit=True)))

    def reply_on(record, marker, timeout=300):
        def probe():
            answer_dialogs()
            snapshot = instance.query('workspace.snapshot', workspaceID=task(record['taskID'])['setup']['taskSpaceWorkspaceID'])
            return visible_text_with(instance, snapshot, marker)
        return wait_for(f'{marker} on screen', probe, timeout=timeout, interval=3)

    def started_task(title, marker):
        text = ('This is an automated Toastty check. Run no command and edit no file unless a message asks you to. '
                f'Reply with exactly {marker} now. For each later message, do what it says and nothing more.')
        created = cli_result('task', 'create', text, '--title', title, '--workspace', workspace_id, '--start-work',
                             '--branch-prefix', 'check', '--wait', '--timeout', '300')
        reply_on(created, marker)
        record = task(created['taskID'])
        require(record['worktree']['state'] == 'finished', f'{title} did not start in a worktree: {record}')
        return record

    def open_pull_request(record, number, pending=False):
        """Commits in the task's worktree, pushes its branch, and links a pull request."""
        worktree, branch = record['worktree']['path'], record['worktree']['branch']
        (Path(worktree) / f'change-{number}.txt').write_text(f'change {number}\n')
        git('add', '.', cwd=worktree)
        git('commit', '-q', '-m', f'change {number}', cwd=worktree)
        git('push', '-q', 'origin', f'HEAD:refs/heads/{branch}', cwd=worktree)
        head = git('rev-parse', 'HEAD', cwd=worktree)
        state = json.loads(gh_state.read_text())
        state['prs'][str(number)] = dict(number=number, head=head, branch=branch, state='OPEN', pending=pending)
        gh_state.write_text(json.dumps(state))
        action('workspace.set-annotation', workspaceID=record['setup']['taskSpaceWorkspaceID'], key='github-pr',
               text=f'PR #{number}', url=f'https://github.com/{SLUG}/pull/{number}')
        return head

    def gh_pr(number):
        return json.loads(gh_state.read_text())['prs'][str(number)]

    def open_chat():
        """Shows the coordinator chat, which reloads tasks.toml, asks GitHub
        and looks for release tags each time."""
        action('coordinator.chat.show')

    def checking_releases(probe):
        """Opens the chat again on each try, which looks for release tags."""
        def wrapped():
            open_chat()
            return probe()
        return wrapped

    def row(record, part):
        return f'sidebar.needsYou.task.{record["taskID"]}.{part}'

    def task_space_label(record):
        title = next(w['title'] for w in instance.query('workspace.list')['workspaces']
                     if w['workspaceID'] == record['setup']['taskSpaceWorkspaceID'])
        return f'{title}, task space'

    def menu_press(label, item):
        """Right-clicks a sidebar row by its label and picks a menu item."""
        result = run_tool(driver, 'context-menu', pid, '*', label, item)
        step('menu', row=label, pressed=item, items=json.loads(result.stdout))

    try:
        listed = instance.wait_until_ready()
        workspace_id = listed[0]['workspaceID']

        def terminal_in_repository():
            cwds = next(w for w in instance.query('workspace.list')['workspaces'] if w['workspaceID'] == workspace_id)['terminalCwds']
            return str(repository) in [os.path.realpath(cwd) for cwd in cwds]

        wait_for('the first terminal in the repository', terminal_in_repository, interval=1)
        wait_for('the coordinator to run', lambda: instance.query('coordinator.status')['state'] == 'running',
                 timeout=60, interval=1)
        run_tool(helper, 'activate', pid)
        step('booted', workspaceID=workspace_id, provider=provider, version=version)

        # 1. Merge through the agent, from the sidebar's Needs you row.
        a = started_task('Merge check', 'READY-A')
        a_worktree, a_branch = a['worktree']['path'], a['worktree']['branch']
        a_head = open_pull_request(a, 7)
        wait_for('A waits for review', lambda: task(a['taskID'])['stage'].get('attention') == 'review', timeout=120, interval=2)
        open_chat()
        capture('1-review')
        press(row(a, 'primary'))
        capture('1-confirm-merge')
        press(row(a, 'confirmMerge'))
        reply_on(a, 'MERGE-REQUESTED')
        step('agent ran task merge', merge=task(a['taskID'])['merge'])
        wait_for('origin merged A', lambda: gh_pr(7)['state'] == 'MERGED', timeout=120, interval=1)
        require(git('rev-parse', 'main', cwd=origin) == a_head, 'origin main is not the accepted commit')
        merged = wait_for('A cleaned up', lambda: (lambda r: r if (r.get('cleanup') or {}).get('finishedAt') else None)(task(a['taskID'])),
                          timeout=300, interval=2)
        require(merged['stage']['group'] == 'toShip', f'A is not To ship: {merged["stage"]}')
        require(merged['mergeCommit'] == a_head and merged['mergeRequestedAt'], f'A lacks its merge: {merged}')
        open_workspaces = [w['workspaceID'] for w in instance.query('workspace.list')['workspaces']]
        require(a['setup']['taskSpaceWorkspaceID'] not in open_workspaces, 'A\'s task space is still open')
        require(not Path(a_worktree).exists(), 'A\'s worktree is still there')
        require(git('branch', '--list', a_branch) == '', 'A\'s local branch is still there')
        require(git('ls-remote', '--heads', 'origin', a_branch) == '', 'A\'s remote branch is still there')
        step('A merged and cleaned up', cleanup=merged['cleanup'])
        open_chat()
        capture('2-to-ship')

        # 2. Release the project; a pushed tag ships both.
        cli_result('task', 'release', '--workspace', workspace_id)
        release = wait_for('the release task', lambda: next((t for t in cli_result('task', 'list')['tasks']
                                                           if t.get('release')), None), timeout=60, interval=1)
        release = wait_for('the release starts', lambda: (lambda r: r if r['setup']['state'] == 'started' else None)(task(release['taskID'])),
                           timeout=300, interval=2)
        require(release['release']['childTaskIDs'] == [a['taskID']], f'Unexpected release children: {release["release"]}')
        release_worktree = release['worktree']['path']
        require(git('rev-parse', 'HEAD', cwd=release_worktree) == a_head, 'The release worktree is not at origin main')
        require(subprocess.run(['git', '-C', release_worktree, 'symbolic-ref', '-q', 'HEAD']).returncode != 0,
                'The release worktree is on a branch')
        reply_on(release, 'RELEASE-READY')
        step('release started', worktree=release['worktree'])
        git('fetch', '-q', 'origin')
        git('tag', 'v1.0', a_head)
        git('push', '-q', 'origin', 'v1.0')
        shipped = wait_for('A shipped', checking_releases(lambda: (lambda r: r if r.get('releaseTag') else None)(task(a['taskID']))),
                           timeout=120, interval=3)
        require(shipped['releaseTag'] == 'v1.0' and shipped['stage']['group'] == 'done', f'A did not ship: {shipped}')
        released = wait_for('the release cleaned up', checking_releases(lambda: (lambda r: r if (r.get('cleanup') or {}).get('finishedAt') else None)(
            task(release['taskID']))), timeout=300, interval=5)
        require(not Path(release_worktree).exists(), 'The release worktree is still there')
        step('shipped', releaseTag=shipped['releaseTag'], releaseCleanup=released['cleanup'])
        capture('3-done')

        # 3. Archive refuses uncommitted work, then keeps unpushed commits.
        b = started_task('Archive check', 'READY-B')
        b_worktree, b_branch = b['worktree']['path'], b['worktree']['branch']
        (Path(b_worktree) / 'local.txt').write_text('local\n')
        git('add', 'local.txt', cwd=b_worktree)
        git('commit', '-q', '-m', 'local only', cwd=b_worktree)
        (Path(b_worktree) / 'draft.txt').write_text('draft\n')
        code, out, err = run_cli('task', 'archive', b['taskID'])
        require(code != 0 and 'uncommitted' in (out + err), f'Archive did not refuse uncommitted work: {code} {out} {err}')
        cli_result('task', 'archive', b['taskID'], '--discard-changes')
        archived = wait_for('B archived', lambda: (lambda r: r if (r.get('cleanup') or {}).get('finishedAt') else None)(task(b['taskID'])),
                            timeout=120, interval=2)
        require(archived['stage']['group'] == 'archived', f'B is not archived: {archived["stage"]}')
        require(not Path(b_worktree).exists(), 'B\'s worktree is still there')
        require(git('branch', '--list', b_branch) != '', 'B\'s branch with an unpushed commit was deleted')
        step('archived', cleanup=archived['cleanup'])

        # 4. Merge Without Checks waits for a check; Cancel Merge ends it.
        c = started_task('Cancel check', 'READY-C')
        open_pull_request(c, 9, pending=True)
        wait_for('C waits for review', lambda: task(c['taskID'])['stage'].get('attention') == 'review', timeout=120, interval=2)
        open_chat()
        wait_for('C\'s Needs you row', lambda: run_tool(helper, 'exists', pid, row(c, 'primary'), check=False).returncode == 0,
                 timeout=30, interval=0.5)
        menu_press('Cancel check, review', 'Merge Without Checks')
        wait_for('C waits for checks', lambda: task(c['taskID'])['merge'] == 'waitingForChecks', timeout=120, interval=1)
        # The task runs while it waits, so its row leaves Needs you.
        wait_for('C to leave Needs you', lambda: run_tool(helper, 'exists', pid, row(c, 'primary'), check=False).returncode != 0,
                 timeout=20, interval=1)
        capture('4-waiting-for-checks')
        # A cancel is refused in the seconds the waiting merge's script runs,
        # every 30 seconds; press again after a refusal.
        def cancel():
            if task(c['taskID'])['merge'] is not None:
                if run_tool(driver, 'context-menu', pid, '*', task_space_label(c), 'Cancel Merge', check=False).returncode == 0:
                    time.sleep(2)
            record = task(c['taskID'])
            return record if record['merge'] is None and record['mergeCancelledAt'] else None
        cancelled = wait_for('C cancelled', cancel, timeout=90, interval=1)
        step('pressed', menuItem='Cancel Merge')
        require(gh_pr(9)['state'] == 'OPEN', 'C merged after the cancel')
        step('cancelled', stage=cancelled['stage'])
        capture('5-cancelled')

        evidence['status'] = 'passed'
    except Exception as error:  # Always keep the failure evidence.
        evidence['failure'] = repr(error)
        try:
            screens = {}
            for workspace in instance.query('workspace.list')['workspaces']:
                for panel in panel_ids(instance.query('workspace.snapshot', workspaceID=workspace['workspaceID'])):
                    try:
                        screens[panel] = instance.query('terminal.visible-text', panelID=panel, tail=40).get('text', '')[-2000:]
                    except AssertionError:
                        pass
            evidence['screens'] = screens
            evidence['tasks'] = json.loads(run_cli('task', 'list')[1])['result']['tasks']
            (artifacts / f'{PREFIX}-ax.txt').write_text(run_tool(helper, 'dump', pid, check=False).stdout)
            capture('failure')
        except Exception as diagnostics_error:
            evidence['diagnosticsError'] = repr(diagnostics_error)
        raise
    finally:
        log = Path(str(gh_state) + '.log')
        if log.is_file():
            evidence['ghCalls'] = log.read_text().splitlines()
        instance_log = runtime_home / 'logs/toastty.log'
        if instance_log.is_file():
            shutil.copyfile(instance_log, artifacts / f'{PREFIX}-instance.log')
        (artifacts / f'{PREFIX}.json').write_text(json.dumps(evidence, indent=2, sort_keys=True, default=str))
        try:
            instance.kill()
        except Exception:
            pass
        if provider == 'codex':
            start_work_check.forget_codex_trust(parent)
        shutil.rmtree(parent, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps(evidence, indent=2, sort_keys=True, default=str))


if __name__ == '__main__':
    main()

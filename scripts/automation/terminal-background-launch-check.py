#!/usr/bin/env python3
"""Prove background terminal launch delivery in a disposable remote app.

Run with scripts/remote/validate.sh --require-remote --scope working-tree
--validation-command 'python3 scripts/automation/terminal-background-launch-check.py'.
This mutates only the injected isolated app and its run directories. The remote
wrapper owns app shutdown and disposal. A fixture runs through agent.launch's
initialCommands, followed by false, so the provider command never starts.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time
import uuid


TIMEOUT = 30
FIXTURE_SOURCE = '''import hashlib
import json
import os
from pathlib import Path
import sys
import time

output, run_id, scenario, panel = sys.argv[1:]
marker = "TOASTTY_BACKGROUND_EXECUTED_" + hashlib.sha256(
    f"{run_id}:{scenario}:{panel}".encode()).hexdigest()
proof = dict(runID=run_id, scenario=scenario, expectedPanelID=panel,
             processID=os.getpid(), stdinIsTTY=sys.stdin.isatty(),
             stdoutIsTTY=sys.stdout.isatty(), marker=marker,
             columns=os.get_terminal_size(0).columns, rows=os.get_terminal_size(0).lines)
destination = Path(output)
temporary = destination.with_suffix(".tmp")
temporary.write_text(json.dumps(proof) + "\\n")
temporary.replace(destination)
print(marker, flush=True)
# Keep the session alive until the parent checks its target and output.
# A deadline also releases the fixture if validation fails unexpectedly.
deadline = time.monotonic() + 90
while not destination.with_suffix(".release").exists() and time.monotonic() < deadline:
    time.sleep(0.1)
'''


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def identifier(value, label):
    require(isinstance(value, str), f'{label} is missing')
    try:
        uuid.UUID(value)
    except ValueError:
        raise AssertionError(f'{label} is not a UUID') from None
    return value


class FixtureRequestError(AssertionError):
    def __init__(self, arguments, code, message):
        self.code = code
        self.message = message
        super().__init__(f"{arguments[0:3]} failed with {code}: {message}")


class Check:
    def __init__(self, evidence, artifacts):
        self.evidence = evidence
        self.artifacts = artifacts.resolve()
        self.runtime_home = Path(os.environ['TOASTTY_RUNTIME_HOME']).resolve()
        instance_path = Path(os.environ['TOASTTY_INSTANCE_JSON']).resolve()
        require(instance_path == self.runtime_home / 'instance.json',
                'instance.json is outside the injected runtime home')
        instance = json.loads(instance_path.read_text())
        self.socket_path = os.environ['TOASTTY_SOCKET_PATH']
        require(instance['socketPath'] == self.socket_path, 'Socket does not match instance.json')
        require(instance['pid'] == int(os.environ['TOASTTY_PID']) and instance['pid'] > 1,
                'PID does not match instance.json')
        require(Path(instance['runtimeHomePath']).resolve() == self.runtime_home,
                'Runtime home does not match instance.json')
        require(instance['runtimeHomeStrategy'] != 'user-home', 'Production runtime is forbidden')
        label = os.environ['TOASTTY_REMOTE_VALIDATE_RUN_LABEL']
        expected_label = re.sub('[^a-z0-9]+', '-', label.lower()).strip('-')[:80].strip('-') or 'run'
        require(instance['runtimeLabel'] == expected_label, 'Remote run label mismatch')
        require(stat.S_ISSOCK(Path(self.socket_path).stat().st_mode), 'Target is not a Unix socket')
        os.kill(instance['pid'], 0)
        self.evidence['target'] = {key: instance[key] for key in
                                  ('pid', 'runtimeLabel', 'runtimeHomePath', 'socketPath')}
        self.evidence['scope'] = 'Disposable remote validation app; fixture and UI state mutations only'
        source = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], capture_output=True,
                                text=True, timeout=10, check=True)
        # The wrapper overlays the local working tree on this remote checkout.
        self.evidence['remoteCheckoutBaseCommit'] = source.stdout.strip()

        bundle = Path(os.environ['TOASTTY_APP_BUNDLE']).resolve()
        derived = Path(os.environ['TOASTTY_DERIVED_PATH']).resolve()
        require(bundle == derived / 'Build/Products/Debug/Toastty.app',
                'App bundle does not belong to the injected build')
        require(Path(instance['bundlePath']).resolve() == bundle,
                'Running app bundle does not match the injected build')
        require(Path(instance['derivedPath']).resolve() == derived,
                'Running app DerivedData does not match the injected build')
        candidates = (bundle / 'Contents/Helpers/toastty', bundle / 'Contents/MacOS/toastty',
                      bundle.parent / 'toastty')
        self.cli = next((path for path in candidates if path.is_file() and os.access(path, os.X_OK)), None)
        require(self.cli is not None, 'Injected validation build has no Toastty CLI')
        self.evidence['cliPath'] = str(self.cli)
        self.environment = dict(os.environ)
        # The remote app owns no session from the terminal running this check.
        for key in ('TOASTTY_SESSION_ID', 'TOASTTY_PANEL_ID'):
            self.environment.pop(key, None)
        self.run_id = uuid.uuid4().hex
        self.evidence['runID'] = self.run_id
        self.fixture_root = self.runtime_home / f'terminal-background-check-{self.run_id}'
        self.fixture_root.mkdir()
        self.fixture = self.fixture_root / 'fixture.py'
        self.fixture.write_text(FIXTURE_SOURCE)
        self.sessions = []
        self.fixture_releases = []
        self.baseline = None
        self.guarded_workspaces = {}

    def run(self, arguments, caller=None, expect_error=False):
        environment = dict(self.environment)
        if caller is not None:
            environment['TOASTTY_SESSION_ID'], environment['TOASTTY_PANEL_ID'] = caller
        recorded = [arg if not arg.startswith('initialCommands=')
                    else 'initialCommands=<fixture or false>' for arg in arguments]
        entry = {'arguments': recorded, 'callerSessionID': caller[0] if caller else None}
        self.evidence['commands'].append(entry)
        try:
            completed = subprocess.run(
                [str(self.cli), '--json', '--socket-path', self.socket_path, *arguments],
                capture_output=True, text=True, timeout=60, env=environment)
        except subprocess.TimeoutExpired:
            raise AssertionError(f'{arguments[0]} CLI command timed out') from None
        try:
            response = json.loads(completed.stdout)
        except json.JSONDecodeError:
            raise AssertionError(f'{arguments[0]} CLI did not return JSON (exit {completed.returncode})') from None
        entry['exitCode'] = completed.returncode
        entry['ok'] = response.get('ok')
        if expect_error:
            require(completed.returncode != 0 and response.get('ok') is False,
                    'Mismatched explicit targets unexpectedly succeeded')
            entry['errorCode'] = (response.get('error') or {}).get('code')
            require(entry['errorCode'] == 'INVALID_PAYLOAD', 'Mismatch did not fail with INVALID_PAYLOAD')
            return response['error']
        if completed.returncode != 0 or response.get('ok') is not True:
            error = response.get('error') or {}
            # Failed fixture requests contain only our target IDs and fixed
            # profile/options. Never record successful launch command payloads.
            entry['errorCode'] = error.get('code', 'unknown error')
            entry['errorMessage'] = error.get('message', '')
            raise FixtureRequestError(arguments, entry["errorCode"], entry["errorMessage"])
        # agent.launch returns a composed command with environment values. Keep
        # that response in memory only; never put it in the evidence or logs.
        return response.get('result')

    def action(self, action_id, *arguments, caller=None, expect_error=False):
        return self.run(['action', 'run', action_id, *arguments], caller, expect_error)

    def query(self, query_id, *arguments):
        return self.run(['query', 'run', query_id, *arguments])

    def snapshot(self, workspace=None):
        return self.query('workspace.snapshot', *(['--workspace', workspace] if workspace else []))

    @staticmethod
    def focus(snapshot):
        right = snapshot['rightPanel']
        return {'workspaceID': snapshot['workspaceID'], 'selectedTabID': snapshot['selectedTabID'],
                'focusedPanelID': snapshot['focusedPanelID'],
                'rightPanel': {key: right[key] for key in
                               ('isVisible', 'activeTabID', 'activePanelID', 'focusedPanelID')}}

    def guard(self, *workspaces):
        self.baseline = self.focus(self.snapshot())
        self.guarded_workspaces = {workspace: self.focus(self.snapshot(workspace))
                                   for workspace in sorted(set(workspaces))}
        self.evidence['selectionChecks'].append({'before': self.baseline,
                                                 'workspaceFocusBefore': self.guarded_workspaces})

    def unchanged(self):
        current = self.focus(self.snapshot())
        local = {workspace: self.focus(self.snapshot(workspace)) for workspace in self.guarded_workspaces}
        self.evidence['selectionChecks'][-1].update(after=current, workspaceFocusAfter=local)
        require(current == self.baseline, 'Selected workspace/tab/panel/right-panel focus changed')
        require(local == self.guarded_workspaces, 'Target workspace tab/panel/right-panel focus changed')

    def workspace(self, title):
        return identifier(self.action('workspace.create', f'title={title}', 'activate=false')['workspaceID'],
                          'Created workspaceID')

    def created(self, result, workspace):
        for key in ('workspaceID', 'tabID', 'panelID'):
            identifier(result.get(key), f'Created {key}')
        require(result['workspaceID'] == workspace, 'Creation used a different workspace')
        return {key: result[key] for key in ('workspaceID', 'tabID', 'panelID')}

    def right_panel_focus(self, workspace):
        before = self.snapshot(workspace)['rightPanel']['panelIDs']
        self.action('panel.create.browser', '--workspace', workspace,
                    'placement=rightPanel', 'url=about:blank')
        added = set(self.snapshot(workspace)['rightPanel']['panelIDs']) - set(before)
        require(len(added) == 1, 'Fixture did not create one right-panel browser')
        panel = added.pop()
        self.action('workspace.focus-panel', '--workspace', workspace, '--panel', panel)
        require(self.snapshot(workspace)['rightPanel']['focusedPanelID'] == panel,
                'Fixture did not focus the right panel')

    def choose_profile(self):
        # Non-Codex profiles avoid Codex's interactive status-hook preflight.
        # An absent executable is safe: false prevents provider execution.
        states = []
        for profile in ('pi', 'opencode', 'mimocode', 'cursor', 'claude'):
            state = self.query('agent.profile.state', f'profileID={profile}')
            states.append({key: state[key] for key in ('profileID', 'source', 'resolved', 'argumentCount')})
            if state['source'] == 'implicit':
                self.evidence['profileSelection'] = states
                return profile
        self.evidence['profileSelection'] = states
        return 'pi'

    def registered(self, target, session):
        workspaces = self.query('workspace.list')['workspaces']
        matches = [(workspace['workspaceID'], record['panelID'])
                   for workspace in workspaces for record in workspace['activeSessions']
                   if record['sessionID'] == session]
        require(matches == [(target['workspaceID'], target['panelID'])],
                'Launch session registry does not match the returned target')

    def launch(self, scenario, target, profile, caller=None, keep_alive=False):
        proof_path = self.artifacts / f'terminal-background-{self.run_id}-{scenario}.json'
        release_path = proof_path.with_suffix('.release')
        self.fixture_releases.append(release_path)
        command = shlex.join([sys.executable, str(self.fixture), str(proof_path), self.run_id,
                              scenario, target['panelID']])
        started = time.monotonic()
        # A fresh shell can report busy between surface creation and its first
        # prompt. Preserve the initial error and retry only this same target;
        # the app must never need selection or focus to become ready.
        attempts = 0
        deadline = time.monotonic() + TIMEOUT
        while True:
            attempts += 1
            try:
                result = self.action('agent.launch', '--workspace', target['workspaceID'],
                                     '--tab', target['tabID'], '--panel', target['panelID'],
                                     f'profileID={profile}', f'cwd={self.fixture_root}',
                                     f'initialCommands={command}', 'initialCommands=false', caller=caller)
                break
            except FixtureRequestError as error:
                if (error.code != 'INVALID_PAYLOAD'
                        or error.message != 'The target terminal is not at an interactive prompt.'
                        or time.monotonic() >= deadline):
                    raise
                self.unchanged()
                time.sleep(0.1)
        session = result.get('sessionID')
        require(isinstance(session, str) and session, 'Launch did not return sessionID')
        self.sessions.append((session, target['panelID']))
        require(result['workspaceID'] == target['workspaceID'] and result['panelID'] == target['panelID'],
                'Launch returned a different target')
        require(result.get('tabID') == target['tabID'], 'Launch tabID is missing or does not match the target')
        self.unchanged()
        self.registered(target, session)
        marker = 'TOASTTY_BACKGROUND_EXECUTED_' + hashlib.sha256(
            f'{self.run_id}:{scenario}:{target["panelID"]}'.encode()).hexdigest()
        deadline = time.monotonic() + TIMEOUT
        while not proof_path.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        require(proof_path.exists(), f'{scenario}: fresh background shell did not execute the fixture')
        proof = json.loads(proof_path.read_text())
        require(proof['runID'] == self.run_id and proof['scenario'] == scenario
                and proof['expectedPanelID'] == target['panelID'] and proof['marker'] == marker,
                'Fixture proof does not match this launch')
        require(proof['stdinIsTTY'] and proof['stdoutIsTTY'], 'Fixture did not execute in a terminal PTY')
        require(proof['columns'] > 0 and proof['rows'] > 0, 'Background PTY has no usable dimensions')
        while time.monotonic() < deadline:
            output = self.query('terminal.visible-text', '--workspace', target['workspaceID'],
                                '--panel', target['panelID'], 'includeScrollback=true', 'tail=40',
                                f'contains={marker}')
            if output.get('contains') is True:
                break
            time.sleep(0.1)
        else:
            raise AssertionError(f'{scenario}: fixture file exists but terminal output proof is missing')
        require(output['panelID'] == target['panelID'] and output['workspaceID'] == target['workspaceID'],
                'Terminal output came from a different target')
        self.unchanged()
        self.evidence['checks'].append({'scenario': scenario, **target, 'sessionID': session,
                                        'proofPath': str(proof_path), 'terminalOutputConfirmed': True,
                                        'stdinIsTTY': True, 'stdoutIsTTY': True, 'launchAttempts': attempts,
                                        'columns': proof['columns'], 'rows': proof['rows'],
                                        'secondsToProof': round(time.monotonic() - started, 3)})
        if not keep_alive:
            self.run(['session', 'stop', '--session', session, '--panel', target['panelID'],
                      '--reason', 'Background launch validation complete'])
            self.sessions.remove((session, target['panelID']))
            release_path.touch()
        return session

    def cleanup(self):
        for session, panel in self.sessions[:]:
            try:
                self.run(['session', 'stop', '--session', session, '--panel', panel,
                          '--reason', 'Background launch validation cleanup'])
                self.sessions.remove((session, panel))
            except Exception as error:
                self.evidence.setdefault('cleanupErrors', []).append(type(error).__name__)
        for release_path in self.fixture_releases:
            release_path.touch()


def main():
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    artifacts.mkdir(parents=True, exist_ok=True)
    evidence = {'status': 'running', 'checks': [], 'commands': [], 'selectionChecks': [],
                'limitations': [
                    'initialCommands runs before the managed provider environment. Proof records the '
                    'expected panel; the returned target and session registry are checked separately.',
                    'false stops the shell before provider startup. This checks managed launch preparation '
                    'and command execution in a fresh Ghostty terminal; it does not check provider startup.',
                    'The normal app socket exposes no first-responder snapshot. Selection and stored '
                    'layout/right-panel focus are checked; actual AppKit keyboard focus is not observed.',
                    'Setup navigation changes selection only in the disposable remote app. The remote '
                    'wrapper owns workspace, fixture-file, and app cleanup.'
                ]}
    check = None
    try:
        check = Check(evidence, artifacts)
        evidence['selectionAtStart'] = check.focus(check.snapshot())
        selected = check.snapshot()
        workspace = selected['workspaceID']
        original_panel = identifier(selected['focusedPanelID'], 'Original focusedPanelID')
        profile = check.choose_profile()
        check.right_panel_focus(workspace)

        # No navigation to this workspace occurs before creation or launch.
        check.guard(workspace)
        hidden = check.workspace('Never selected background terminal validation')
        check.unchanged()
        hidden_snapshot = check.snapshot(hidden)
        check.guard(workspace, hidden)
        split = check.created(check.action('workspace.split.right', '--workspace', hidden,
                                           '--tab', hidden_snapshot['selectedTabID'],
                                           '--panel', hidden_snapshot['focusedPanelID'],
                                           'activate=false'), hidden)
        # Attempt launch immediately; record readiness rejections before retrying.
        check.launch('never-selected-workspace-split', split, profile)

        check.guard(workspace, hidden)
        tab = check.created(check.action('workspace.tab.create', '--workspace', workspace,
                                         'activate=false'), workspace)
        caller_session = check.launch('new-unselected-tab', tab, profile, keep_alive=True)

        # Keep the launched caller in the unselected tab, then move the user to a
        # different workspace. Omitted selectors must still use that caller tab.
        elsewhere = check.workspace('User selected background terminal validation')
        check.action('workspace.select', '--workspace', elsewhere)
        check.right_panel_focus(elsewhere)
        require(check.snapshot(workspace)['selectedTabID'] != tab['tabID'],
                'Managed caller fixture tab is unexpectedly selected')
        check.guard(workspace, hidden, elsewhere)
        caller = (caller_session, tab['panelID'])
        managed_split = check.created(check.action('workspace.split.right', 'activate=false',
                                                   caller=caller), workspace)
        require(managed_split['tabID'] == tab['tabID'], 'Default split did not use the managed caller tab')
        check.launch('managed-caller-after-user-switch', managed_split, profile, caller)

        # Focus mode must not prevent a new sibling outside its visible root
        # from mounting. This workspace also remains unselected for the check.
        focused_workspace = check.workspace('Focus-mode background terminal validation')
        check.action('panel.focus-mode.toggle', '--workspace', focused_workspace)
        focused_snapshot = check.snapshot(focused_workspace)
        check.guard(workspace, hidden, elsewhere, focused_workspace)
        focused_split = check.created(check.action(
            'workspace.split.right', '--workspace', focused_workspace,
            '--tab', focused_snapshot['selectedTabID'],
            '--panel', focused_snapshot['focusedPanelID'], 'activate=false'
        ), focused_workspace)
        check.launch('focus-mode-hidden-split', focused_split, profile)

        # The tab and panel exist in one workspace, but they do not match.
        # Rejection must happen before launch preparation or provider delivery.
        check.action('agent.launch', '--workspace', workspace, '--tab', tab['tabID'],
                     '--panel', original_panel, f'profileID={profile}', 'initialCommands=false',
                     expect_error=True)
        check.unchanged()
        evidence['checks'].append({'scenario': 'mismatched-tab-and-panel', 'rejected': True,
                                   'errorCode': 'INVALID_PAYLOAD'})
        evidence['selectionAtEnd'] = check.focus(check.snapshot())
        evidence['status'] = 'pass'
    except Exception as error:
        evidence['status'] = 'fail'
        evidence['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        if check is not None:
            check.cleanup()
        output = artifacts / 'terminal-background-launch.json'
        output.write_text(json.dumps(evidence, indent=2) + '\n')
        print(json.dumps({'status': evidence['status'], 'evidence': str(output),
                          'scenarios': [entry['scenario'] for entry in evidence['checks']]}))


if __name__ == '__main__':
    main()

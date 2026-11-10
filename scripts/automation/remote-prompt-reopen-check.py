#!/usr/bin/env python3
"""Open the coordinator's prompt again after a failed turn or a lost send.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-prompt-reopen-check.py --scenario <name>'.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home. It never moves focus to another app, and it does
not touch the installed production app.

'--scenario failed-turn --gui-session' runs the real Claude CLI as the
coordinator. A stub on a loopback port stands in for the model API and
answers every request with an overloaded error, so each turn ends with an API
error and Claude Code fires its StopFailure hook in place of Stop. Claude
gets a placeholder token for the stub, so the login token is not sent to it.
The stub reads each request only to discard it: it never keeps a header or a
body. It keeps the method, the path, and which kind of credential the request
carried (the placeholder, none, or another one), and the check fails if any
request carried another one. The check
proves from Claude's transcript that the turn failed, and then that the next
wake digest is typed.

'--scenario lost-send' runs a script that stands in for Claude Code and
reports its turns as Claude's hooks do. It can leave one Return unanswered:
the text stays in its composer and no turn starts. It can also start a turn
late. The check proves that the next message is typed after the time limit,
that a message taken late is typed once, and that each message starts one
turn.

'--expect stuck' records the fault instead: the next message stays queued.
Use it against a build without the repair.

Evidence goes to remote-prompt-reopen-check-<scenario>.json, the app log and,
for the real CLI, Claude's transcripts in the artifacts directory.
"""

import argparse
from datetime import datetime, timezone
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coordinator_check = load('coordinator_check', 'remote-coordinator-check.py')
require, wait_for, Instance = coordinator_check.require, coordinator_check.wait_for, coordinator_check.Instance

# How long Toastty waits for a typed message to start a turn.
LOST_SEND_LIMIT = 10
# What Claude sends to the stub in place of the login token.
PLACEHOLDER_TOKEN = 'toastty-stub-placeholder'
LOG_LINES = (
    'Remote input availability changed',
    'Typed a message into the coordinator',
    'Local conversation send evaluated',
    'Remote send was not confirmed',
    'Opened the prompt again',
)

# Reads one message for each line, or for each bracketed paste, and reports
# its turns as Claude's UserPromptSubmit and Stop hooks do. A turn lasts a
# second. With the file `drop-next-return`, the next Return submits nothing:
# the text stays in the composer and goes out with the next message. With
# `take-late`, the next turn starts after that many seconds.
FAKE_AGENT = r'''#!__PYTHON__
import json, os, subprocess, sys, time, uuid
from datetime import datetime, timezone

arguments = sys.argv[1:]
if arguments[:1] == ['--version']:
    print('2.1.288 (Claude Code)')
    sys.exit(0)
if arguments[:1] and arguments[0] in ('plugin', 'mcp', 'config'):
    sys.exit(0)
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent')
os.makedirs(here, exist_ok=True)
session, panel, cli = (os.environ[name] for name in ('TOASTTY_SESSION_ID', 'TOASTTY_PANEL_ID', 'TOASTTY_CLI_PATH'))
native = str(uuid.uuid4())
transcript = os.path.join(here, native + '.jsonl')
open(transcript, 'a').close()


def record(event, **facts):
    with open(os.path.join(here, 'events.jsonl'), 'a') as log:
        log.write(json.dumps(dict(event=event, session=session, at=time.time(), **facts)) + '\n')


def hook(name, **fields):
    subprocess.run(
        [cli, 'session', 'ingest-agent-event', '--source', 'claude-hooks', '--session', session, '--panel', panel],
        input=json.dumps(dict(hook_event_name=name, session_id=native, transcript_path=transcript, cwd=os.getcwd(), **fields)),
        text=True, capture_output=True)


def write(role, content, **fields):
    now = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    with open(transcript, 'a') as log:
        log.write(json.dumps(dict(type=role, uuid=str(uuid.uuid4()), timestamp=now, sessionId=native,
                                  message=dict(role=role, content=content, **fields))) + '\n')


def control(name):
    path = os.path.join(here, name)
    if not os.path.exists(path):
        return None
    value = open(path).read().strip()
    os.remove(path)
    return value or '1'


record('started', panel=panel, cwd=os.getcwd(), native=native)
hook('SessionStart')
subprocess.run([cli, 'session', 'status', '--session', session, '--kind', 'idle', '--summary', 'Waiting'], capture_output=True)
sys.stdout.write('\033[?2004h')
sys.stdout.flush()


def turn(message):
    late = control('take-late')
    if late:
        record('taking late', text=message, seconds=float(late))
        time.sleep(float(late))
    hook('UserPromptSubmit', prompt=message)
    write('user', message)
    record('message', text=message)
    time.sleep(1)
    write('assistant', [dict(type='text', text='Done.')], stop_reason='end_turn')
    hook('Stop', stop_hook_active=False, last_assistant_message='Done.')
    record('turn ended', text=message)


START, END = '\033[200~', '\033[201~'
lines, pasting, composer = [], False, ''
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
    if control('drop-next-return'):
        composer += message
        record('return dropped', text=message)
        continue
    message, composer = composer + message, ''
    if message.strip() == '/exit':
        break
    turn(message)
'''


class StubAPI:
    """Answers every model request with an overloaded error.

    A request's headers and body carry the caller's login. This server reads
    them only to take them off the socket. It keeps the method, the path,
    and which kind of credential the request carried: the placeholder token,
    none, or another one. It never keeps the credential.
    """

    def __init__(self):
        requests = self.requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *arguments):
                pass

            def answer(self):
                remaining = int(self.headers.get('Content-Length') or 0)
                while remaining > 0:
                    discarded = self.rfile.read(min(remaining, 65536))
                    if not discarded:
                        break
                    remaining -= len(discarded)
                path = urllib.parse.urlsplit(self.path).path
                authorization, api_key = self.headers.get('Authorization'), self.headers.get('x-api-key')
                if authorization is None and api_key is None:
                    credential = 'none'
                elif authorization == f'Bearer {PLACEHOLDER_TOKEN}' and api_key is None:
                    credential = 'placeholder'
                else:
                    credential = 'other'
                requests.append(dict(method=self.command, path=path, at=time.time(), credential=credential))
                if self.command == 'POST' and path.startswith('/v1/messages'):
                    status, kind, message = 529, 'overloaded_error', 'Overloaded'
                else:
                    status, kind, message = 404, 'not_found_error', 'Not found'
                body = json.dumps(dict(type='error', error=dict(type=kind, message=message))).encode()
                self.close_connection = True
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                if self.command != 'HEAD':
                    self.wfile.write(body)

            do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = answer

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def model_requests(self):
        return [request for request in self.requests if request['path'].startswith('/v1/messages')]

    def stop(self):
        self.server.shutdown()


class ReopenCheck(coordinator_check.Check):
    def __init__(self, scenario):
        super().__init__('claude' if scenario == 'failed-turn' else 'fake')
        self.prefix = f'remote-prompt-reopen-check-{scenario}'

    def keep_log_lines(self, runtime_home):
        log = runtime_home / 'logs/toastty.log'
        lines = log.read_text(errors='replace').splitlines() if log.is_file() else []
        self.evidence['appLog'] = [line for line in lines if any(text in line for text in LOG_LINES)]


# MARK: - A failed turn of the real Claude CLI


def run_failed_turn(check, expect):
    steer = load('queue_steer_check', 'remote-queue-steer-check.py')
    host_environment = {key: value for key, value in os.environ.items()
                        if not key.startswith('TOASTTY_')
                        and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT')}
    claude = shutil.which('claude') or str(Path.home() / '.local/bin/claude')
    require(Path(claude).is_file(), 'Claude CLI is not installed on the remote host')
    version = subprocess.check_output([claude, '--version'], text=True, timeout=30, env=host_environment).strip()
    check.evidence['cliVersion'] = version

    stub = StubAPI()
    # Only this run's agent sees these values. The placeholder token keeps
    # the login token away from the stub, and one try keeps the failure fast.
    settings = dict(env=dict(ANTHROPIC_BASE_URL=stub.url, ANTHROPIC_AUTH_TOKEN=PLACEHOLDER_TOKEN,
                             CLAUDE_CODE_MAX_RETRIES='0', DISABLE_TELEMETRY='1', DISABLE_ERROR_REPORTING='1'))
    argv = [claude, '--setting-sources=', '--tools', 'Bash', '--strict-mcp-config', '--settings', json.dumps(settings)]
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
        return '\n'.join(part.get('text') or '' for part in content or [] if isinstance(part, dict))

    def user_messages():
        return [text_of(record) for record in transcript_records()
                if record.get('type') == 'user' and not record.get('isMeta') and text_of(record).strip()]

    def api_errors():
        return [dict(text=text_of(record)[:300], error=record.get('error'), at=record.get('timestamp'))
                for record in transcript_records() if record.get('isApiErrorMessage')]

    def digests():
        return [text for text in user_messages() if text.lstrip().startswith('[Toastty] Wake')]

    try:
        instance.wait_until_ready()
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        wait_for('Claude at its prompt',
                 lambda: (s := status()).get('status') in ('idle', 'ready') and s.get('agentState') == 'running' and s,
                 timeout=120, interval=1)
        time.sleep(3)
        step('open started Claude', opened=opened, version=version, stub=stub.url)

        # 1. A real turn that the API fails.
        answer = cli('coordinator', 'send', 'Say OK.')
        require(answer['delivery'] == 'sent', f'The first message was not typed: {answer} {status()}')
        failed = wait_for('the turn to fail with an API error', lambda: api_errors() or None, timeout=600, interval=2)
        time.sleep(5)
        after_failure = status()
        require(all(request['credential'] == 'placeholder' for request in stub.model_requests())
                and all(request['credential'] != 'other' for request in stub.requests),
                'A request to the stub carried a credential other than the placeholder token')
        step('the API failed the turn', apiErrors=failed, modelRequests=len(stub.model_requests()),
             userMessages=user_messages(), status=after_failure)

        # 2. The next wake digest.
        timer = cli('coordinator', 'wake', '--in', '60s')['wake']
        due = datetime.fromisoformat(timer['nextWakeAt'].replace('Z', '+00:00')).timestamp()
        if expect == 'stuck':
            require(after_failure.get('status') == 'working', f'The failed turn is not shown as working: {after_failure}')
            time.sleep(max(0, due - time.time()) + 45)
            held = status()
            require(not digests(), f'The digest was typed: {digests()}')
            # Claude's idle reminder returns the status to ready after a
            # minute. The conversation still shows a running turn.
            require(held['wake']['nextWakeSource'] == 'coordinator' and held['wake']['nextWakeAt'] == timer['nextWakeAt'],
                    f'The timer is not waiting: {held}')
            step('the digest is held, 45 seconds after its time', status=held, timer=timer, userMessages=user_messages())
            return
        require(after_failure.get('status') == 'error', f'The failed turn is not shown as an error: {after_failure}')
        typed = wait_for('the digest to reach Claude', lambda: digests() or None,
                         timeout=max(0, due - time.time()) + 40, interval=1)
        arrived = time.time()
        require(arrived <= due + 40, f'The digest came late: due {due}, arrived {arrived}')
        # That turn fails too, and the prompt opens once more.
        wait_for('the second turn to fail', lambda: len(api_errors()) >= 2, timeout=600, interval=2)
        time.sleep(5)
        after_digest = status()
        require(after_digest.get('status') == 'error' and after_digest['wake']['nextWakeSource'] != 'coordinator',
                f'Unexpected status after the digest: {after_digest}')
        again = cli('coordinator', 'send', 'Say OK again.')
        require(again['delivery'] == 'sent', f'A message after the second failure was not typed: {again} {status()}')
        wait_for('the third turn to fail', lambda: len(api_errors()) >= 3, timeout=600, interval=2)
        step('the digest and a later message were typed', digest=typed[0], secondsAfterDue=round(arrived - due, 1),
             status=after_digest, apiErrors=api_errors(), userMessages=user_messages(),
             modelRequests=len(stub.model_requests()))

        # 3. Claude reminds an idle prompt after a minute. The failure stays.
        time.sleep(80)
        reminded = status()
        require(reminded.get('status') == 'error', f"Claude's idle reminder hid the failure: {reminded}")
        step('the failure is still shown after a minute at the prompt', status=reminded)
    finally:
        check.evidence['stubRequests'] = stub.requests[:200]
        try:
            instance.kill()
        except Exception:
            pass
        stub.stop()
        check.keep_log_lines(runtime_home)
        check.copy_instance_log(runtime_home, 'claude')
        steer.set_directory_trust(directory, False)
        if project.is_dir():
            capture = check.artifacts / f'{check.prefix}-transcripts'
            capture.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, capture / path.name)
            # Only the project for this run's unique temporary folder.
            shutil.rmtree(project, ignore_errors=True)


# MARK: - A lost send to a fake agent


def run_lost_send(check, expect):
    fake_bin = check.root / 'bin'
    fake_bin.mkdir()
    agent = fake_bin / 'claude'
    agent.write_text(FAKE_AGENT.replace('__PYTHON__', sys.executable))
    agent.chmod(0o755)
    records = fake_bin / 'agent'
    records.mkdir()
    runtime_home, user_home = check.home('main', [str(agent)])
    environment = check.environment('main', runtime_home, user_home)
    _, cli = check.cli_runner(environment)
    app_log = check.artifacts / f'{check.prefix}-app.log'
    instance = Instance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log)
    step = check.step

    def events(kind=None):
        log = records / 'events.jsonl'
        found = [json.loads(line) for line in log.read_text().splitlines()] if log.is_file() else []
        return [event for event in found if kind is None or event['event'] == kind]

    def turns_with(text):
        return [event for event in events('message') if text in event['text']]

    def status():
        return cli('coordinator', 'status')

    def at_prompt():
        current = status()
        return (current.get('status') in ('idle', 'ready') and current.get('agentState') == 'running'
                and current.get('queuedCount') == 0 and current)

    def send(text, delivery):
        answer = cli('coordinator', 'send', text)
        require(answer['delivery'] == delivery, f'{text!r} was not {delivery}: {answer} {status()}')
        return answer

    try:
        instance.wait_until_ready()
        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start the agent: {opened}')
        wait_for('the agent at its prompt', at_prompt)
        time.sleep(1.5)
        send('first message', 'sent')
        wait_for('the first turn to end', lambda: any('first message' in e['text'] for e in events('turn ended')))
        wait_for('the agent at its prompt', at_prompt)
        time.sleep(1.5)
        step('a normal message ran its turn', opened=opened, status=status())

        # 1. The agent leaves one Return unanswered.
        (records / 'drop-next-return').write_text('1')
        lost_at = time.time()
        send('lost message', 'sent')
        wait_for('the agent to leave the Return unanswered', lambda: events('return dropped'))
        queued = send('following message', 'queued')
        if expect == 'stuck':
            time.sleep(45)
            held = status()
            require(not turns_with('following message'), f'The next message was typed: {events("message")}')
            require(held.get('queuedCount') == 1 and held.get('hold') == 'busy', f'Unexpected status: {held}')
            step('the next message is held, 45 seconds after the lost one', answer=queued, status=held,
                 agentEvents=events())
            return
        arrival = wait_for('the next message to reach the agent',
                           lambda: (found := turns_with('following message')) and found[0], timeout=40)
        seconds = arrival['at'] - lost_at
        require(LOST_SEND_LIMIT - 1 <= seconds <= LOST_SEND_LIMIT + 6,
                f'The next message came {seconds:.1f} s after the lost one, not about {LOST_SEND_LIMIT} s')
        wait_for('the agent at its prompt', at_prompt)
        time.sleep(1.5)
        send('a later message', 'sent')
        wait_for('that turn to end', lambda: any('a later message' in e['text'] for e in events('turn ended')))
        texts = [event['text'] for event in events('message')]
        require(all(sum(text.count(sent) for text in texts) == 1
                    for sent in ('lost message', 'following message', 'a later message')),
                f'A message was typed twice or not at all: {texts}')
        step('the next message was typed after the time limit', secondsAfterLostSend=round(seconds, 1),
             answer=queued, received=texts, status=status())

        # 2. The agent takes a message after the time limit.
        wait_for('the agent at its prompt', at_prompt)
        time.sleep(1.5)
        before = len(events('message'))
        (records / 'take-late').write_text(str(LOST_SEND_LIMIT + 5))
        send('slow message', 'sent')
        wait_for('the agent to hold the slow message', lambda: events('taking late'))
        send('behind the slow message', 'queued')
        wait_for('both turns to end',
                 lambda: any('behind the slow message' in e['text'] for e in events('turn ended')), timeout=60)
        wait_for('the agent at its prompt', at_prompt)
        time.sleep(LOST_SEND_LIMIT + 3)
        late = [event['text'] for event in events('message')[before:]]
        require(len(late) == 2 and late[0].endswith('slow message') and 'behind' not in late[0]
                and late[1].endswith('behind the slow message') and late[1].count('slow message') == 1,
                f'A message taken late was typed twice, or two messages were mixed: {late}')
        send('last message', 'sent')
        wait_for('the last turn to end', lambda: any('last message' in e['text'] for e in events('turn ended')))
        step('a message taken late was typed once', received=late, status=status())
        check.evidence['agentEvents'] = events()
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        check.keep_log_lines(runtime_home)
        check.copy_instance_log(runtime_home, 'main')
        events_log = records / 'events.jsonl'
        if events_log.is_file():
            shutil.copyfile(events_log, check.artifacts / f'{check.prefix}-agent-events.jsonl')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--scenario', choices=('failed-turn', 'lost-send'), required=True)
    parser.add_argument('--expect', choices=('open', 'stuck'), default='open',
                        help="'stuck' records the fault on a build without the repair")
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, as the checks with the real Claude CLI do')
    options = parser.parse_args()
    if options.gui_session:
        steer = load('queue_steer_check', 'remote-queue-steer-check.py')
        steer.run_in_gui_session(f'remote-prompt-reopen-check-{options.scenario}', __file__,
                                 ['--scenario', options.scenario, '--expect', options.expect])
    check = ReopenCheck(options.scenario)
    check.evidence.update(startedAt=datetime.now(timezone.utc).isoformat(), scenario=options.scenario, expect=options.expect)
    try:
        (run_failed_turn if options.scenario == 'failed-turn' else run_lost_send)(check, options.expect)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[prompt-reopen-check] passed ({options.scenario}, expect {options.expect})', flush=True)


if __name__ == '__main__':
    main()

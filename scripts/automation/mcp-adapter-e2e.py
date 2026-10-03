#!/usr/bin/env python3
"""Exercise actual MCP stdio -> Unix socket -> disposable Toastty -> fake Claude PTY.

Run with scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/mcp-adapter-e2e.py'. No pairing or network listener is used.
"""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time
import uuid


TIMEOUT = 35
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time, uuid
if len(sys.argv) > 1 and sys.argv[1] == '--version':
    print('2.1.288 (Claude Code)')
    sys.exit(0)
if len(sys.argv) > 1 and sys.argv[1] in ('plugin', 'mcp', 'config'):
    sys.exit(0)
root = pathlib.Path(__file__).parent
(root / 'argv.json').write_text(json.dumps(sys.argv[1:]))
transcript = root / 'conversation.jsonl'
native_id = 'fixture-native-session'
cli = os.environ['TOASTTY_CLI_PATH']
def hook(name, **fields):
    payload = dict(hook_event_name=name, session_id=native_id, **fields)
    subprocess.run([cli, 'session', 'ingest-agent-event', '--source', 'claude-hooks'],
                   input=json.dumps(payload), text=True, capture_output=True, timeout=8)
def append(kind, text, index):
    event = {'type': kind, 'sessionId': native_id, 'uuid': str(uuid.uuid4()),
             'timestamp': '2026-10-03T12:00:%02d.000Z' % (index % 60),
             'message': {'role': kind, 'content': ([{'type': 'text', 'text': text}]
                                             if kind == 'assistant' else text)}}
    if kind == 'assistant': event['message']['model'] = 'fixture-model'
    with transcript.open('a') as out: out.write(json.dumps(event) + '\n')
hook('SessionStart', transcript_path=str(transcript), cwd=str(root))
append('user', sys.argv[-1], 0)
append('assistant', 'Fixture ready for MCP', 1)
hook('Stop', last_assistant_message='Fixture ready for MCP')
for index, line in enumerate(sys.stdin, start=2):
    message = line.strip()
    if not message: continue
    hook('UserPromptSubmit', prompt=message, turn_id=str(index))
    append('user', message, index * 2)
    append('assistant', 'Fixture received: ' + message, index * 2 + 1)
    hook('Stop', last_assistant_message='Fixture received: ' + message)
'''


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def wait_for(label, probe):
    deadline = time.monotonic() + TIMEOUT
    last = None
    while time.monotonic() < deadline:
        last = probe()
        if last:
            return last
        time.sleep(0.25)
    raise AssertionError(f'timed out waiting for {label}; last={last!r}')


class MCP:
    def __init__(self, script, socket_path):
        self.process = subprocess.Popen(['node', str(script)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, bufsize=1,
                                        env=dict(os.environ, TOASTTY_SOCKET_PATH=socket_path))
        self.serial = 0

    def request(self, method, params=None):
        self.serial += 1
        self.process.stdin.write(json.dumps(dict(jsonrpc='2.0', id=self.serial,
                                                 method=method, params=params or {})) + '\n')
        self.process.stdin.flush()
        ready, _, _ = select.select([self.process.stdout], [], [], TIMEOUT)
        require(ready, f'MCP {method} timed out')
        response = json.loads(self.process.stdout.readline())
        require(response['id'] == self.serial, f'MCP response ID mismatch: {response}')
        require('error' not in response, f'MCP protocol error: {response}')
        return response['result']

    def tool(self, name, **arguments):
        result = self.request('tools/call', dict(name=name, arguments=arguments))
        if result.get('isError'):
            raise RuntimeError(result['content'][0]['text'])
        return result['structuredContent']

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)


def main():
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    source = Path(__file__).resolve().parents[2]
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    root = Path(tempfile.mkdtemp(prefix='toastty-mcp-e2e-')).resolve()
    runtime = root / 'runtime'
    user_home = root / 'home'
    fake_bin = root / 'fake-bin'
    for directory in (runtime, user_home / '.toastty', fake_bin):
        directory.mkdir(parents=True)
    fake = fake_bin / 'claude'
    fake.write_text(FAKE_CLAUDE)
    fake.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = ["{fake}"]\n')
    socket_path = f'/tmp/toastty-mcp-{os.getpid()}.sock'
    environment = {k: v for k, v in os.environ.items() if not k.startswith('TOASTTY_')}
    environment.update(TOASTTY_RUNTIME_HOME=str(runtime), TOASTTY_SOCKET_PATH=socket_path,
                       TOASTTY_USER_SKILLS_ROOT=str(runtime / 'skills'),
                       TOASTTY_RUNTIME_LABEL='mcp-e2e', CFFIXED_USER_HOME=str(user_home))
    app_log = open(artifacts / 'mcp-disposable-app.log', 'w')
    app = subprocess.Popen([str(bundle / 'Contents/MacOS/Toastty')], env=environment,
                           stdout=app_log, stderr=subprocess.STDOUT)
    evidence = dict(status='failed', host='disposable Toastty app', provider='fake Claude PTY',
                    gatewayEnablementRequested=False)
    mcp = None
    try:
        instance = wait_for('instance.json', lambda: json.loads((runtime / 'instance.json').read_text())
                            if (runtime / 'instance.json').exists() else None)
        require(instance['pid'] == app.pid and instance['socketPath'] == socket_path,
                'isolated app identity mismatch')
        wait_for('socket', lambda: Path(socket_path).exists())
        mcp = MCP(source / 'tools/toastty-mcp/server.mjs', socket_path)
        hello = mcp.request('initialize', dict(protocolVersion='2025-03-26', capabilities={},
                                               clientInfo=dict(name='fixture', version='1')))
        names = [tool['name'] for tool in mcp.request('tools/list')['tools']]
        require('toastty_start_session' in names and 'toastty_send_message' in names, names)
        evidence['mcp'] = dict(protocol=hello['protocolVersion'], toolNames=names,
                               transport='JSON-RPC stdio to Unix socket')

        offline = MCP(source / 'tools/toastty-mcp/server.mjs', socket_path + '.absent')
        try:
            offline.request('initialize')
            try:
                offline.tool('toastty_list_sessions')
                raise AssertionError('offline Toastty socket was accepted')
            except RuntimeError as error:
                require('ENOENT' in str(error), str(error))
        finally:
            offline.close()
        evidence['offlineSocketRejected'] = True

        initial = mcp.tool('toastty_list_sessions')
        workspace_id = initial['workspaces'][0]['id']
        try:
            mcp.tool('toastty_start_session', clientRequestID=str(uuid.uuid4()),
                     workspaceID=workspace_id, profileID='claude',
                     text='start\x1b[31m')
            raise AssertionError('control sequence was accepted as a first prompt')
        except RuntimeError as error:
            require('control characters' in str(error), str(error))
        evidence['controlSequenceRejected'] = True
        request_id = str(uuid.uuid4())
        started = mcp.tool('toastty_start_session', clientRequestID=request_id,
                           workspaceID=workspace_id, profileID='claude',
                           text='MCP fixture start')
        require(started['status'] == 'delivered_to_terminal', started)
        again = mcp.tool('toastty_start_session', clientRequestID=request_id,
                         workspaceID=workspace_id, profileID='claude', text='MCP fixture start')
        require(again == started, f'duplicate start differed: {again}')
        argv = wait_for('fake agent argv', lambda: json.loads((fake_bin / 'argv.json').read_text())
                        if (fake_bin / 'argv.json').exists() else None)
        require(argv[-1] == 'MCP fixture start', argv)
        evidence['start'] = dict(status=started['status'], duplicateReturnedSame=True,
                                 agentReceivedFirstPrompt=True)

        conversation = wait_for('listed conversation', lambda: next((c for c in
            mcp.tool('toastty_list_sessions')['conversations']
            if c['placement'].get('panelID') == started['panelID']), None))
        conversation_id = conversation['conversationID']
        def events():
            page = mcp.tool('toastty_read_progress', conversationID=conversation_id, limit=40)
            return page['page']['events'] if page.get('outcome') == 'page' else []
        first_events = wait_for('assistant transcript', lambda: (e if any(
            item['kind'] == 'assistant_message' and item['payload'].get('text') == 'Fixture ready for MCP'
            for item in e) else None) if (e := events()) else None)
        evidence['read'] = dict(eventCount=len(first_events), assistantSeen=True)

        def prompt_epoch():
            row = next((c for c in mcp.tool('toastty_list_sessions')['conversations']
                        if c['conversationID'] == conversation_id), None)
            availability = row['inputAvailability'] if row else {}
            return availability.get('epoch') if availability.get('kind') == 'open_prompt' else None
        epoch = wait_for('open prompt', prompt_epoch)
        wrong_target = mcp.tool('toastty_send_message', conversationID=str(uuid.uuid4()),
                                clientRequestID=str(uuid.uuid4()), expectedInputEpoch=epoch,
                                text='wrong target fixture')
        require(wrong_target['status'] == 'rejected', wrong_target)
        evidence['wrongConversationRejected'] = True
        nonce = 'mcp-nonce-' + uuid.uuid4().hex[:10]
        send_id = str(uuid.uuid4())
        sent = mcp.tool('toastty_send_message', conversationID=conversation_id,
                        clientRequestID=send_id, expectedInputEpoch=epoch, text=nonce)
        require(sent['status'] == 'accepted', sent)
        repeated = mcp.tool('toastty_send_message', conversationID=conversation_id,
                            clientRequestID=send_id, expectedInputEpoch=epoch, text=nonce)
        require(repeated['status'] == 'duplicate', repeated)
        def confirmed():
            page = events()
            return page if any(item['kind'] == 'user_message' and
                               item['payload'].get('clientRequestID') == send_id for item in page) else None
        confirmation = wait_for('transcript confirmation', confirmed)
        evidence['send'] = dict(status=sent['status'], repeated=repeated['status'],
                                transcriptConfirmed=True, nonce=nonce,
                                eventCount=len(confirmation))
        skill_id = str(uuid.uuid4())
        skill_epoch = wait_for('skill prompt', prompt_epoch)
        skill = mcp.tool('toastty_request_skill', conversationID=conversation_id,
                         clientRequestID=skill_id, expectedInputEpoch=skill_epoch,
                         skillName='toastty-verify', task='Run the fixture check')
        require(skill['status'] == 'accepted', skill)
        skill_events = wait_for('skill request confirmation', lambda: (e if any(
            item['kind'] == 'user_message' and
            item['payload'].get('clientRequestID') == skill_id and
            '$toastty-verify' in item['payload'].get('text', '')
            for item in e) else None) if (e := events()) else None)
        evidence['skill'] = dict(status=skill['status'], transcriptConfirmed=bool(skill_events))

        merge_id = str(uuid.uuid4())
        merge_epoch = wait_for('merge prompt', prompt_epoch)
        merge = mcp.tool('toastty_request_merge', conversationID=conversation_id,
                         clientRequestID=merge_id, expectedInputEpoch=merge_epoch,
                         pullRequestURL='https://github.com/example/project/pull/123')
        require(merge['status'] == 'accepted', merge)
        merge_events = wait_for('merge request confirmation', lambda: (e if any(
            item['kind'] == 'user_message' and
            item['payload'].get('clientRequestID') == merge_id and
            'prepare a merge handoff' in item['payload'].get('text', '')
            for item in e) else None) if (e := events()) else None)
        evidence['merge'] = dict(status=merge['status'], transcriptConfirmed=bool(merge_events))
        evidence['status'] = 'passed'
    finally:
        if mcp: mcp.close()
        app.send_signal(signal.SIGTERM)
        try: app.wait(timeout=10)
        except subprocess.TimeoutExpired: app.kill()
        app_log.close()
        (artifacts / 'mcp-e2e.json').write_text(json.dumps(evidence, indent=2, sort_keys=True))
        print(json.dumps(evidence, indent=2, sort_keys=True))


if __name__ == '__main__': main()

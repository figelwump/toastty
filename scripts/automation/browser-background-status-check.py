#!/usr/bin/env python3
"""Check detached browser status against a disposable remote validation app.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/browser-background-status-check.py'. This creates
background workspaces/panels in that app; it never selects or focuses them.
The remote wrapper owns app shutdown and disposable runtime cleanup.
"""

import collections
import http.server
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time
import uuid
import zlib


TIMEOUT = 30


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def make_png():
    """A valid 32x24 RGB image, also used as local file evidence."""
    def chunk(kind, data):
        return (struct.pack('!I', len(data)) + kind + data
                + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff))

    rows = b''.join(b'\x00' + b''.join(bytes((x * 8, y * 10, 120))
                                      for x in range(32)) for y in range(24))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('!IIBBBBB', 32, 24, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(('127.0.0.1', 0), FixtureHandler)
        self.counts = collections.Counter()
        self.lock = threading.Lock()
        self.release_slow = threading.Event()

    def count(self, path):
        with self.lock:
            return self.counts[path]


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        with self.server.lock:
            self.server.counts[path] += 1
        if path == '/disconnect':
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/final')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/slow':
            if not self.server.release_slow.wait(TIMEOUT):
                return
        body = (f'<!doctype html><title>Background {path}</title>'
                f'<h1>Background {path}</h1>').encode()
        if path == '/reload':
            body = f'<title>Reload {self.server.count(path)}</title>'.encode()
        if path == '/image.png':
            body = make_png()
        self.send_response(200)
        self.send_header('Content-Type', 'image/png' if path.endswith('.png')
                         else 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'max-age=3600' if path == '/reload' else 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Check:
    def __init__(self, evidence):
        self.evidence = evidence
        self.socket_path = os.environ['TOASTTY_SOCKET_PATH']
        instance = json.loads(Path(os.environ['TOASTTY_INSTANCE_JSON']).read_text())
        require(instance['socketPath'] == self.socket_path, 'Socket does not match instance.json')
        require(instance['pid'] == int(os.environ['TOASTTY_PID']), 'PID does not match instance.json')
        require(Path(instance['runtimeHomePath']).resolve()
                == Path(os.environ['TOASTTY_RUNTIME_HOME']).resolve(), 'Runtime home mismatch')
        label = os.environ['TOASTTY_REMOTE_VALIDATE_RUN_LABEL']
        expected = re.sub('[^a-z0-9]+', '-', label.lower()).strip('-')[:80].strip('-') or 'run'
        require(instance['runtimeLabel'] == expected, 'Runtime label mismatch')
        os.kill(instance['pid'], 0)
        self.evidence['target'] = {key: instance[key] for key in
                                   ('pid', 'runtimeLabel', 'runtimeHomePath', 'socketPath')}
        self.baseline = self.selection()
        self.evidence['selectionBefore'] = self.baseline

    def request(self, command, payload):
        request_id = str(uuid.uuid4())
        envelope = dict(protocolVersion='1.0', kind='request', requestID=request_id,
                        command=command, payload=payload)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(10)
            connection.connect(self.socket_path)
            connection.sendall(json.dumps(envelope).encode() + b'\n')
            data = b''
            while b'\n' not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
                require(len(data) < 1048576, 'Oversized socket response')
        response = json.loads(data)
        require(response.get('requestID') == request_id, 'Socket response requestID mismatch')
        require(response.get('ok'), f'{command} failed: {response}')
        return response['result']

    def query(self, query_id, **args):
        return self.request('app_control.run_query', dict(id=query_id, args=args))

    def action(self, action_id, **args):
        require(action_id in ('workspace.create', 'panel.create.browser'),
                f'Unexpected mutating action: {action_id}')
        return self.request('app_control.run_action', dict(id=action_id, args=args))

    def selection(self):
        selected = self.query('workspace.snapshot')
        return {key: selected[key] for key in
                ('workspaceID', 'selectedTabID', 'focusedPanelID', 'rightPanel')}

    def reload(self, panel):
        bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
        candidates = (bundle / 'Contents/Helpers/toastty', bundle / 'Contents/MacOS/toastty',
                      bundle.parent / 'toastty')
        cli = next((path for path in candidates if path.is_file() and os.access(path, os.X_OK)), None)
        require(cli is not None, 'Validation build has no Toastty CLI')
        # This disposable app owns no managed caller from the launching session.
        environment = dict(os.environ)
        environment.pop('TOASTTY_SESSION_ID', None)
        result = subprocess.run([str(cli), '--json', '--socket-path', self.socket_path,
                                 'action', 'run', 'panel.browser.reload', '--panel', panel],
                                capture_output=True, text=True, timeout=10, env=environment)
        require(result.returncode == 0, f'Reload CLI failed: {result.stderr} {result.stdout}')
        response = json.loads(result.stdout)
        require(response.get('ok'), f'Reload action failed: {response}')
        require(response['result']['panelID'] == panel, 'Reload targeted a different panel')
        self.unchanged()

    def unchanged(self):
        current = self.selection()
        self.evidence['selectionAfter'] = current
        require(current == self.baseline, 'Visible workspace/tab/focus changed')

    def create_browser(self, workspace, url):
        before = self.query('workspace.snapshot', workspaceID=workspace)['rightPanel']['panelIDs']
        self.action('panel.create.browser', workspaceID=workspace, placement='rightPanel', url=url)
        after = self.query('workspace.snapshot', workspaceID=workspace)['rightPanel']['panelIDs']
        added = set(after) - set(before)
        require(len(added) == 1, 'Expected one new background browser panel')
        self.unchanged()
        return added.pop()

    def state(self, panel):
        state = self.query('panel.browser.state', panelID=panel)
        required = {'observedURL', 'title', 'isLoading', 'navigationState', 'navigationError'}
        require(required <= state.keys(), f'Missing browser status fields: {required - state.keys()}')
        require(state['navigationState'] in ('idle', 'loading', 'finished', 'failed'),
                f'Unknown navigationState: {state}')
        require(isinstance(state['isLoading'], bool), 'isLoading must be boolean')
        require(state['observedURL'] is None or isinstance(state['observedURL'], str), 'Invalid observedURL')
        require(state['title'] is None or isinstance(state['title'], str), 'Invalid title')
        error = state['navigationError']
        if error is not None:
            require(isinstance(error, dict) and set(error) == {'domain', 'code', 'message'},
                    f'Invalid error schema: {error}')
            require(isinstance(error['domain'], str) and isinstance(error['message'], str)
                    and type(error['code']) is int, f'Invalid error types: {error}')
        require(state['hostLifecycleState'] == 'detached', f'Background browser attached: {state}')
        require(state['hostAttachmentID'] is None, 'Detached browser has host attachment')
        self.evidence.setdefault('states', {}).setdefault(panel, []).append(state)
        return state

    def poll(self, panel, expected, url=None, title=None):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            state = self.state(panel)
            self.unchanged()
            if state['navigationState'] == expected and not state['isLoading']:
                require(expected == 'failed' or state['navigationError'] is None,
                        f'Stale navigation error: {state}')
                require(expected != 'failed' or state['navigationError'] is not None,
                        'Failed navigation did not report an error')
                if url is not None:
                    require(state['observedURL'] == url, f'Unexpected observed URL: {state}')
                if title is not None:
                    require(state['title'] == title, f'Unexpected title: {state}')
                return state
            time.sleep(0.1)
        raise AssertionError(f'Timed out waiting for {expected}: {state}')


def main():
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    artifacts.mkdir(parents=True, exist_ok=True)
    evidence = {'status': 'running', 'checks': [], 'limitations': [
        'Navigation completion does not establish HTTP success, SPA readiness, or visual correctness.',
        'Unqueried panel network inactivity is checked; persisted restoration is covered separately.',
        'The socket catalog has no arbitrary browser navigation or screenshot action; superseded callbacks '
        'and detached screenshot rejection require runtime tests.'
    ]}
    server = None
    try:
        check = Check(evidence)
        server = FixtureServer()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        workspace = check.action('workspace.create', title='Background browser validation',
                                 activate=False)['workspaceID']
        check.unchanged()
        lazy = check.create_browser(workspace, base + '/lazy')
        time.sleep(0.5)
        require(server.count('/lazy') == 0, 'Panel creation eagerly loaded an unqueried browser')

        idle = check.create_browser(workspace, 'about:blank')
        check.poll(idle, 'idle')
        evidence['checks'].append('Start page reports idle while detached')

        for path, final in (('/page', '/page'), ('/redirect', '/final'), ('/image.png', '/image.png')):
            panel = check.create_browser(workspace, base + path)
            title = None if final.endswith('.png') else f'Background {final}'
            check.poll(panel, 'finished', base + final, title)
            count = server.count(final)
            require(count == 1, f'Expected one initial request for {final}, got {count}')
            for _ in range(8):
                check.poll(panel, 'finished', base + final, title)
                time.sleep(0.1)
            require(server.count(final) == count, f'Status polling reloaded {final}')
            evidence['checks'].append(f'Detached {path} finished; repeated polling did not reload')

        image = artifacts / 'background-browser-fixture.png'
        image.write_bytes(make_png())
        panel = check.create_browser(workspace, image.resolve().as_uri())
        check.poll(panel, 'finished', image.resolve().as_uri())
        evidence['checks'].append('Local PNG file finished while detached (not a visual assertion)')

        reloaded = check.create_browser(workspace, base + '/reload')
        check.reload(reloaded)
        check.poll(reloaded, 'finished', base + '/reload', 'Reload 1')
        require(server.count('/reload') == 1, 'First reload initiated duplicate requests')
        check.reload(reloaded)
        check.poll(reloaded, 'finished', base + '/reload', 'Reload 2')
        require(server.count('/reload') == 2, 'Reload did not revalidate cached page')
        evidence['checks'].append('CLI reload loads an unqueried panel once and refreshes a cached HTTP page')

        local = artifacts / 'reload-evidence.html'
        local.write_text('<title>Before reload</title>')
        local_panel = check.create_browser(workspace, local.resolve().as_uri())
        check.poll(local_panel, 'finished', local.resolve().as_uri(), 'Before reload')
        local.write_text('<title>After reload</title>')
        check.reload(local_panel)
        check.poll(local_panel, 'finished', local.resolve().as_uri(), 'After reload')
        evidence['checks'].append('CLI reload refreshes modified local HTML while detached')

        slow = check.create_browser(workspace, base + '/slow')
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            state = check.state(slow)
            if server.count('/slow') and state['navigationState'] == 'loading' and state['isLoading']:
                require(state['navigationError'] is None, 'New navigation retained an error')
                break
            time.sleep(0.1)
        else:
            raise AssertionError('Slow page never reported an in-progress navigation')
        check.reload(slow)
        deadline = time.monotonic() + TIMEOUT
        while server.count('/slow') < 2 and time.monotonic() < deadline:
            time.sleep(0.1)
        require(server.count('/slow') == 2, 'Reload stopped the slow request instead of restarting it')
        server.release_slow.set()
        check.poll(slow, 'finished', base + '/slow', 'Background /slow')
        evidence['checks'].append('CLI reload during loading restarts navigation and finishes while detached')

        for url in (base + '/disconnect', 'http://['):
            panel = check.create_browser(workspace, url)
            state = check.poll(panel, 'failed')
            if url == 'http://[':
                require(state['navigationError']['domain'] == 'NSURLErrorDomain'
                        and state['navigationError']['code'] == -1000, 'Expected invalid-URL error')
                # The error HTML may finish and publish metadata after failure.
                # Repeated queries must preserve failure instead of loading that helper URL.
                for _ in range(8):
                    time.sleep(0.1)
                    subsequent = check.poll(panel, 'failed')
                    require(subsequent['navigationError'] == state['navigationError'],
                            'Invalid URL error changed after loading the helper page')
            evidence['checks'].append(f'Navigation failure includes structured error for {url}')

        require(server.count('/lazy') == 0, 'Querying other browsers loaded the unqueried panel')
        check.poll(lazy, 'finished', base + '/lazy', 'Background /lazy')
        require(server.count('/lazy') == 1, 'Lazy panel did not load once on first query')
        evidence['checks'].append('Unqueried browser stays unloaded until its first state query')
        check.unchanged()
        evidence['checks'].append('Visible workspace, selected tab, focused panel and right panel unchanged')
        evidence['status'] = 'pass'
    except Exception as error:
        evidence['status'] = 'fail'
        evidence['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        if server is not None:
            server.release_slow.set()
            server.shutdown()
            server.server_close()
            evidence['httpRequestCounts'] = dict(server.counts)
        output = artifacts / 'browser-background-status.json'
        output.write_text(json.dumps(evidence, indent=2) + '\n')
        print(json.dumps({'status': evidence['status'], 'evidence': str(output),
                          'checks': evidence['checks']}))


if __name__ == '__main__':
    main()

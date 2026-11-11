#!/usr/bin/env python3
"""Attach files to a message in the coordinator's chat through its real UI,
with the real Claude CLI as the coordinator.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-attachments-check.py --gui-session'.
The run uses subscription usage. It needs the remote Mac's screen unlocked.

The check starts its own instance of the wrapper's build, with a throwaway
runtime home and user home, as remote-coordinator-chat-check.py does. Every
action goes through the real UI: real mouse drags from a small window that
offers a file (`drag-source.swift`), clicks and keys from `ax-drive.swift`.

The check proves from Claude's transcript and the chat's own text that:
- an image dragged onto the message field becomes an attachment, and the
  field holds no path; with typed text, Return sends the message, Claude
  reads the image and answers, and the chat never says that the
  conversation did not show the message;
- a promised file (as a screenshot's thumbnail gives) dragged onto the
  conversation above the field, an image pasted with Cmd-V, and a file
  chosen with + > Files… become attachments too;
- the message names each file as a path in a code span, in the
  coordinator's attachments folder, and Claude reads every file;
- the chat shows the text and the file names, not the paths.

Evidence goes to remote-coordinator-attachments-check.json, the app log,
Claude's transcripts, and full-screen stills under
remote-coordinator-attachments-check-frames in the artifacts directory.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time
import zlib

HERE = Path(__file__).parent
NAME = 'remote-coordinator-attachments-check'
# What the chat says when Toastty typed a message and the conversation did
# not show it, as a dropped bare image path once caused.
NOT_SHOWN = 'did not show it'
# The line before the paths in the message that Toastty types.
INTRODUCTION = 'Read the following files attached to this message'


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


chat_check = load('chat_check', 'remote-coordinator-chat-check.py')
coordinator_check = chat_check.coordinator_check
steer = chat_check.steer
require, wait_for = coordinator_check.require, coordinator_check.wait_for


def solid_png(path, rgb, size=160):
    """A square PNG of one color."""
    raw = b''.join(b'\x00' + bytes(rgb) * size for _ in range(size))

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


class DragSource:
    """A window that offers one file for a drag, in the GUI session."""

    def __init__(self, binary, mode, file, directory):
        self.ready = directory / f'drag-source-{mode}-{file.stem}.ready'
        self.ready.unlink(missing_ok=True)
        self.process = subprocess.Popen([str(binary), mode, str(file), str(self.ready)])
        wait_for('the drag source window', lambda: self.ready.is_file() and self.ready.read_text().strip(), timeout=20)
        self.point = [int(value) for value in self.ready.read_text().split()]

    @property
    def log(self):
        path = Path(f'{self.ready}.log')
        return path.read_text() if path.is_file() else ''

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()


def run(check):
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

    # The coordinator may read files, and do nothing else.
    argv = [claude, '--setting-sources=', '--allowedTools', 'Read', '--tools', 'Read', '--strict-mcp-config']
    runtime_home, user_home = check.home('attachments', argv)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)

    # The files to attach, outside the coordinator's folder.
    fixtures = check.root / 'fixtures'
    fixtures.mkdir()
    red, green, blue = fixtures / 'red square.png', fixtures / 'Screenshot green.png', fixtures / 'blue.png'
    solid_png(red, (220, 30, 30))
    solid_png(green, (30, 170, 60))
    solid_png(blue, (40, 80, 220))
    note = fixtures / 'secret-note.txt'
    note.write_text('The secret word is PAPAYA-7.\n')

    frames = check.artifacts / f'{NAME}-frames'
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    helper = check.root / 'drag-source'
    subprocess.run(['swiftc', '-O', str(HERE / 'drag-source.swift'), '-o', str(helper)], check=True, timeout=300)

    environment = check.environment('attachments', runtime_home, user_home, real_home=True)
    run_cli, cli = check.cli_runner(environment)
    directory = runtime_home / 'coordinator'
    directory.mkdir(parents=True)
    attachments_folder = (directory / 'attachments').resolve()
    steer.set_directory_trust(directory, True)
    project = steer.claude_project_directory(directory)
    app_log = check.artifacts / f'{check.prefix}-app.log'
    instance = chat_check.ChatInstance(check.binary, environment, environment['TOASTTY_SOCKET_PATH'], runtime_home, app_log)
    step = check.step
    check.evidence['stills'] = []
    sources = []

    def status():
        return cli('coordinator', 'status')

    def at_prompt():
        current = status()
        return current.get('agentState') == 'running' and current.get('status') in ('idle', 'ready') and current

    def transcript():
        entries = []
        for path in sorted(project.glob('*.jsonl'), key=lambda item: item.stat().st_mtime):
            for line in path.read_text().splitlines():
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get('type') not in ('user', 'assistant') or record.get('isSidechain'):
                    continue
                text = steer.claude_content_text((record.get('message') or {}).get('content'))
                if text:
                    entries.append(dict(role=record['type'], text=text))
        return entries

    def user_message(fragment):
        return next((entry['text'] for entry in transcript() if entry['role'] == 'user' and fragment in entry['text']), None)

    def reply(marker):
        return next((entry['text'] for entry in transcript() if entry['role'] == 'assistant' and marker in entry['text']), None)

    def still(name):
        """The whole screen as the user sees it, with the window's frame."""
        path = frames / f'{len(check.evidence["stills"]) + 1:02d}-{name}.png'
        completed = subprocess.run(['screencapture', '-x', '-t', 'png', str(path)], capture_output=True, text=True, timeout=30)
        code, window = ui.run('window-frame', check=False)
        check.evidence['stills'].append(dict(name=path.name, ok=completed.returncode == 0 and path.is_file(),
                                             window=window if code == 0 else None, error=completed.stderr.strip()))

    def chips():
        return ui.texts('coordinator.chat.attachments') if ui.exists('coordinator.chat.attachments') else ''

    def composer_text():
        return ui.texts('coordinator.chat.composer')

    def middle(identifier):
        x, y, width, height = (int(value) for value in ui.run('frame', identifier)[1].split())
        return x + width // 2, y + height // 2

    def drag(source, point):
        ui.run('drag', *map(str, source.point), *map(str, point))

    def require_no_path_in_field(where):
        text = composer_text()
        require('/' not in text and '.png' not in text and '.txt' not in text,
                f'{where}: the message field holds a path: {text!r}')

    try:
        instance.wait_until_ready()
        wait_for('instance.json', lambda: (runtime_home / 'instance.json').is_file())
        pid = json.loads((runtime_home / 'instance.json').read_text())['pid']
        ui = chat_check.UI(check.artifacts, pid)
        _, trust = ui.run('status')
        require('trusted=true' in trust and 'locked=false' in trust,
                f'The UI driver cannot act: {trust}. Unlock the screen, or run with --gui-session over SSH')

        opened = cli('coordinator', 'open')
        require(opened['startedAgent'] and opened['agentState'] == 'running', f'Open did not start Claude: {opened}')
        ui.run('activate')
        wait_for('the chat', lambda: ui.exists('coordinator.chat') and ui.exists('coordinator.chat.composer'))
        wait_for('Claude at its first prompt', at_prompt, timeout=180)
        if ui.has_label('Dismiss'):
            ui.run('click-label', 'Dismiss', check=False)
            time.sleep(0.5)
        # Room on the left of the window for the drag source.
        ui.run('window-set-frame', '240', '60', '1100', '820', check=False)
        ui.run('activate')
        time.sleep(1)
        still('chat-open')
        step('the chat is open with Claude at its prompt', version=version)

        # 1. An image dragged onto the message field, text, Return.
        source = DragSource(helper, 'file', red, check.root)
        sources.append(source)
        drag(source, middle('coordinator.chat.composer'))
        wait_for('the dropped image as an attachment', lambda: 'red square.png' in chips(), timeout=20)
        require_no_path_in_field('After the drop on the field')
        ui.run('activate')
        still('image-dropped-on-field')
        ui.send('What color is the square in the attached image? Reply with exactly COLOR- and the color in capitals, '
                'such as COLOR-PURPLE, and nothing else.')
        wait_for('Claude to read the image and answer', lambda: reply('COLOR-'), timeout=240)
        first = user_message('What color is the square')
        require(first is not None, 'Claude did not get the message')
        paths = [line.strip('` ') for line in first.splitlines() if line.startswith('`')]
        require(len(paths) == 1 and paths[0].startswith(str(attachments_folder) + '/') and paths[0].endswith('red-square.png'),
                f'The message does not name the copy in a code span: {first!r}')
        require(Path(paths[0]).is_file(), f'The copy is not there: {paths[0]}')
        answer = reply('COLOR-')
        require('COLOR-RED' in answer.upper(), f'Claude did not read the image: {answer!r}')
        wait_for('the chat to show the answer', lambda: 'COLOR-RED' in ui.texts().upper(), timeout=60)
        texts = ui.texts()
        require(NOT_SHOWN not in texts, f'The chat says the message did not show: {texts[-600:]}')
        # The user's bubble names the file. Toastty's list of paths shows
        # only in the terminal. A tool row may show the path Claude read.
        require(INTRODUCTION not in texts, f'The chat shows the list of paths: {texts[-600:]}')
        require('red-square.png' in texts, f'The chat does not name the file: {texts[-600:]}')
        require(chips() == '' and composer_text().strip() in ('', 'Message the coordinator…'),
                f'The composer is not empty after the send: {chips()!r} {composer_text()!r}')
        wait_for('the prompt to open again', at_prompt, timeout=120)
        still('dropped-image-sent-and-answered')
        step('an image dropped on the field went with the message, and Claude answered',
             message=first, answer=answer, notice=NOT_SHOWN in texts)

        # 2. A promised file dropped on the conversation, a pasted image, and
        # a file from + > Files….
        source.close()
        promise = DragSource(helper, 'promise', green, check.root)
        sources.append(promise)
        x, y, width, height = (int(value) for value in ui.run('frame', 'coordinator.chat')[1].split())
        drag(promise, (x + width // 2, y + height // 3))
        wait_for('the promised file as an attachment', lambda: 'Screenshot green.png' in chips(), timeout=30)
        require('wrote promise' in promise.log, f'The drop did not take the promise: {promise.log!r}')
        require_no_path_in_field('After the drop on the conversation')
        ui.run('activate')
        still('promise-dropped-on-conversation')

        subprocess.run([str(helper), 'copy-png', str(blue)], check=True, timeout=30)
        ui.run('focus', 'coordinator.chat.composer')
        time.sleep(0.3)
        ui.run('key', 'cmd-v')
        wait_for('the pasted image as an attachment', lambda: 'Pasted image.png' in chips(), timeout=20)
        require_no_path_in_field('After the paste')

        ui.run('click', 'coordinator.chat.attach')
        time.sleep(0.8)
        x, y, width, height = (int(value) for value in ui.run('label-frame', 'Files…')[1].split())
        ui.run('click-at', str(x + width // 2), str(y + height // 2))
        wait_for('the open panel', lambda: ui.run('sheet-texts', check=False)[0] == 0, timeout=20)
        ui.run('key', 'cmd-shift-g')
        time.sleep(1)
        ui.run('type', str(note))
        time.sleep(0.5)
        ui.run('key', 'return')
        time.sleep(1.5)
        still('files-open-panel')
        ui.run('key', 'return')
        wait_for('the chosen file as an attachment', lambda: 'secret-note.txt' in chips(), timeout=20)
        ui.run('activate')
        still('three-more-attachments')
        step('a promise drop, a paste and Files… attached', chips=chips())

        ui.send('Read every file attached to this message. Reply with exactly one line: ATTACH-OK, then the color '
                'of the square in each image in the order the files are listed, in lower case, then the secret word '
                'in the text file. For example: ATTACH-OK purple orange yellow WORD-1')
        wait_for('Claude to read the files and answer', lambda: reply('ATTACH-OK'), timeout=300)
        second = user_message('Read every file attached')
        paths = [line.strip('` ') for line in second.splitlines() if line.startswith('`')]
        require(len(paths) == 3 and all(path.startswith(str(attachments_folder) + '/') for path in paths)
                and [Path(path).name for path in paths] == ['Screenshot-green.png', 'Pasted-image.png', 'secret-note.txt'],
                f'The message does not name the three copies: {second!r}')
        answer = reply('ATTACH-OK')
        lower = answer.lower()
        require(0 <= lower.find('green') < lower.find('blue') and 'papaya-7' in lower,
                f'Claude did not read every file: {answer!r}')
        wait_for('the chat to show the answer', lambda: 'papaya-7' in ui.texts().lower(), timeout=60)
        texts = ui.texts()
        require(NOT_SHOWN not in texts, f'The chat says the message did not show: {texts[-600:]}')
        require('Screenshot-green.png, Pasted-image.png, secret-note.txt' in texts,
                f'The chat does not name the files: {texts[-800:]}')
        require(INTRODUCTION not in texts, f'The chat shows the list of paths: {texts[-800:]}')
        still('three-files-sent-and-answered')
        step('the files went with the message, and Claude read each', message=second, answer=answer)
    except Exception:
        try:
            still('failure')
        except Exception:  # noqa: BLE001 - the first error matters
            pass
        raise
    finally:
        for source in sources:
            source.close()
        try:
            instance.kill()
        except Exception:  # noqa: BLE001 - the evidence below matters more
            pass
        check.copy_instance_log(runtime_home, 'attachments')
        steer.set_directory_trust(directory, False)
        if project.is_dir():
            saved = check.artifacts / f'{check.prefix}-transcripts'
            saved.mkdir(exist_ok=True)
            for path in project.glob('*.jsonl'):
                shutil.copyfile(path, saved / path.name)
            shutil.rmtree(project, ignore_errors=True)


class Check(coordinator_check.Check):
    def __init__(self):
        super().__init__('claude')
        self.prefix = NAME


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--gui-session', action='store_true',
                        help='rerun through Terminal in the GUI session, where the Claude login is readable')
    options = parser.parse_args()
    if options.gui_session:
        chat_check.run_in_gui_session([], name=NAME, script=__file__)
    check = Check()
    try:
        run(check)
        check.evidence['status'] = 'passed'
    except Exception as error:  # noqa: BLE001 - always keep the evidence
        check.evidence['failure'] = repr(error)
        raise
    finally:
        check.finish()
    print(f'[{NAME}] passed', flush=True)


if __name__ == '__main__':
    main()

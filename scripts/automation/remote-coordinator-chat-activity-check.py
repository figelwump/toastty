#!/usr/bin/env python3
"""Show the coordinator chat's working state and its folded work.

Run through scripts/remote/validate.sh --require-remote --validation-command
'python3 scripts/automation/remote-coordinator-chat-activity-check.py [--capture-only] [--gui-session]'.
It needs an unlocked screen for the window resize. Add --capture-only to
record the same captures without the checks, as for a build from before
this change.

The check starts its own app instance with a throwaway runtime home, the fake
coordinator agent from remote-coordinator-session-check.py, and a synthetic
Claude transcript bound through the public Claude hook route, as
remote-coordinator-chat-check.py does. The transcript uses Claude's record
shapes: tool_use and tool_result blocks, `stop_reason: tool_use` on
intermediate text and `end_turn` on a turn's final text. Through the real
page it checks that:
- the automatic launch prompt does not show, and the launch turn's work folds
  to one line beside its final message;
- a message sent from the composer shows a working row at once, before the
  transcript records it;
- while the turn runs, its tool calls and intermediate messages fold into the
  working row, which names the latest intermediate message;
- a card posted during the turn stays visible outside the fold;
- when the turn ends, the work folds to one line with its tool and note
  counts, the final message shows, and the working row goes away;
- a fold opens on click and shows the tool lines;
- work after a background wake-up, with no user message, folds as well.
- a pending background shell keeps its waiting state without a Working row,
  including when the user sends another message or a background task wakes it.
No real provider runs; this proves the page and the app's state, not what a
real Claude session writes.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone

HERE = Path(__file__).parent


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


create_check = _load('remote_task_create_check', 'remote-task-create-check.py')
queue_check = _load('remote_queue_steer_check', 'remote-queue-steer-check.py')
session_check = _load('remote_coordinator_session_check', 'remote-coordinator-session-check.py')
require, wait_for, Instance = create_check.require, create_check.wait_for, create_check.Instance

PREFIX = 'remote-coordinator-chat-activity'
REQUEST = 'cleanup worktrees in toastty'


def main():
    capture_only = '--capture-only' in sys.argv[1:]
    if '--gui-session' in sys.argv[1:]:
        queue_check.run_in_gui_session(PREFIX, __file__, [a for a in sys.argv[1:] if a != '--gui-session'])
    bundle = Path(os.environ['TOASTTY_APP_BUNDLE'])
    artifacts = Path(os.environ['TOASTTY_ARTIFACTS_DIR'])
    binary, cli = bundle / 'Contents/MacOS/Toastty', bundle / 'Contents/Helpers/toastty'
    require(binary.is_file() and cli.is_file(), f'No Toastty binary or CLI in {bundle}')

    root = Path(tempfile.mkdtemp(prefix='toastty-coordinator-activity-check-', dir='/tmp')).resolve()
    runtime_home, user_home, fake_bin, work = root / 'runtime-home', root / 'user-home', root / 'bin', root / 'work'
    for directory in (runtime_home, user_home / '.toastty', fake_bin, work):
        directory.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(user_home)], check=True)
    agent = fake_bin / 'claude'
    agent.write_text(session_check.FAKE_AGENT.replace(
        '  [ "$line" = quit ] && exit 0\n',
        '  printf \'%s\\n\' "$line" >> "$dir/$TOASTTY_SESSION_ID.input"\n'
        '  [ "$line" = quit ] && exit 0\n'))
    agent.chmod(0o755)
    (user_home / '.toastty/agents.toml').write_text(
        f'[claude]\ndisplayName = "Claude Code"\nargv = {json.dumps([str(agent)])}\n')
    (user_home / '.toastty/tasks.toml').write_text('[defaults]\nagent = "claude"\n')

    helper = root / 'task-stages-ui-helper'
    subprocess.run(['swiftc', '-O', str(HERE / 'task-stages-ui-helper.swift'), '-o', str(helper)], check=True)

    socket_path = str(root / 'socket.sock')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('TOASTTY_') and key not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}
    environment.update(
        TOASTTY_RUNTIME_HOME=str(runtime_home),
        TOASTTY_USER_SKILLS_ROOT=str(runtime_home / 'skills'),
        TOASTTY_RUNTIME_LABEL=PREFIX,
        TOASTTY_SOCKET_PATH=socket_path,
        TOASTTY_COORDINATOR_AUTOSTART='1',
        # Automation mode lets the app capture its own window, web content
        # included, where the host gives no Screen Recording grant.
        TOASTTY_AUTOMATION='1',
        TOASTTY_ARTIFACTS_DIR=str(artifacts),
        HOME=str(user_home),
        CFFIXED_USER_HOME=str(user_home),
        PATH=f'{fake_bin}:{environment.get("PATH", "")}',
        DISABLE_AUTOUPDATER='1',
    )
    cli_environment = {key: value for key, value in environment.items()
                       if key not in ('TOASTTY_COORDINATOR_AUTOSTART', 'TOASTTY_AUTOMATION')}
    evidence = dict(status='failed', captureOnly=capture_only, steps=[], captures=[], root=str(root))

    def step(name, **facts):
        evidence['steps'].append(dict(step=name, at=time.time(), **facts))
        print(f'[activity-check] {name} {json.dumps(facts, default=str)}', flush=True)

    def check(condition, message):
        # Capture-only runs record what the build shows without judging it.
        if not capture_only:
            require(condition, message)

    def cli_result(*arguments, session=None, stdin=None):
        env = dict(cli_environment)
        if session:
            env.update(TOASTTY_SESSION_ID=session['sessionID'], TOASTTY_PANEL_ID=session['panelID'])
        result = subprocess.run([str(cli), '--json', '--socket-path', socket_path, *arguments], env=env, cwd=work,
                                input=stdin, capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, f'toastty {" ".join(arguments[:3])} failed ({result.returncode}): {result.stdout} {result.stderr}')
        return json.loads(result.stdout).get('result') or {}

    instance = Instance(binary, environment, socket_path, runtime_home, artifacts / f'{PREFIX}-app.log')
    pid = instance.process.pid

    def chat_state():
        return instance.query('coordinator.chat.state')

    def rendered():
        response = instance.request('automation.coordinator_page_state', {})
        require(response.get('ok'), f'Could not inspect coordinator pages: {response}')
        return next((page for page in response['result']['pages'] if page['view'] == 'chat'), None)

    def page_action(action, element_id, text=None):
        payload = dict(action=action, elementID=element_id)
        if text is not None:
            payload['text'] = text
        response = instance.request('automation.coordinator_chat_action', payload)
        require(response.get('ok'), f'The page could not {action} {element_id}: {response}')
        return response

    def capture(name):
        path = artifacts / f'{name}.png'
        time.sleep(1.0)
        response = instance.request('automation.capture_screenshot', dict(step=name))
        if not response.get('ok'):
            step('capture unavailable', file=path.name, app=response.get('error'))
            return
        if Path(response['result']['path']).resolve() != path.resolve():
            shutil.copyfile(response['result']['path'], path)
        evidence['captures'].append(path.name)
        step('captured', file=path.name)

    def page_facts():
        page = rendered() or {}
        return {key: page.get(key) for key in ('workStrips', 'activityText', 'visibleToolCount', 'visibleMessageTexts')}

    try:
        instance.wait_until_ready()
        coordinator = wait_for('the coordinator to run', lambda: (lambda s: s if s['state'] == 'running' else None)(
            instance.query('coordinator.status')), timeout=90, interval=1)
        cli_result('coordinator', 'show')
        actual_size = json.loads(subprocess.run([str(helper), 'resize', str(pid), '1400', '900'], capture_output=True,
                                                text=True, timeout=60).stdout or '{}')
        wait_for('the chat page', lambda: rendered() is not None, timeout=30, interval=0.3)
        step('coordinator chat open', sessionID=coordinator['sessionID'], window=actual_size)

        # Bind a synthetic Claude transcript to the coordinator through the
        # public hook route, as remote-coordinator-chat-check.py does.
        session_path = fake_bin / 'sessions' / f"{coordinator['sessionID']}.json"
        session = json.loads(session_path.read_text())
        native_id = str(uuid.uuid4())
        transcript = root / f'{native_id}.jsonl'
        transcript.touch()

        def record(kind, message):
            # Claude's own format, so each line keeps its record time.
            now = datetime.now(timezone.utc)
            stamp = now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond // 1000:03d}Z'
            row = dict(type=kind, sessionId=native_id, uuid=str(uuid.uuid4()), isSidechain=False,
                       timestamp=stamp, message=message)
            with transcript.open('a') as stream:
                stream.write(json.dumps(row) + '\n')

        def user(text):
            record('user', dict(role='user', content=text))

        def say(text, final):
            record('assistant', dict(role='assistant', content=[dict(type='text', text=text)],
                                     stop_reason='end_turn' if final else 'tool_use'))

        def tool(command, finished=True):
            call_id = f'toolu_{uuid.uuid4().hex[:20]}'
            record('assistant', dict(role='assistant', stop_reason='tool_use',
                                     content=[dict(type='tool_use', id=call_id, name='Bash', input=dict(command=command))]))
            if finished:
                record('user', dict(role='user', content=[dict(type='tool_result', tool_use_id=call_id,
                                                               content='ok', is_error=False)]))

        def hook(name, **fields):
            cli_result('session', 'ingest-agent-event', '--source', 'claude-hooks', session=session,
                       stdin=json.dumps(dict(hook_event_name=name, session_id=native_id,
                                             transcript_path=str(transcript), cwd=session['cwd'], **fields)))

        background_tasks = [dict(id='fixture-watch', type='shell', status='running',
                                 description='Watch for new tasks')]

        def shows(text):
            return any(item.get('text') == text for item in chat_state()['items'])

        # 1. The launch turn: the automatic prompt, four steps, a final message.
        hook('SessionStart')
        hook('UserPromptSubmit', turn_id='launch', prompt=session_check.FIRST_MESSAGE)
        user(session_check.FIRST_MESSAGE)
        tool('"$TOASTTY_CLI_PATH" --json task list')
        say('Nothing is running yet. I will check the routing notes.', final=False)
        tool('cat "$TOASTTY_COORDINATOR_DIR/routing.md"')
        launch_final = 'No tasks need you. I am waiting for new requests.'
        say(launch_final, final=True)
        wait_for('the launch turn in the chat', lambda: shows(launch_final), timeout=30, interval=0.3)
        hook('Stop', turn_id='launch', last_assistant_message=launch_final, background_tasks=background_tasks)
        wait_for('the coordinator prompt after the launch turn', lambda: (state := chat_state())
                 and state['inputState'] == 'openPrompt' and state['canSend'], timeout=30, interval=0.3)
        facts = page_facts()
        check(chat_state().get('waiting') and not chat_state()['working'],
              'The pending background watch did not settle into a non-working wait')
        capture('activity-1-launch-settled')
        page = rendered()
        launch_visible = session_check.FIRST_MESSAGE in (page.get('visibleMessageTexts') or [])
        check(not launch_visible, 'The automatic launch prompt still shows')
        check([strip['live'] for strip in facts['workStrips'] or []] == [False], f'The launch turn did not fold to one line: {facts}')
        check(facts['visibleToolCount'] == 0, f'Tool lines show outside a fold: {facts}')
        check(facts['activityText'] is None, f'A working row shows while the coordinator is idle: {facts}')
        step('launch turn folded', **facts)

        # 2. Send from the composer. The working row shows before the
        # transcript has the message, as soon as the app takes it.
        page_action('type', 'composer-input', REQUEST)
        input_path = fake_bin / 'sessions' / f"{coordinator['sessionID']}.input"
        wait_for('the request in the fake coordinator', lambda: input_path.is_file() and REQUEST in input_path.read_text(),
                 timeout=30, interval=0.3)
        facts = page_facts()
        capture('activity-2-just-sent')
        check(facts['activityText'] and facts['activityText'].lower().startswith('working'),
              f'No working row right after the send: {facts}')
        step('working row after send, before the transcript', **facts)

        # 3. The turn runs: steps fold into the working row.
        hook('UserPromptSubmit', turn_id='request', prompt=REQUEST)
        user(REQUEST)
        tool('"$TOASTTY_CLI_PATH" --json task workspace-choices')
        narration = 'The project is the main toastty repo. I will check how task create takes a project folder.'
        say(narration, final=False)
        tool('"$TOASTTY_CLI_PATH" task create --help 2>&1 | head -40')
        cli_result('coordinator', 'post', 'note', 'Started a task to clean up merged worktrees in toastty.')
        tool('"$TOASTTY_CLI_PATH" task watch 6F337EB3 --until idle --wait', finished=False)
        # Two launch tools and three in this turn, the last still running.
        wait_for('the running tool in the chat', lambda: sum(item['type'] == 'tool' for item in chat_state()['items']) == 5,
                 timeout=30, interval=0.3)
        time.sleep(1.5)
        facts = page_facts()
        capture('activity-3-working')
        live = [strip for strip in facts['workStrips'] or [] if strip['live']]
        check(len(live) == 1, f'The running turn has no live fold: {facts}')
        check(facts['visibleToolCount'] == 0, f'Tool lines show outside a fold while working: {facts}')
        check(facts['activityText'] and narration[:40] in facts['activityText'],
              f'The working row does not name the latest step: {facts}')
        step('running turn folded into the working row', **facts)

        # 4. The turn ends.
        request_final = 'I started a task to clean up worktrees in the main toastty repo.'
        say(request_final, final=True)
        wait_for('the final message', lambda: shows(request_final), timeout=30, interval=0.3)
        hook('Stop', turn_id='request', last_assistant_message=request_final, background_tasks=background_tasks)
        wait_for('the coordinator prompt after the request', lambda: chat_state()['inputState'] == 'openPrompt',
                 timeout=30, interval=0.3)
        time.sleep(1.0)
        facts = page_facts()
        capture('activity-4-settled')
        strips = facts['workStrips'] or []
        check(len(strips) == 2 and not any(strip['live'] for strip in strips), f'Expected two settled folds: {facts}')
        check(strips and '3 tool calls' in strips[-1]['label'] and '1 note' in strips[-1]['label'],
              f'The settled fold does not count its steps: {facts}')
        check(facts['activityText'] is None, f'The working row stayed after the turn ended: {facts}')
        check(request_final in (facts['visibleMessageTexts'] or []), f'The final message is hidden: {facts}')
        step('turn settled into one fold', **facts, order=[(item['type'], (item.get('text') or item.get('kind') or '')[:40], item.get('at'))
                                                             for item in chat_state()['items']])
        cli_result('coordinator', 'show-terminal')
        capture('activity-4-terminal-waiting')
        cli_result('coordinator', 'show')
        wait_for('the chat page after the native terminal',
                 lambda: (page := rendered()) and any(strip['elementID'] == strips[-1]['elementID']
                                                      for strip in page.get('workStrips', [])),
                 timeout=30, interval=0.3)

        # 5. A fold opens on click.
        if strips:
            page_action('click', strips[-1]['elementID'])
            time.sleep(0.5)
            facts = page_facts()
            capture('activity-5-expanded')
            check(facts['visibleToolCount'] == 3, f'The open fold does not show its tool lines: {facts}')
            check(narration in (facts['visibleMessageTexts'] or []), f'The open fold hides its intermediate message: {facts}')
            page_action('click', strips[-1]['elementID'])
            step('fold opened and closed', **facts)

        # 6. A background wake-up: Claude drops the task-notification record,
        # so the transcript has work and a reply with no user message.
        wake_command = '"$TOASTTY_CLI_PATH" --json task get 6F337EB3'
        hook('PreToolUse', tool_name='Bash', tool_input=dict(command=wake_command))
        tool(wake_command)
        if not capture_only:
            wait_for('the background wake-up to show active work', lambda: chat_state()['working'] and not chat_state()['waiting'],
                     timeout=30, interval=0.3)
        wake_final = 'The cleanup task removed 18 merged worktrees and is waiting for your answer.'
        say(wake_final, final=True)
        wait_for('the wake-up reply', lambda: shows(wake_final), timeout=30, interval=0.3)
        hook('Stop', last_assistant_message=wake_final, background_tasks=background_tasks)
        if not capture_only:
            wait_for('the coordinator to wait after the wake-up', lambda: chat_state()['waiting'] and not chat_state()['working'],
                     timeout=30, interval=0.3)
        time.sleep(1.0)
        facts = page_facts()
        capture('activity-6-wake-up')
        check(len(facts['workStrips'] or []) == 3 and facts['visibleToolCount'] == 0,
              f'Wake-up work did not fold: {facts}')
        step('wake-up work folded', **facts)

        evidence['status'] = 'captured' if capture_only else 'passed'
    except Exception as error:
        diagnostics = dict(error=str(error))
        for name, read in [('chatState', chat_state), ('page', rendered)]:
            try:
                diagnostics[name] = read()
            except Exception as probe_error:
                diagnostics[name] = dict(error=str(probe_error))
        (artifacts / f'{PREFIX}-failure-diagnostics.json').write_text(json.dumps(diagnostics, indent=2, default=str))
        try:
            capture('activity-failed')
        except Exception:
            pass
        raise
    finally:
        try:
            instance.kill()
        except Exception:
            pass
        (artifacts / f'{PREFIX}-check.json').write_text(json.dumps(evidence, indent=2, default=str))
    print(f'[activity-check] {evidence["status"]}', flush=True)


if __name__ == '__main__':
    main()

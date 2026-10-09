#!/usr/bin/env python3
"""Emit real OSC 7501 reports in an isolated Toastty terminal for verification."""
import argparse
import base64
import os
import select
import termios
import time
import tty


def report(state, **fields):
    for name in ("title", "msg"):
        if name in fields:
            fields[name] = base64.b64encode(fields[name].encode()).decode()
    body = ":".join(["state=" + state] + [f"{k}={v}" for k, v in fields.items()])
    os.write(1, ("\x1b]7501;" + body + "\x1b\\").encode())


def query_support():
    saved = termios.tcgetattr(0)
    try:
        tty.setraw(0)
        query = b"\x1b]7501;?\x1b\\"
        os.write(1, query)
        response = b""
        deadline = time.monotonic() + 5
        while query not in response and time.monotonic() < deadline:
            if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
                response += os.read(0, 4096)
        if query not in response:
            raise SystemExit("OSC 7501 support query received no reply")
    finally:
        termios.tcsetattr(0, termios.TCSANOW, saved)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=["working", "permission", "question", "auth", "done", "error", "agent", "lifecycle", "flood"], default="permission")
    parser.add_argument("--hold-seconds", type=float, default=120)
    args = parser.parse_args()
    query_support()
    print("OSC 7501 support confirmed", flush=True)
    report("clear")
    if args.scenario == "lifecycle":
        report("working", app="deploy", title="Deploy café", progress=65)
        report("blocked", id="west", title="EU West", msg="Approve deployment?", kind="permission")
        os.write(1, b"\x1b]133;A\x1b\\")
        report("done", msg="Complete")
        os.write(1, b"\x1bc")
        report("done", app="deploy", title="Result", msg="Reset complete")
    elif args.scenario == "flood":
        for index in range(1000):
            report("working", id=f"task{index}", app="build", progress=index % 101)
        report("clear")
        report("done", app="build", title="Flood complete")
    elif args.scenario == "agent":
        report("blocked", app="claude-code", msg="Which retry policy should I use?", kind="question")
    else:
        report("working", app="deploy", title="Deploy v2.4.1", msg="Uploading images to 3 regions…", progress=65)
        if args.scenario == "permission":
            report("blocked", id="west", title="EU West", msg="approve deployment?", kind="permission")
        elif args.scenario in ("question", "auth"):
            message = "Choose a deployment region" if args.scenario == "question" else "Sign in to the deployment account"
            report("blocked", app="deploy", title="Deploy v2.4.1", msg=message, kind=args.scenario)
        elif args.scenario in ("done", "error"):
            report(args.scenario, app="deploy", title="Deploy v2.4.1", msg="Deployed v2.4.1 to 3 regions" if args.scenario == "done" else "EU West: deployment failed")
    print(f"Scenario: {args.scenario}. Status remains for {args.hold_seconds:g} seconds.", flush=True)
    time.sleep(args.hold_seconds)


if __name__ == "__main__":
    main()

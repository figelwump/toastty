#!/usr/bin/env python3
"""Send one Toastty socket request: socket-request.py SOCKET COMMAND [PAYLOAD_JSON]."""
import json, socket, sys, uuid
path, command = sys.argv[1], sys.argv[2]
payload = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path)
s.sendall((json.dumps({"protocolVersion": "1.0", "kind": "request", "requestID": str(uuid.uuid4()), "command": command, "payload": payload}) + "\n").encode())
data = b""
while True:
    chunk = s.recv(65536)
    if not chunk: break
    data += chunk
print(data.decode())

"""Disposable authenticated subscriber, terminated by the parent after PREEDIT."""
import json
from pathlib import Path
import socket
import sys
import time

directory = Path(sys.argv[1])
pidfile = directory / 'pid'
deadline = time.monotonic() + 150
while not pidfile.exists() and time.monotonic() < deadline:
    time.sleep(.02)
pid = int(pidfile.read_text())
token = '0123456789abcdef0123456789abcdef'
with socket.socket() as server:
    server.bind(('127.0.0.1', 0))
    server.listen()
    (directory / f'{pid}.json').write_text(json.dumps({
        'version': 1, 'port': server.getsockname()[1], 'token': token}), encoding='utf-8')
    with server.accept()[0] as connection, (directory / 'drop-channel.log').open('w', encoding='utf-8') as log:
        with connection.makefile('r', encoding='utf-8', newline='\n') as stream:
            for line in stream:
                log.write(line)
                log.flush()
                if line.startswith('HELLO'):
                    assert line == f'HELLO 1 {token} {pid}\n', line
                    connection.sendall(b'OK 1\nCARET 321 456 23\n')

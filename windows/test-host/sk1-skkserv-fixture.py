"""Synthetic SKK server; loopback test ports only, UTF-8 host/EUC-JP stock."""
import argparse
import socket
import threading
import time


def serve(client, delay):
    with client:
        client.settimeout(5)
        pending = b''
        try:
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    return
                pending += chunk
                while pending:
                    command = pending[:1]
                    if command == b'0':
                        return
                    if command in (b'2', b'3'):
                        client.sendall(b'SK1-fixture ')
                        pending = pending[1:]
                        continue
                    if b' ' not in pending:
                        break
                    raw, pending = pending.split(b' ', 1)
                    try:
                        reading = raw[1:].decode('utf-8')
                        encoding = 'utf-8'
                    except UnicodeDecodeError:
                        reading = raw[1:].decode('euc-jp')
                        encoding = 'euc-jp'
                    time.sleep(delay / 1000)
                    words = {'かな': '/仮名/serverExtra/', 'なぞ': '/serverOnly/'}
                    reply = '1' + words[reading] if reading in words else '4'
                    client.sendall((reply + '\n').encode(encoding))
        except (OSError, UnicodeError):
            return


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=31102)
    parser.add_argument('--delay-ms', type=int, default=0)
    args = parser.parse_args()
    if not 31100 <= args.port <= 31199:
        parser.error('fixture ports are 31100-31199')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', args.port))
        listener.listen()
        print('READY', args.port, flush=True)
        while True:
            connection, _ = listener.accept()
            threading.Thread(target=serve, args=(connection, args.delay_ms), daemon=True).start()

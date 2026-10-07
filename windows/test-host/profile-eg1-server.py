"""Read-only synthetic skkserv fixture. Never uses a personal dictionary."""
import argparse
import socket
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--dictionary", required=True)
parser.add_argument("--port", type=int, choices=range(31100, 31200), required=True)
args = parser.parse_args()
table = {}
with open(args.dictionary, encoding="utf-8-sig") as source:
    for line in source:
        if not line.startswith(";") and " " in line:
            key, value = line.strip().split(" ", 1)
            table.setdefault(key, value)

def serve(connection):
    with connection:
        pending = b""
        while True:
            chunk = connection.recv(8192)
            if not chunk:
                return
            pending += chunk
            if len(pending) > 65536:
                return
            while b" " in pending:
                query, pending = pending.split(b" ", 1)
                key = query[1:].decode("utf-8")
                reply = "1"+table[key] if query.startswith(b"1") and key in table else "4"
                connection.sendall((reply+"\n").encode("utf-8"))

with socket.socket() as listener:
    listener.bind(("127.0.0.1", args.port))
    listener.listen()
    print(f"READY private fixture port={args.port} entries={len(table)}", flush=True)
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=serve, args=(connection,), daemon=True).start()

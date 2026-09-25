#!/usr/bin/env python3
"""Send one Lisp command form to a running BES TCP server."""

from __future__ import annotations

import argparse
import socket
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path, help="file containing one Lisp form")
    source.add_argument("--message", help="literal Lisp form")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--timeout", type=float, default=5.0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    message = args.file.read_text(encoding="utf-8") if args.file else args.message
    message = message.strip()
    if not message:
        raise SystemExit("Refusing to send an empty BES command")
    if not (message.startswith("(") and message.endswith(")")):
        raise SystemExit("BES command must be one complete parenthesized Lisp form")

    with socket.create_connection((args.host, args.port), timeout=args.timeout) as sock:
        sock.sendall((message + "\n").encode("utf-8"))

    origin = str(args.file) if args.file else "literal command"
    print(f"Sent {origin} to {args.host}:{args.port}")


if __name__ == "__main__":
    main()


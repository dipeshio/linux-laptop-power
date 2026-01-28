#!/usr/bin/env python3
import time
import signal
import sys

def handler(signum, frame):
    sys.exit(0)

signal.signal(signal.SIGTERM, handler)

def stress():
    try:
        while True:
            [x**2 for x in range(100000)]
    except:
        pass

if __name__ == '__main__':
    stress()

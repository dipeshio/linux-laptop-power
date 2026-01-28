#!/usr/bin/env python3
import numpy as np
import signal
import sys

def handler(signum, frame):
    sys.exit(0)

signal.signal(signal.SIGTERM, handler)

try:
    while True:
        a = np.random.rand(1000, 1000)
        b = np.random.rand(1000, 1000)
        c = np.dot(a, b)
        np.linalg.eig(c[:100, :100])
except:
    pass

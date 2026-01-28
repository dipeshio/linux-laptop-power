#!/usr/bin/env python3
import multiprocessing
import signal
import sys

def handler(signum, frame):
    sys.exit(0)

signal.signal(signal.SIGTERM, handler)

def is_prime(n):
    if n < 2: return False
    for i in range(2, int(n**0.5) + 1):
        if n % i == 0: return False
    return True

def find_primes(start, end):
    return [n for n in range(start, end) if is_prime(n)]

if __name__ == '__main__':
    try:
        while True:
            with multiprocessing.Pool(2) as pool:
                results = pool.starmap(find_primes, [(1, 500000), (500000, 1000000)])
    except:
        pass

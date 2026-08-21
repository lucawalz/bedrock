#!/usr/bin/env python3

import hashlib
import json
import multiprocessing
import os
import time

# 48 divides every core count on offer, so no machine idles a worker waiting on the tail.
SHARD_COUNT = 48
# Calibrated for about five minutes of fixed work on two shared vCPU.
DEFAULT_SHARD_ITERATIONS = 15000000
DEFAULT_SEED = 20260807

MODULUS = (1 << 61) - 1
MULTIPLIER = 6364136223846793005
INCREMENT = 1442695040888963407
SHARD_STRIDE = 11400714819323198485

RESULT_SEPARATOR = ","
INSTANT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
ELAPSED_DECIMALS = 3


def read_positive_int(name, default):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    if not raw.isdigit() or int(raw) < 1:
        raise SystemExit(f"quantum: {name} must be a positive whole number, got {raw!r}")
    return int(raw)


def run_shard(task):
    index, iterations, seed = task
    state = (seed + index * SHARD_STRIDE) % MODULUS
    accumulator = 0
    for _ in range(iterations):
        state = (state * MULTIPLIER + INCREMENT) % MODULUS
        accumulator = (accumulator + state) % MODULUS
    return accumulator


def as_instant(epoch_seconds):
    return time.strftime(INSTANT_FORMAT, time.gmtime(epoch_seconds))


def main():
    shard_iterations = read_positive_int("QUANTUM_SHARD_ITERATIONS", DEFAULT_SHARD_ITERATIONS)
    seed = read_positive_int("QUANTUM_SEED", DEFAULT_SEED)
    workers = min(read_positive_int("QUANTUM_WORKERS", os.process_cpu_count() or 1), SHARD_COUNT)

    tasks = [(index, shard_iterations, seed) for index in range(SHARD_COUNT)]
    with multiprocessing.get_context("fork").Pool(processes=workers) as pool:
        started_at = time.time()
        started = time.monotonic()
        results = pool.map(run_shard, tasks, chunksize=1)
        elapsed = time.monotonic() - started
        finished_at = time.time()

    joined = RESULT_SEPARATOR.join(str(result) for result in results)
    print(
        json.dumps(
            {
                "checksum": hashlib.sha256(joined.encode()).hexdigest(),
                "completionIndex": os.environ.get("JOB_COMPLETION_INDEX", ""),
                "elapsedSeconds": round(elapsed, ELAPSED_DECIMALS),
                "finishedAt": as_instant(finished_at),
                "iterations": SHARD_COUNT * shard_iterations,
                "node": os.environ.get("QUANTUM_NODE_NAME", ""),
                "pod": os.environ.get("QUANTUM_POD_NAME", ""),
                "seed": seed,
                "shardIterations": shard_iterations,
                "shards": SHARD_COUNT,
                "startedAt": as_instant(started_at),
                "workers": workers,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()

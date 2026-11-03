#!/usr/bin/env python3
"""Run the complete profile CLI; a stalled/partial run can never pass."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run(binary, log, timeout=180):
    binary, log = Path(binary).resolve(), Path(log).resolve()
    log.parent.mkdir(parents=True, exist_ok=True)
    report_path = log.with_suffix('.run.json')
    sample_path = log.with_suffix('.sample.txt')
    if any(p.exists() for p in [log, report_path, sample_path]):
        raise ValueError('Preserve prior profile results; use a fresh result path.')
    started = time.monotonic()
    timed_out = False
    sample_status = 'not_needed'
    with log.open('xb') as output:
        child = subprocess.Popen([str(binary), '--profile-test'], stdout=output,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            if Path('/usr/bin/sample').exists():
                try:
                    sampled = subprocess.run(['/usr/bin/sample', str(child.pid), '2', '1', '-file', str(sample_path)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=6)
                    sample_status = 'captured' if sampled.returncode == 0 and sample_path.exists() else 'unavailable'
                except subprocess.TimeoutExpired:
                    sample_status = 'sample_timed_out'
            else:
                sample_status = 'tool_unavailable'
            try: os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: code = child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                code = child.wait(timeout=2)
    raw = log.read_bytes()
    lines = raw.decode('utf-8', errors='replace').splitlines()
    complete = 'ALL PASS' in lines
    failures = sum(line.startswith('FAIL ') or line.startswith('FAILURES:') for line in lines)
    passed = not timed_out and code == 0 and complete and failures == 0
    record = dict(status='PASS_COMPLETE_PROFILE' if passed else 'FAIL_INCOMPLETE_OR_FAILED_PROFILE',
        command='--profile-test', timed_out=timed_out, child_exit_code=code,
        completion_footer=complete, pass_lines=sum(line.startswith('PASS ') for line in lines),
        failure_lines=failures, elapsed_seconds=round(time.monotonic()-started,3),
        log_sha256=hashlib.sha256(raw).hexdigest(), last_line=lines[-1] if lines else '',
        stack_sample=sample_status, scope='Complete offscreen logic suite only; not app/native answer acceptance.')
    report_path.write_text(json.dumps(record, indent=2)+'\n')
    print(json.dumps(record))
    return 0 if passed else 124 if timed_out else code if code > 0 else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('log', type=Path)
    parser.add_argument('--timeout', type=float, default=180)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600: parser.error('timeout must be1..600 seconds')
    raise SystemExit(run(args.binary, args.log, args.timeout))

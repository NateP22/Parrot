#!/usr/bin/env python3
"""Actual child success/failure/partial/cancel controls; no app, key or model."""
from pathlib import Path
import importlib.util
import json
import tempfile

path = Path(__file__).with_name('run-profile-test.py')
spec = importlib.util.spec_from_file_location('profile_runner', path)
runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
checks = failures = 0


def check(name, condition):
    global checks, failures
    checks += 1
    if not condition: failures += 1; print('FAIL '+name)


with tempfile.TemporaryDirectory(prefix='parrot-profile-runner-') as directory:
    root = Path(directory)
    cases = [
        ('complete', 'print("PASS fixture",flush=True)\nprint("ALL PASS",flush=True)\n', True),
        ('partial', 'print("PASS only one",flush=True)\n', False),
        ('failed', 'print("ALL PASS",flush=True)\nraise SystemExit(1)\n', False),
        ('timeout', 'import signal,time\ndef stop(*args):\n print("ALL PASS",flush=True)\n raise SystemExit(0)\nsignal.signal(signal.SIGTERM,stop)\nprint("PASS before hang",flush=True)\ntime.sleep(60)\n', False),
    ]
    for name, program, expected in cases:
        child = root/(name+'.py')
        child.write_text('#!/usr/bin/env python3\n'+program); child.chmod(0o700)
        log = root/(name+'.log')
        result = runner.run(child, log, timeout=1 if name=='timeout' else 10)
        report = json.loads(log.with_suffix('.run.json').read_text())
        check(name+' exit gate', (result==0)==expected)
        check(name+' status gate', (report['status']=='PASS_COMPLETE_PROFILE')==expected)
        check(name+' timeout gate', report['timed_out']==(name=='timeout'))
    check('timeout remains failure even if child prints success and exits zero after cancellation', result==124
        and report['child_exit_code']==0 and report['completion_footer'])
print(f'PROFILE RUNNER: {checks} checks; {failures} failures; real synthetic children; no app/native acceptance')
raise SystemExit(0 if failures==0 else 1)

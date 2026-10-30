"""Calculate a single trial from externally reviewed native evidence.

This is an offline calculator, not a capture tool or an evidence authenticator.
The independent native critic must inspect the referenced audio, frames,
calibration, transitions, manifests and visible text. Input assertions and
hash-shaped strings alone never establish native acceptance. No API, ASR,
insert or view-mount timestamp is accepted as the acoustic/visible anchor.
Only synthetic fixtures for this calculator belong in the public repository.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import unicodedata
import uuid

DEADLINE_NS = 2_000_000_000
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_FRAMES = 10_000

class Unverified(ValueError):
    pass

def require(value, reason):
    if not value:
        raise Unverified(reason)

def integer(value):
    require(type(value) is int and 0 <= value < 2**64, 'invalid integer timestamp/count')
    return value

def interval(obj, low, high):
    left, right = integer(obj[low]), integer(obj[high])
    require(left <= right, 'inverted time interval')
    return left, right

def digest(value):
    require(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value), 'missing evidence digest')

def identifier(value):
    require(type(value) is str, 'invalid UUID')
    try:
        require(str(uuid.UUID(value)) == value, 'noncanonical UUID')
    except (ValueError, AttributeError):
        raise Unverified('invalid UUID') from None

def result(verdict, reason, **extra):
    return {'verdict': verdict, 'reason': reason, 'deadline_ns': DEADLINE_NS,
            'native_acceptance': False,
            'evidence_authenticity': 'Requires independent native artifact review; calculator trusts supplied assertions',
            **extra}

def qualify(data):
    """Fail closed; retain exact integer worst-case elapsed, never an average.

    `*_verified` fields are assertions from the independent post-capture review,
    not facts established by this function. The result deliberately cannot mark
    a trial, release or app natively accepted. Trial/question/insight identities
    come from runtime bindings, not expected-answer IDs fed into the app.
    """
    try:
        return _qualify(data)
    except (Unverified, KeyError, TypeError, AttributeError) as error:
        # Do not echo a malformed key/value: input may contain private text.
        reason = str(error) if isinstance(error, Unverified) else 'missing or malformed evidence fields'
        return result('UNVERIFIED', reason)

def _qualify(data):
    require(type(data) is dict and type(data['schema']) is int and data['schema'] == 1, 'unknown schema')
    trial, question = data['trial_id'], data['question_id']
    require(type(trial) is str and 0 < len(trial) <= 128, 'missing trial identity')
    identifier(question)
    clock, capture, oracle = data['clock'], data['capture'], data['oracle']
    require(clock['domain'] == 'mach_absolute_time_ns', 'unconverted or unknown clock')
    require(clock['anchor_kind'] == 'captured_final_voiced_sample', 'anchor is not acoustic speech end')
    require(clock['calibration_verified'] is True, 'calibration not independently verified')
    digest(clock['calibration_sha256'])
    a_low, a_high = interval(clock, 'anchor_low_ns', 'anchor_high_ns')
    require(capture['kind'] == 'visible_own_window', 'offscreen or unknown capture')
    for field in ['owner_verified', 'foreground_verified', 'visibility_verified', 'all_answer_transitions_verified']:
        require(capture[field] is True, 'native window/visibility/transition evidence incomplete')
    digest(capture['frame_manifest_sha256'])
    require(integer(capture['dropped_frames']) == 0 and capture['capped'] is False, 'capture dropped or capped')
    start, end = interval(capture, 'start_ns', 'end_ns')
    require(start <= a_low and end >= a_high, 'capture misses acoustic anchor')
    require(oracle['independent_review_verified'] is True, 'independent review missing')
    digest(oracle['review_sha256'])
    bindings = data['bindings']
    require(type(bindings) is list and 0 < len(bindings) <= MAX_FRAMES, 'missing or oversized binding set')
    by_insight = {}
    for binding in bindings:
        insight = binding['insight_id']
        identifier(insight)
        require(insight not in by_insight, 'duplicate or ambiguous insight binding')
        require(binding['trial_id'] == trial and binding['question_id'] == question, 'stale runtime binding')
        by_insight[insight] = (trial, question)
    frames = data['frames']
    require(type(frames) is list and len(frames) <= MAX_FRAMES, 'malformed or oversized frame sequence')
    first_complete = None
    previous = None
    failure = None
    for frame in frames:
        low, high = interval(frame, 'at_low_ns', 'at_high_ns')
        require(previous is None or low >= previous, 'out-of-order frame evidence')
        previous = low
        require(start <= low <= high <= end, 'frame outside capture interval')
        digest(frame['frame_sha256'])
        require(frame['state'] in ('placeholder', 'partial', 'complete'), 'unknown frame state')
        if frame['state'] == 'placeholder':
            continue
        insight = frame['insight_id']
        require(by_insight.get(insight) == (trial, question)
                and frame['trial_id'] == trial and frame['question_id'] == question, 'stale or unbound displayed answer')
        require(low >= a_high, 'answer predates completed question')
        require(frame['review'] in ('correct', 'wrong', 'unknown'), 'unknown review status')
        require(frame['review'] != 'unknown', 'displayed text not reviewed')
        if frame['review'] == 'wrong':
            failure = 'wrong factual text displayed'
        if frame['state'] == 'complete':
            if first_complete is None:
                first_complete = frame
            require(type(frame['visible_reply']) is str and frame['visible_reply'].strip(), 'missing complete visible reply')
            if len(frame['visible_reply'].split()) > 30:
                failure = 'complete visible reply exceeds thirty words'
            reply = frame['visible_reply'].strip()
            sentences = list(re.finditer(r'''[.!?]+["”’)\]]*(?=\s|$)''', reply))
            if (frame['plain_language_verified'] is not True
                    or any(unicodedata.category(c).startswith('C') and c != '\n' for c in reply)
                    or not 1 <= len(sentences) <= 2
                    or sentences[-1].end() != len(reply)):
                failure = 'reply lacks plain one-or-two-sentence review'
            if frame['conditions_supported'] is not True or frame['citations_verified'] is not True:
                failure = 'answer conditions or evidence not supported'
            # A failed first useful answer stays failed after a correction.
            if frame['useful'] is not True:
                failure = 'complete answer was not useful'
    if failure:
        return result('FAIL', failure)
    if first_complete is None:
        return result('FAIL', 'no complete useful visible answer')
    elapsed = first_complete['at_high_ns'] - a_low
    return result('PASS_CALCULATION' if elapsed <= DEADLINE_NS else 'FAIL',
                  'within deadline on supplied evidence' if elapsed <= DEADLINE_NS else 'complete visible answer was late',
                  elapsed_upper_ns=elapsed,
                  first_complete_frame_sha256=first_complete['frame_sha256'],
                  frames_considered=len(frames))

def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise Unverified('duplicate JSON field')
        obj[key] = value
    return obj

def read_evidence(path):
    """Admit a regular file, then read at most MAX+1 bytes, including races."""
    path = Path(path)
    require(stat.S_ISREG(path.lstat().st_mode), 'evidence is not a regular file')
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, 'rb') as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'evidence is not a regular file')
        raw = stream.read(MAX_JSON_BYTES + 1)
    require(len(raw) <= MAX_JSON_BYTES, 'evidence file too large')
    return raw, json.loads(raw, object_pairs_hook=unique_object)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path, help='Private normalized post-capture evidence JSON')
    args = parser.parse_args()
    try:
        raw, data = read_evidence(args.evidence)
        output = qualify(data)
        output['input_sha256'] = hashlib.sha256(raw).hexdigest()
    except (OSError, ValueError, UnicodeError, RecursionError):
        output = result('UNVERIFIED', 'evidence could not be read or decoded safely')
    print(json.dumps(output, sort_keys=True))
    return 0 if output['verdict'] == 'PASS_CALCULATION' else 1

if __name__ == '__main__':
    raise SystemExit(main())

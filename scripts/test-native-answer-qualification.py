"""Synthetic timing regressions. No app, audio, models or credentials."""
from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import native_answer_qualification as module
from native_answer_qualification import qualify

Q='00000000-0000-4000-8000-000000000001'
I='00000000-0000-4000-8000-000000000002'
H='a'*64
S=1_000_000_000

def fixture():
    return {
        'schema':1,'trial_id':'fictional-trial','question_id':Q,
        'clock':{'domain':'mach_absolute_time_ns','anchor_kind':'captured_final_voiced_sample',
                 'anchor_low_ns':10*S,'anchor_high_ns':10*S,'calibration_verified':True,'calibration_sha256':H},
        'capture':{'kind':'visible_own_window','start_ns':9*S,'end_ns':14*S,
                   'owner_verified':True,'foreground_verified':True,'visibility_verified':True,
                   'all_answer_transitions_verified':True,'frame_manifest_sha256':H,'dropped_frames':0,'capped':False},
        'oracle':{'independent_review_verified':True,'review_sha256':H},
        'bindings':[{'trial_id':'fictional-trial','question_id':Q,'insight_id':I}],
        'frames':[{'at_low_ns':11*S,'at_high_ns':11*S,'frame_sha256':H,
                   'trial_id':'fictional-trial','question_id':Q,'insight_id':I,
                   'state':'complete','review':'correct','useful':True,
                   'visible_reply':'Choose the fictional Export button.',
                   'conditions_supported':True,'citations_verified':True,'plain_language_verified':True}]}

class NativeQualificationTests(unittest.TestCase):
    def not_pass(self,d):self.assertNotEqual(qualify(d)['verdict'],'PASS_CALCULATION')
    def test_good_complete_visible_answer(self):
        r=qualify(fixture());self.assertEqual(r['verdict'],'PASS_CALCULATION')
        self.assertEqual(r['elapsed_upper_ns'],S);self.assertFalse(r['native_acceptance'])
    def test_exact_deadline_and_one_nanosecond_late(self):
        d=fixture();d['frames'][0].update(at_low_ns=12*S,at_high_ns=12*S)
        self.assertEqual(qualify(d)['verdict'],'PASS_CALCULATION')
        d['frames'][0].update(at_low_ns=12*S+1,at_high_ns=12*S+1);self.not_pass(d)
    def test_anchor_and_frame_uncertainty_count(self):
        d=fixture();d['clock']['anchor_low_ns']-=20_000_000
        d['frames'][0].update(at_low_ns=11_990_000_000,at_high_ns=11_990_000_000);self.not_pass(d)
        d=fixture();d['frames'][0].update(at_low_ns=11_990_000_000,at_high_ns=12_010_000_000);self.not_pass(d)
    def test_asr_api_insert_onappear_cannot_replace_acoustic_anchor(self):
        d=fixture();d.update(asr_final_ns=11_800_000_000,request_sent_ns=12_300_000_000,
                            card_inserted_ns=11_500_000_000,view_mounted_ns=11_500_000_000)
        d['frames'][0].update(at_low_ns=12_400_000_000,at_high_ns=12_400_000_000);self.not_pass(d)
    def test_wrong_display_before_or_after_correct_answer_fails(self):
        for at in [10_800_000_000,11_400_000_000]:
            d=fixture();wrong=deepcopy(d['frames'][0]);wrong.update(at_low_ns=at,at_high_ns=at,review='wrong')
            d['frames'].append(wrong);d['frames'].sort(key=lambda x:x['at_low_ns']);self.not_pass(d)
    def test_partial_and_nonuseful_cannot_hide_late_or_bad_first_answer(self):
        d=fixture();d['frames'][0]['state']='partial';self.not_pass(d)
        full=deepcopy(d['frames'][0]);full.update(state='complete',at_low_ns=12_100_000_000,at_high_ns=12_100_000_000)
        d['frames'].append(full);self.not_pass(d)
        d=fixture();later=deepcopy(d['frames'][0]);later.update(at_low_ns=11_400_000_000,at_high_ns=11_400_000_000)
        d['frames'][0]['useful']=False;d['frames'].append(later);self.not_pass(d)
    def test_incomplete_capture_proof_never_passes(self):
        pairs=[(k,False) for k in ['owner_verified','foreground_verified','visibility_verified','all_answer_transitions_verified']]
        pairs+=[('dropped_frames',1),('capped',True),('kind','offscreen'),('frame_manifest_sha256','')]
        for k,v in pairs:
            with self.subTest(k=k):d=fixture();d['capture'][k]=v;self.not_pass(d)
    def test_clock_and_binding_and_oracle_fail_closed(self):
        mutations=[('clock','domain','wall_time'),('clock','anchor_kind','asr_end'),('clock','calibration_verified',False),
                   ('clock','calibration_sha256',''),('oracle','independent_review_verified',False)]
        for section,key,value in mutations:
            with self.subTest(key=key):d=fixture();d[section][key]=value;self.not_pass(d)
        for k,v in [('trial_id','old'),('question_id',I),('insight_id',Q),('review','unknown'),('frame_sha256','')]:
            with self.subTest(k=k):d=fixture();d['frames'][0][k]=v;self.not_pass(d)
        d=fixture();d['bindings'].append(dict(d['bindings'][0],question_id=I));self.not_pass(d)
    def test_conditions_citations_and_thirty_words(self):
        for k,v in [('conditions_supported',False),('citations_verified',False),('visible_reply','word '*31)]:
            with self.subTest(k=k):d=fixture();d['frames'][0][k]=v;self.not_pass(d)
    def test_capture_must_cover_anchor_and_frames(self):
        for k,v in [('start_ns',10*S+1),('end_ns',11*S-1)]:
            d=fixture();d['capture'][k]=v;self.not_pass(d)
    def test_integer_order_and_nonnegative_intervals(self):
        for v in [True,10.0,-1,2**64,None]:
            with self.subTest(v=v):d=fixture();d['clock']['anchor_low_ns']=v;self.not_pass(d)
        d=fixture();d['clock']['anchor_high_ns']=9*S;self.not_pass(d)
        d=fixture();d['frames'][0]['at_high_ns']=10*S;self.not_pass(d)
        d=fixture();d['frames'][0].update(at_low_ns=9*S,at_high_ns=9*S);self.not_pass(d)
        d=fixture();earlier=deepcopy(d['frames'][0]);earlier.update(at_low_ns=10_900_000_000,at_high_ns=10_900_000_000)
        d['frames'].append(earlier);self.not_pass(d)
    def test_missing_answer_and_no_averaging(self):
        d=fixture();d['frames']=[];self.not_pass(d)
        d=fixture();d['frames'][0]['state']='placeholder';self.not_pass(d)
        self.assertEqual(qualify(fixture())['verdict'],'PASS_CALCULATION')
        d=fixture();d['frames'][0].update(at_low_ns=13*S,at_high_ns=13*S);self.not_pass(d)
    def test_three_sentences_hidden_text_and_missing_plainness_review_fail(self):
        for text in ['Choose Export. Select Print. Click Done.', '\u200b', 'Choose\u200b Export.', 'Choose Export']:
            with self.subTest(text=text):d=fixture();d['frames'][0]['visible_reply']=text;self.not_pass(d)
        d=fixture();d['frames'][0]['plain_language_verified']=False;self.not_pass(d)
    def test_two_sentences_with_version_numbers_are_allowed(self):
        d=fixture();d['frames'][0]['visible_reply']='In 3.169.0, choose Export. Then select Print.'
        self.assertEqual(qualify(d)['verdict'],'PASS_CALCULATION')
    def test_input_reader_rejects_nonregular_and_oversized_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);fifo=root/'pipe';os.mkfifo(fifo)
            for path in [root,fifo]:
                with self.subTest(path=path.name),self.assertRaises(ValueError):module.read_evidence(path)
            large=root/'large.json';large.write_bytes(b' '*65)
            with patch.object(module,'MAX_JSON_BYTES',64),self.assertRaises(ValueError):module.read_evidence(large)
    def test_cli_malformed_nested_duplicate_or_private_text_is_not_echoed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'evidence.json'
            for raw in [b'['*2000+b']'*2000,b'{"schema":1,"schema":1}',b'PRIVATE-TEST-CONTENT']:
                path.write_bytes(raw)
                r=subprocess.run([sys.executable,str(Path(module.__file__)),str(path)],capture_output=True,text=True,timeout=3)
                self.assertEqual(r.returncode,1);self.assertFalse(r.stderr)
                self.assertEqual(json.loads(r.stdout)['verdict'],'UNVERIFIED')
                self.assertNotIn('PRIVATE-TEST-CONTENT',r.stdout)

if __name__=='__main__':unittest.main()

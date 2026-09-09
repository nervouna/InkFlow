"""Query fixtures use the current Swift writer DDL; full acceptance also reads its DB."""
import argparse
import contextlib
import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import time
import threading
from unittest import mock
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / '.agents/skills/inkflow-quality-analysis/scripts/quality.py'
ENGINE_DB = ROOT / 'build/quality-evidence/engine-controller.sqlite3'
SOURCE = ROOT / 'macOS/Sources/QualityStore.swift'
DDL = dict(re.findall(r'"(\w+)": """\s*(CREATE TABLE .*?)\s*"""', SOURCE.read_text(), re.S))
STAMP = '2026-09-06T16:00:00.000Z'
OPS = dict(keypresses=5, pageRequests=1, pageTurns=1, candidateMoves=2, preeditEdits=0)


def insert(db, table, **values):
    db.execute(f'INSERT INTO {table} ({",".join(values)}) VALUES ({",".join("?" for _ in values)})', list(values.values()))


def empty_db(path):
    db = sqlite3.connect(path)
    db.execute('PRAGMA foreign_keys=ON')
    db.execute('PRAGMA application_id=1229345073')
    db.execute('PRAGMA user_version=1')
    for sql in DDL.values():
        db.execute(sql)
    return db


def fixture(path):
    db = empty_db(path)
    insert(db, 'recording_runs', id='run', started_at=STAMP, status='closed', engine_version='1.17.0',
           build_metadata_json='{}', metric_rule_version=1,
           stats_json=json.dumps(dict(written=21, submitted=30, droppedBusy=2, droppedQueue=3,
                                      droppedOversized=1, errors=1, truncatedEnvelopes=1)))
    for rid, fp in [('rev1', 'fingerprint-A'), ('rev2', 'fingerprint-A'), ('rev3', 'fingerprint-B')]:
        insert(db, 'config_revisions', id=rid, fingerprint=fp, created_at=STAMP,
               applied_config_json='{}', build_metadata_json='{}', engine_version='1.17.0', metric_rule_version=1)

    def add(cid, *, outcome='committed', regular=1, issued=1, presentation='candidates_requested',
            first=True, index=0, chosen='使', kind='chinese', caret=3, context='', custom=0,
            revision='rev1', rank=4, prefix_valid=True, truncated=0):
        insert(db, 'compositions', id=cid, run_id='run', started_at=STAMP, ended_at=STAMP,
               app_bundle_id="app'quoted", outcome='committed' if outcome == 'committed' else 'unknown',
               operations_json=json.dumps(OPS), page_history_truncated=truncated, dropped_page_count=2*truncated)
        commit_id = f'commit-{cid}' if outcome == 'committed' else None
        if commit_id:
            insert(db, 'commits', id=commit_id, composition_id=cid, issued_at=STAMP, text=chosen,
                   kind='candidate' if regular else 'punctuation', insertion_issued=issued)
        page = dict(generation=7, rawInput='shi', caret=caret, selectedPrefix='', selectedPrefixValid=prefix_valid,
                    precedingContext=context, configurationRevisionID=revision, configuration={},
                    page=0 if rank == 1 else 1, pageSize=3, highlightedDisplayIndex=0,
                    presentation=presentation, capturedAt=STAMP,
                    candidates=[dict(text=chosen, displayIndex=0, displayRank=rank,
                                     nativeIndex=0 if rank == 1 else 1, nativeRank=1 if rank == 1 else 5)])
        first_page = dict(page, page=0, candidates=[dict(text='是', displayIndex=0, displayRank=1, nativeIndex=0, nativeRank=1)])
        insert(db, 'candidate_decisions', id=f'decision-{cid}', composition_id=cid, config_revision_id=revision,
               commit_id=commit_id, occurred_at=STAMP, sequence=0, trigger='space' if regular else 'punctuation',
               outcome=outcome, selected_display_index=index, selected_text=chosen, text_kind=kind,
               snapshot_json=json.dumps(page, ensure_ascii=False), first_page_json=json.dumps(first_page) if first else None,
               visited_pages_json='[]', page_history_truncated=truncated, dropped_page_count=2*truncated,
               operations_json=json.dumps(OPS), regular_ranked_selection=regular, matches_custom_phrase=custom,
               unknown_rank_reason='ambiguous_candidate_text' if index is None else None)

    add('a'); add('b', revision='rev2'); add('c', truncated=1)
    add('d', chosen='是', rank=1)
    add('e', first=False)
    add('f', index=None)
    add('g', outcome='reverted'); add('h', outcome='edited'); add('i', outcome='cancelled')
    add('j', regular=0); add('k', issued=0); add('l', presentation='not_shown')
    add('m', prefix_valid=False); add('n', chosen='😀', kind='emoji')
    add('o', caret=2); add('p', context='前文'); add('q', custom=1); add('r', revision='rev3')
    add('s', outcome='unknown'); add('t', outcome='interrupted')
    insert(db, 'compositions', id='raw-only', run_id='run', started_at=STAMP, ended_at=STAMP,
           app_bundle_id='other.app', outcome='committed', operations_json=json.dumps(OPS),
           page_history_truncated=0, dropped_page_count=0)
    insert(db, 'commits', id='raw-commit', composition_id='raw-only', issued_at=STAMP, text='raw',
           kind='raw_return', insertion_issued=1)
    db.commit()
    db.close()


class QueryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('quality', SCRIPT)
        cls.quality = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        spec.loader.exec_module(cls.quality)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='inkflow-query-')
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'fixture ?#.sqlite3'
        fixture(self.db)

    def run_cli(self, *args, db=None, success=True):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = self.quality.main([*args, '--db', str(db or self.db)])
        self.assertEqual(code, 0 if success else 2, stderr.getvalue())
        return stdout.getvalue() if success else stderr.getvalue()

    def result(self, command='summary', *args, db=None):
        return json.loads(self.run_cli(command, *args, '--format', 'json', db=db))

    def test_summary_exact_denominators_and_ranks(self):
        result = self.result()
        self.assertEqual(result['coverage']['compositions'], 21)
        self.assertEqual(result['coverage']['commits'], 16)
        self.assertEqual(result['coverage']['decisions'], 20)
        group = next(g for g in result['groups'] if g['fingerprint']=='fingerprint-A'
                     and g['text_kind']=='chinese' and g['presentation']=='candidates_requested')
        expected = dict(decisions=17, committed=12, unknown=1, reverted=1, edited=1, cancelled=1,
                        interrupted=1, regular_not_issued=1, valid=10, known_rank=9, unknown_rank=1,
                        comparable=7, first_page_unavailable=2, top1_selected=1, top1_matches=1,
                        truncated=1, dropped_page_count=2)
        for key, value in expected.items():
            self.assertEqual(group[key], value, key)
        self.assertAlmostEqual(group['top1_rate'], 1/9)
        self.assertAlmostEqual(group['top1_match_rate'], 1/7)
        self.assertEqual(group['mean_display_rank'], 33/9)
        ranks = [r for r in result['rank_counts'] if r['fingerprint']=='fingerprint-A'
                 and r['text_kind']=='chinese' and r['presentation']=='candidates_requested']
        self.assertEqual([(r['display_rank'],r['count']) for r in ranks], [(1,1),(4,8)])
        hidden = next(g for g in result['groups'] if g['presentation']=='not_shown')
        self.assertEqual(hidden['regular_issued'], 1)
        self.assertEqual(hidden['valid'], 0)
        self.assertIsNone(hidden['top1_rate'])
        self.assertEqual(result['recording_runs']['scope'], 'whole_db_lifetime_unfiltered')
        self.assertEqual(result['recording_runs']['totals']['droppedQueue'], 3)

    def test_issues_grouping_and_inspect_ids(self):
        result = self.result('ranking-issues')
        self.assertEqual(len(result['issues']), 1)
        issue = result['issues'][0]
        self.assertEqual(issue['occurrences'], 3)
        self.assertEqual(issue['mean_display_rank'], 4)
        self.assertEqual(issue['mean_native_rank'], 5)
        self.assertEqual(issue['page_turns'], 3)
        self.assertEqual(issue['candidate_moves'], 6)
        self.assertEqual(issue['composition_ids'], ['a','b','c'])
        self.assertEqual(issue['first_page_top1'], '是')
        self.assertEqual(len(self.result('ranking-issues','--min-count','1')['issues']), 6)
        self.assertEqual(len(self.result('ranking-issues','--min-count','1','--limit','2')['issues']), 2)
        for cid in issue['composition_ids']:
            data = self.result('inspect', cid)
            self.assertEqual(data['composition']['id'],cid)
            self.assertEqual(data['decisions'][0]['snapshot']['candidates'][0]['text'], '使')
            self.assertIsNone(data['decisions'][0]['snapshot']['candidates'][0].get('source'))

    def test_filters_and_parameter_binding(self):
        filtered = self.result('summary', '--app', "app'quoted", '--config','fingerprint-A','--kind','emoji')
        self.assertEqual(filtered['coverage']['compositions'], 1)
        self.assertEqual(filtered['coverage']['decisions'], 1)
        self.assertEqual(filtered['groups'][0]['text_kind'], 'emoji')
        self.assertEqual(filtered['recording_runs']['totals']['droppedQueue'], 3)
        self.assertEqual(self.result('summary','--app', "x' OR 1=1 --")['coverage']['compositions'], 0)
        self.assertEqual(self.result('summary','--config','fingerprint')['coverage']['compositions'], 0)
        self.assertEqual(self.result('summary','--since',STAMP)['coverage']['compositions'],21)
        self.assertEqual(self.result('summary','--until',STAMP)['coverage']['compositions'],0)
        self.assertEqual(self.result('summary','--since','2026-09-06T16:00:00.000001Z')['coverage']['compositions'],0)
        self.assertEqual(self.result('summary','--until','2026-09-06T16:00:00.000001Z')['coverage']['compositions'],21)
        self.assertEqual(self.result('summary','--since','2026-09-06T15:59:59.999999Z')['coverage']['compositions'],21)
        self.assertEqual(self.result('summary','--until','2026-09-06T15:59:59.999999Z')['coverage']['compositions'],0)
        self.assertEqual(self.result('summary','--since','2026-09-07T00:00:00+08:00')['coverage']['compositions'],21)
        self.assertIn('does not match',self.run_cli('inspect','a','--kind','emoji',success=False))

    def test_local_calendar_date_and_invalid_arguments(self):
        previous = os.environ.get('TZ')
        try:
            os.environ['TZ']='Asia/Taipei'; time.tzset()
            self.assertEqual(self.quality.timestamp('2026-09-07'),'2026-09-06T16:00:00.000Z')
        finally:
            if previous is None: os.environ.pop('TZ',None)
            else: os.environ['TZ']=previous
            time.tzset()
        for args in [('summary','--since','nonsense'),('summary','--since','2026-09-07T12:00:00'),
                     ('summary','--since',STAMP,'--until',STAMP),('ranking-issues','--min-count','0')]:
            self.run_cli(*args,success=False)

    def test_formats_are_lossless_and_readable(self):
        for args in [('summary',),('ranking-issues','--min-count','1'),('inspect','n')]:
            table = self.run_cli(*args)
            self.assertTrue(table.strip())
            exported = list(csv.DictReader(io.StringIO(self.run_cli(*args,'--format','csv'))))
            self.assertTrue(exported)
            self.assertEqual(set(exported[0]), {'path','value'})
        self.assertIn('😀',self.run_cli('inspect','n'))
        self.assertIn('N/A',self.run_cli('summary','--kind','unknown'))
        self.assertIn('fingerprint-A',self.run_cli('summary'))

    def test_empty_missing_schema_and_readonly(self):
        empty = Path(self.temp.name)/'empty.sqlite3'; empty_db(empty).close()
        result = self.result(db=empty)
        self.assertEqual(result['coverage']['valid'],0)
        self.assertIsNone(result['coverage']['top1_rate'])
        self.assertEqual(result['groups'],[])
        missing=Path(self.temp.name)/'missing.sqlite3'
        self.assertIn('does not exist',self.run_cli('summary',db=missing,success=False))
        self.assertFalse(missing.exists())
        before=hashlib.sha256(self.db.read_bytes()).hexdigest()
        with contextlib.closing(self.quality.connect(self.db)) as connection:
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("DELETE FROM compositions")
        self.result(); self.result('inspect','a')
        self.assertEqual(before,hashlib.sha256(self.db.read_bytes()).hexdigest())
        for statement in ['PRAGMA user_version=2','DROP TABLE candidate_decisions']:
            bad=Path(self.temp.name)/('bad'+str(len(statement))+'.sqlite3')
            db=empty_db(bad); db.execute(statement); db.close()
            self.assertIn('incompatible',self.run_cli('summary',db=bad,success=False))
        self.assertIn('not found',self.run_cli('inspect','missing',success=False))

    def test_incomplete_evidence_bounded_ids_and_concurrent_reader(self):
        db = sqlite3.connect(self.db)
        self.addCleanup(db.close)
        # Corrupted or absent rank evidence never promotes a candidate to rank one.
        db.execute("UPDATE candidate_decisions SET selected_text='different' WHERE composition_id='a'")
        db.execute("UPDATE candidate_decisions SET first_page_json=json_set(first_page_json,'$.generation',99) WHERE composition_id='b'")
        db.commit()
        result = self.result('ranking-issues','--min-count','1')
        normal = next(x for x in result['issues'] if x['fingerprint']=='fingerprint-A'
                      and x['caret']==3 and x['preceding_context']=='' and x['text_kind']=='chinese'
                      and x['matches_custom_phrase']==0)
        self.assertEqual(normal['composition_ids'],['c'])
        # Duplicate one valid envelope into six separate compositions to exceed the sample bound.
        for index in range(6):
            cid=f'copy-{index}'
            source=dict(zip([x[1] for x in db.execute('PRAGMA table_info(compositions)')],
                            db.execute("SELECT * FROM compositions WHERE id='c'").fetchone()))
            source['id']=cid; insert(db,'compositions',**source)
            source=dict(zip([x[1] for x in db.execute('PRAGMA table_info(commits)')],
                            db.execute("SELECT * FROM commits WHERE composition_id='c'").fetchone()))
            source.update(id='commit-'+cid,composition_id=cid); insert(db,'commits',**source)
            source=dict(zip([x[1] for x in db.execute('PRAGMA table_info(candidate_decisions)')],
                            db.execute("SELECT * FROM candidate_decisions WHERE composition_id='c'").fetchone()))
            source.update(id='decision-'+cid,composition_id=cid,commit_id='commit-'+cid)
            insert(db,'candidate_decisions',**source)
        db.commit()
        issue=self.result('ranking-issues')['issues'][0]
        self.assertEqual(issue['occurrences'],7)
        self.assertEqual(len(issue['composition_ids']),5)
        # A reserved rollback-journal writer may coexist with this read-only query.
        db.execute('BEGIN IMMEDIATE')
        db.execute("UPDATE compositions SET app_bundle_id='uncommitted' WHERE id='c'")
        self.assertEqual(self.result('inspect','c')['composition']['app_bundle_id'],"app'quoted")
        db.rollback()

    def test_snapshot_consistency_during_intervening_write(self):
        ready, committed = threading.Event(), threading.Event()
        failures=[]

        def writer():
            try:
                with sqlite3.connect(self.db,timeout=3) as db:
                    db.execute("UPDATE candidate_decisions SET outcome='unknown' WHERE composition_id='a'")
                    ready.set()
                committed.set()
            except Exception as error:
                failures.append(error)
                ready.set()

        original=self.quality.rows
        started=False
        thread=threading.Thread(target=writer)

        def read_rows(db, sql, parameters=None):
            nonlocal started
            result=original(db,sql,parameters)
            if not started:
                started=True
                thread.start()
                self.assertTrue(ready.wait(2),'writer did not reach commit')
                self.assertFalse(committed.is_set(),'writer committed through the active read snapshot')
            return result

        with mock.patch.object(self.quality,'rows',side_effect=read_rows):
            result=self.result()
        thread.join(4)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures,[])
        self.assertTrue(committed.is_set())
        self.assertEqual(result['coverage']['valid'],12)
        self.assertEqual(sum(g['valid'] for g in result['groups']),12)
        self.assertEqual(self.result()['coverage']['valid'],11)

    def test_analysis_schema_extensions_remain_compatible(self):
        with sqlite3.connect(self.db) as db:
            db.execute('CREATE VIEW analysis_view AS SELECT id FROM compositions')
            db.execute('CREATE INDEX analysis_index ON candidate_decisions(text_kind)')
            db.execute('ANALYZE')
        self.assertEqual(self.result()['coverage']['compositions'],21)

    def test_timing_legacy_unknown_and_one_snapshot_per_composition(self):
        legacy = self.result('timing')
        self.assertEqual(legacy['coverage']['unavailable'], 21)
        self.assertEqual(legacy['coverage']['timing_v1'], 0)
        self.assertIsNone(legacy['durations']['ended']['postEditWait']['p50'])
        samples = [dict(sequence=0, offset=0, kind='typing', isRepeat=False),
                   dict(sequence=1, offset=0.2, interval=0.2, kind='typing', isRepeat=False),
                   dict(sequence=256, offset=4, interval=0.4, kind='ai_tab', isRepeat=True)]
        value = dict(version=1, keySamples=samples, droppedKeyCount=254, endedOffset=4,
                     postEditWait=0.8, observedVisibleDuration=0.5, phaseWait=0.3,
                     phaseObservedVisibleDuration=0.2, visibilityObservationInterval=0.1)
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE compositions SET operations_json=? WHERE id='a'", (json.dumps(dict(OPS, timing=value)),))
            # Decision snapshots deliberately contain the same data. Never sum these copies.
            db.execute('UPDATE candidate_decisions SET operations_json=?', (json.dumps(dict(OPS, timing=value)),))
            unfinished = dict(value)
            unfinished.pop('endedOffset')
            unfinished.pop('observedVisibleDuration')
            unfinished['keySamples'] = []
            unfinished['droppedKeyCount'] = 0
            db.execute("UPDATE compositions SET operations_json=? WHERE id='b'", (json.dumps(dict(OPS, timing=unfinished)),))
            db.execute("UPDATE compositions SET operations_json=? WHERE id='c'", (json.dumps(dict(OPS, timing=dict(version=2))),))
        result = self.result('timing')
        self.assertEqual(result['scope'], 'composition_operations_once')
        self.assertEqual(result['coverage'], dict(compositions=21, timing_v1=2, unavailable=18, unsupported_version=1,
                                                ended=1, unfinished=1, truncated_compositions=1, dropped_keys=254, retained_keys=3))
        intervals = result['key_intervals']['all']
        self.assertEqual(intervals['count'], 2)
        self.assertEqual(intervals['unknown'], 1)
        self.assertAlmostEqual(intervals['p50'], 0.3)
        self.assertAlmostEqual(intervals['p95'], 0.39)
        self.assertEqual(result['key_intervals']['by_category_repeat'][0]['kind'], 'ai_tab')
        self.assertEqual(result['key_intervals']['by_category_repeat'][0]['intervals']['p50'], 0.4)
        self.assertEqual(result['durations']['ended']['observedVisibleDuration']['p50'], 0.5)
        self.assertIsNone(result['durations']['unfinished_observations']['observedVisibleDuration']['p50'])
        self.assertEqual(self.result('timing', '--kind', 'emoji')['coverage']['compositions'], 1)
        self.assertEqual(self.result('timing', '--kind', 'emoji')['coverage']['timing_v1'], 0)
        self.assertNotIn('rawInput', json.dumps(result))

    def test_timing_actual_controller_writer(self):
        if not ENGINE_DB.exists():
            if REQUIRE_ENGINE:
                self.fail('Run test-quality-capture.sh first')
            self.skipTest('Actual controller DB absent')
        result = self.result('timing', db=ENGINE_DB)
        self.assertEqual(result['coverage']['compositions'], 40)
        self.assertGreater(result['coverage']['timing_v1'], 0)
        self.assertGreater(result['key_intervals']['all']['count'], 0)
        # This engine/controller fixture does not observe native panel visibility.
        self.assertIsNone(result['visibility_observation_interval']['p50'])
        self.assertEqual(result['visibility_observation_interval']['count'], 0)

    def test_actual_engine_schema_and_controller_cohort(self):
        if not ENGINE_DB.exists():
            if REQUIRE_ENGINE:
                self.fail('Full acceptance requires engine-controller.sqlite3; run test-quality-capture.sh first')
            self.skipTest('Standalone fixture mode: actual engine DB is absent')
        db=sqlite3.connect(ENGINE_DB.as_uri()+'?mode=ro',uri=True)
        self.addCleanup(db.close)
        actual=dict(db.execute("SELECT name,sql FROM sqlite_master WHERE type='table'"))
        self.assertEqual({k:' '.join(v.split()) for k,v in actual.items()},
                         {k:' '.join(v.split()) for k,v in DDL.items()})
        result=self.result(db=ENGINE_DB)
        # The deferred-toggle then panel-selection fixture adds one valid composition,
        # decision and issued candidate commit; the toggle itself adds no decision.
        self.assertEqual([result['coverage'][x] for x in ['compositions','decisions','commits']],[40,36,37])
        self.assertEqual(result['coverage']['valid'],28)
        self.assertEqual(result['coverage']['regular_issued'],29)
        self.assertEqual(result['coverage']['regular_not_issued'],1)
        # Three fixtures explicitly select emoji; positional selections may also be emoji as the corpus changes.
        self.assertGreaterEqual(sum(g['valid'] for g in result['groups'] if g['text_kind']=='emoji'),3)
        cohort=self.result('summary','--app','inkflow.recording-client',db=ENGINE_DB)
        self.assertGreater(cohort['coverage']['valid'],0)
        issues=self.result('ranking-issues','--min-count','1',db=ENGINE_DB)
        self.assertGreater(len(issues['issues']),0)
        selected=issues['issues'][0]['composition_ids'][0]
        inspected=self.result('inspect',selected,db=ENGINE_DB)
        self.assertTrue(inspected['commits'][0]['insertion_issued'])
        self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--require-engine',action='store_true')
    options,remaining=parser.parse_known_args()
    REQUIRE_ENGINE=options.require_engine
    unittest.main(argv=[sys.argv[0],*remaining],verbosity=2)
else:
    REQUIRE_ENGINE=False

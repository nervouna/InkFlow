"""Read-only CLI acceptance using synthetic DDL and actual Swift writer fixtures."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'macOS/Tools/ai-statistics.py'
DDL = dict(re.findall(r'"(\w+)": """\s*(CREATE TABLE .*?)\s*"""',
                     (ROOT / 'macOS/Sources/AIStatisticsStore.swift').read_text(), re.S))
STAMP = 1788710400.125
NOW = STAMP + 10
SECRET = 'synthetic-sample-body-only'


def insert(db, table, **values):
    db.execute(f'INSERT INTO {table} ({",".join(values)}) VALUES ({",".join("?" for _ in values)})', list(values.values()))


def fixture(path):
    with contextlib.closing(sqlite3.connect(path)) as db, db:
        db.execute('PRAGMA application_id=1229340977')
        db.execute('PRAGMA user_version=1')
        for sql in DDL.values():
            db.execute(sql)
        insert(db, 'recording_runs', id='run', started_at=STAMP, status='running',
               counters_json=json.dumps(dict(submitted=70, written=65, droppedQueue=3, errors=1)))
        insert(db, 'configurations', id='config', snapshot_json=json.dumps(dict(requestedModel='model-A', maxTokens=256)),
               pricing_json=json.dumps(dict(inputPerMillion=2, outputPerMillion=4)), pricing_version=1, build_identity='synthetic')

        def attempt(id, kinds, **changes):
            values = dict(id=id, run_id='run', configuration_id='config', scheduled_at=STAMP,
                          provider='https://fixture.example', requested_model='model-A', strategy_version='strategy-A',
                          app_bundle_id="app'quoted", last_edit_to_schedule_ms=500, last_edit_to_dispatch_ms=1000)
            values.update(changes)
            insert(db, 'attempts', **values)
            for kind, elapsed in kinds.items():
                insert(db, 'attempt_events', attempt_id=id, kind=kind, occurred_at=STAMP+elapsed/1000,
                       elapsed_ms=elapsed, reason='inputChanged' if kind == 'uiEnded' else ('network' if kind == 'serviceFailed' else None))

        network = dict(scheduled=0, dispatched=500, transportStarted=510, responseObserved=610,
                       transportEnded=620, serviceReturned=625, shown=650, uiEnded=900)
        adopted = dict(network, adoptionRequested=800, insertionIssued=810, insertionReturned=820)
        attempt('a', adopted, composition_id='ordinary', dispatch_composition_id='ordinary', usage_state='valid',
                prompt_tokens=250, completion_tokens=50, cached_tokens=100, reasoning_tokens=10, total_tokens=300,
                estimated_cost='0.00052', currency='USD', cost_state='known', matches_first_candidate=1,
                matches_candidate_page=1, suggestion_length=2, candidate_coverage='current_page', response_truncated=1,
                preceding_available=1, following_available=0)
        attempt('b', network, usage_state='valid', prompt_tokens=100, completion_tokens=10,
                estimated_cost='0.00024', currency='USD', cost_state='known', matches_first_candidate=0, matches_candidate_page=0)
        attempt('c', adopted, usage_state='valid', estimated_cost='0.002', currency='EUR', cost_state='known')
        attempt('d', adopted, usage_state='partial', prompt_tokens=20, cost_state='usage_partial')
        attempt('e', dict(scheduled=0, dispatched=500, transportStarted=510, transportEnded=700, serviceFailed=710, uiEnded=720),
                usage_state='invalid', prompt_tokens=999, cost_state='usage_invalid')
        attempt('f', dict(scheduled=0, uiEnded=100))
        attempt('g', dict(scheduled=0, dispatched=500, transportStarted=510))
        attempt('h', dict(scheduled=0), recovery_state='interrupted', requested_model='model-B',
                strategy_version='strategy-B', app_bundle_id='other.app', scheduled_at=STAMP+0.000001)
        # Deliberately missing denominator evidence must not inflate either rate.
        attempt('i', dict(scheduled=0, insertionIssued=100, uiEnded=110), recovery_state='closed_incomplete')
        for id, expires in [('a', NOW+100), ('b', NOW)]:
            insert(db, 'samples', attempt_id=id, expires_at=expires,
                   input_json=json.dumps(dict(preceding=SECRET, following='', pinyin='ni', selectedPrefix='')),
                   candidates_json=json.dumps([SECRET]), response_text=SECRET)


class QueryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('ai_statistics_query', SCRIPT)
        cls.query = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        spec.loader.exec_module(cls.query)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='inkflow-ai-query-')
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'fixture ?#.sqlite3'
        fixture(self.db)

    def cli(self, *args, db=None, success=True):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), mock.patch.object(self.query, 'now_epoch', return_value=NOW):
            code = self.query.main([*args, '--db', str(db or self.db), '--format', 'json'])
        self.assertEqual(code, 0 if success else 2, stderr.getvalue())
        return json.loads(stdout.getvalue()) if success else stderr.getvalue()

    def test_counts_denominators_and_statuses(self):
        result = self.cli('summary')
        self.assertEqual(result['counts']['attempts'], 9)
        self.assertEqual(result['counts']['transportStarted'], 6)
        self.assertEqual(result['counts']['shown'], 4)
        self.assertEqual(result['counts']['insertionIssued'], 4)
        self.assertEqual(result['rates']['display_adoption'], dict(numerator=3, denominator=4, value=0.75))
        self.assertEqual(result['rates']['request_conversion'], dict(numerator=3, denominator=6, value=0.5))
        self.assertEqual(result['rates']['display_rate']['numerator'], 4)
        self.assertEqual(result['completion']['complete'], 6)
        self.assertEqual(result['completion']['pending'], 1)
        self.assertEqual(result['completion']['interrupted'], 1)
        self.assertEqual(result['completion']['closed_incomplete'], 1)
        self.assertEqual(result['completion']['service_failed'], 1)
        self.assertEqual(result['completion']['service_failure_reasons'], dict(network=1))
        self.assertEqual(result['recording_runs']['scope'], 'whole_db_lifetime_unfiltered')
        self.assertEqual(result['recording_runs']['counter_totals']['droppedQueue'], 3)
        self.assertNotIn(SECRET, json.dumps(result))

    def test_usage_cost_cohorts_and_quantiles(self):
        result = self.cli('summary')
        self.assertEqual(result['usage']['states']['valid'], 3)
        self.assertEqual(result['usage']['tokens']['prompt_tokens'], dict(known_attempts=3, total=370))
        costs = {r['currency']: r for r in result['cost']['currencies']}
        self.assertEqual(costs['USD']['known_cost'], '0.00076')
        self.assertEqual(costs['USD']['adopted_request_cost'], '0.00052')
        self.assertEqual(costs['USD']['cost_per_issued_adoption'], '0.00076')
        self.assertEqual(costs['USD']['mean_adopted_request_cost'], '0.00052')
        self.assertEqual(costs['EUR']['known_cost'], '0.002')
        self.assertEqual(result['cost']['unknown_attempts'], 6)
        self.assertEqual(result['latency_ms']['network_to_response']['p95'], 100)
        self.assertEqual(result['latency_ms']['schedule_to_first_show']['p50'], 650)
        self.assertEqual(result['latency_ms']['last_edit_to_first_show']['p50'], 1150)
        self.assertEqual(result['comparison']['matches_first_candidate'], dict(known=2, true=1, false=1, unknown=7))

    def test_filters_limits_and_empty_cohort(self):
        self.assertEqual(self.cli('summary', '--app', "app'quoted", '--model', 'model-A', '--strategy', 'strategy-A')['counts']['attempts'], 8)
        empty = self.cli('summary', '--model', "x' OR 1=1 --")
        self.assertEqual(empty['counts']['attempts'], 0)
        self.assertIsNone(empty['rates']['display_adoption']['value'])
        self.assertIsNone(empty['usage']['tokens']['prompt_tokens']['total'])
        self.assertIsNone(empty['latency_ms']['network_to_response']['p95'])
        self.assertEqual(empty['recording_runs']['counter_totals']['droppedQueue'], 3)
        self.assertEqual(len(self.cli('list', '--limit', '2')['attempts']), 2)
        self.assertNotIn(SECRET, json.dumps(self.cli('list')))
        from datetime import datetime, timezone
        boundary = datetime.fromtimestamp(STAMP, timezone.utc).isoformat()
        after = datetime.fromtimestamp(STAMP+0.000001, timezone.utc).isoformat()
        self.assertEqual(self.cli('summary', '--since', boundary)['counts']['attempts'], 9)
        self.assertEqual(self.cli('summary', '--until', boundary)['counts']['attempts'], 0)
        self.assertEqual(self.cli('summary', '--since', after)['counts']['attempts'], 1)
        self.assertEqual(self.cli('summary', '--until', after)['counts']['attempts'], 8)
        self.cli('summary', '--since', boundary, '--until', boundary, success=False)
        self.cli('list', '--limit', '0', success=False)
        self.cli('list', '--limit', '1001', success=False)

    def test_retention_inspect_and_unknown_context(self):
        retained = self.cli('inspect', 'a')
        self.assertEqual(retained['sample']['state'], 'retained')
        self.assertEqual(retained['sample']['input']['preceding'], SECRET)
        self.assertEqual(retained['attempt']['following_available'], 0)
        self.assertEqual(retained['sample']['input']['following'], '')
        expired = self.cli('inspect', 'b')
        self.assertEqual(expired['sample']['state'], 'expired')
        self.assertNotIn(SECRET, json.dumps(expired))
        self.assertEqual(self.cli('inspect', 'c')['sample']['state'], 'absent')
        self.assertEqual(self.cli('summary')['retention']['states'], dict(retained=1, expired=1, absent=7))
        self.cli('inspect', 'unknown', success=False)
        self.cli('inspect', 'a', '--model', 'model-B', success=False)

    def test_readonly_identity_and_byte_preservation(self):
        before = self.db.read_bytes()
        before_files = sorted(p.name for p in self.db.parent.iterdir())
        for command in [('summary',), ('list',), ('inspect', 'a')]:
            self.cli(*command)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in self.db.parent.iterdir()), before_files)
        with contextlib.closing(self.query.connect(self.db)) as db:
            self.assertEqual(db.execute('PRAGMA query_only').fetchone()[0], 1)
            with self.assertRaises(sqlite3.OperationalError):
                db.execute('DELETE FROM samples')
        missing = self.db.parent / 'missing.sqlite3'
        self.cli('summary', db=missing, success=False)
        self.assertFalse(missing.exists())
        for mutation in ['PRAGMA application_id=0', 'PRAGMA user_version=2', 'ALTER TABLE samples DROP COLUMN response_text', 'CREATE TABLE foreign_table(x)']:
            other = self.db.parent / 'foreign.sqlite3'
            other.write_bytes(before)
            with contextlib.closing(sqlite3.connect(other)) as db, db:
                db.execute(mutation)
            original = other.read_bytes()
            self.cli('summary', db=other, success=False)
            self.assertEqual(other.read_bytes(), original)

    def test_exact_optional_composition_join(self):
        spec = importlib.util.spec_from_file_location('quality_query_fixtures', ROOT / 'macOS/Tests/QualityQueryTests.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        quality_path = self.db.parent / 'quality.sqlite3'
        module.fixture(quality_path)
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE attempts SET composition_id='a', dispatch_composition_id='a' WHERE id='a'")
        result = self.cli('inspect', 'a', '--quality-db', str(quality_path))
        self.assertEqual(result['ordinary_compositions'][0]['composition']['id'], 'a')
        self.assertEqual(result['ordinary_compositions'][0]['associations'], ['scheduled', 'dispatched'])
        self.assertNotIn('decisions', result['ordinary_compositions'][0])
        self.assertEqual(self.cli('inspect', 'c', '--quality-db', str(quality_path))['ordinary_compositions'], [])

    def test_actual_swift_writer_fixtures(self):
        root = WRITER_DIR.resolve() if WRITER_DIR is not None else None
        if root is None:
            self.skipTest('Pass --writer-dir from test-ai-statistics.sh evidence for actual writer acceptance')
        result = self.cli('summary', db=root / 'ai-statistics.sqlite3')
        usd = next(r for r in result['cost']['currencies'] if r['currency'] == 'USD')
        self.assertEqual(usd['known_cost'], '0.00052')
        self.assertEqual(result['retention']['states']['retained'], 0)
        retained_summary = self.cli('summary', db=root / 'retained-fixture.sqlite3')
        self.assertIsNone(retained_summary['cost']['currencies'][0]['cost_per_issued_adoption'])
        retained = self.cli('list', db=root / 'retained-fixture.sqlite3')['attempts'][0]
        inspected = self.cli('inspect', retained['id'], db=root / 'retained-fixture.sqlite3')
        # These synthetic timestamps may be expired at the query's real clock.
        with contextlib.closing(sqlite3.connect((root / 'retained-fixture.sqlite3').as_uri()+'?mode=ro', uri=True)) as db:
            expiry = db.execute('SELECT expires_at FROM samples').fetchone()[0]
        with mock.patch.object(self.query, 'now_epoch', return_value=expiry-1):
            with contextlib.closing(self.query.connect(root / 'retained-fixture.sqlite3')) as db:
                args = self.query.parser().parse_args(['inspect', retained['id']])
                inspected = self.query.inspect(db, args)
        self.assertEqual(inspected['sample']['response_text'], 'retained-result')
        self.assertEqual(inspected['configuration']['pricing_version'], 1)
        self.assertEqual(inspected['attempt']['matches_candidate_page'], 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--writer-dir', type=Path)
    options, remaining = parser.parse_known_args()
    WRITER_DIR = options.writer_dir
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
else:
    WRITER_DIR = None

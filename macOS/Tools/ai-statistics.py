#!/usr/bin/env python3
"""Read-only AI statistics: all saved attempt history by default, no sample text in summary/list."""
import argparse
from collections import Counter
from contextlib import closing
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, localcontext
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys

# Reuse only the small existing read-only query helpers and exact composition reader.
_spec = importlib.util.spec_from_file_location('inkflow_quality_query',
    Path(__file__).resolve().parents[2] / '.agents/skills/inkflow-quality-analysis/scripts/quality.py')
quality = importlib.util.module_from_spec(_spec)
_previous_bytecode = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    _spec.loader.exec_module(quality)
finally:
    sys.dont_write_bytecode = _previous_bytecode
QueryError = quality.QueryError
DEFAULT_DB = Path.home() / 'Library/Application Support/InkFlow/ai-statistics.sqlite3'
TABLE_COLUMNS = {
    'recording_runs': 'id started_at ended_at status counters_json',
    'configurations': 'id snapshot_json pricing_json pricing_version build_identity',
    'attempts': '''id run_id configuration_id scheduled_at composition_id app_bundle_id last_edit_at
        last_edit_to_schedule_ms dispatch_composition_id dispatch_last_edit_at last_edit_to_dispatch_ms
        ordinary_visible_ms candidate_count candidate_page candidate_coverage pinyin_length prefix_length
        preceding_length following_length preceding_available following_available suggestion_length
        matches_first_candidate matches_candidate_page comparison_scope provider requested_model returned_model
        strategy_version usage_state prompt_tokens completion_tokens cached_tokens reasoning_tokens total_tokens
        estimated_cost currency cost_state response_truncated response_oversized recovery_state''',
    'attempt_events': 'attempt_id kind occurred_at elapsed_ms reason http_status',
    'samples': 'attempt_id expires_at input_json candidates_json response_text',
}
EVENTS = ('scheduled', 'dispatched', 'transportStarted', 'responseObserved', 'transportEnded',
          'serviceReturned', 'serviceFailed', 'shown', 'adoptionRequested', 'insertionIssued',
          'insertionReturned', 'uiEnded')
TOKENS = ('prompt_tokens', 'completion_tokens', 'cached_tokens', 'reasoning_tokens', 'total_tokens')


def now_epoch():
    return datetime.now(timezone.utc).timestamp()


def connect(path):
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise QueryError(f'Database does not exist: {path}. Use --db PATH or record AI attempts first.')
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.25)
    try:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')  # Identity and all command reads share the same snapshot.
        if (db.execute('PRAGMA application_id').fetchone()[0] != 0x49464131
                or db.execute('PRAGMA user_version').fetchone()[0] != 1):
            raise QueryError('Database is incompatible: expected InkFlow AI statistics v1 (IFA1).')
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,7)!='sqlite_'")}
        if tables != set(TABLE_COLUMNS):
            raise QueryError('Database is incompatible: expected the five InkFlow AI statistics tables.')
        for table, columns in TABLE_COLUMNS.items():
            actual = {r['name'] for r in db.execute(f'PRAGMA table_info({table})')}
            if not set(columns.split()) <= actual:
                raise QueryError(f'Database is incompatible: missing columns in {table}.')
        return db
    except Exception:
        db.close()
        raise


def filters(args):
    conditions, parameters = [], {}
    for name, column, comparison in [('since', 'scheduled_at', '>='), ('until', 'scheduled_at', '<'),
                                      ('model', 'requested_model', '='), ('strategy', 'strategy_version', '='),
                                      ('app', 'app_bundle_id', '=')]:
        value = getattr(args, name)
        if value is not None:
            conditions.append(f'a.{column} {comparison} :{name}')
            parameters[name] = datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() if name in ('since', 'until') else value
    return ' AND '.join(conditions) or '1', parameters


def attempts(db, args, *, limit=None, attempt_id=None):
    where, parameters = filters(args)
    if attempt_id is not None:
        where += ' AND a.id=:id'
        parameters['id'] = attempt_id
    suffix = ''
    if limit is not None:
        parameters['limit'] = limit
        suffix = ' LIMIT :limit'
    # No sample bodies are selected here, even when the database still holds expired rows.
    sql = f'''SELECT a.*,s.expires_at AS sample_expires_at,r.status AS run_status
        FROM attempts a LEFT JOIN samples s ON s.attempt_id=a.id
        JOIN recording_runs r ON r.id=a.run_id WHERE {where} ORDER BY a.scheduled_at DESC,a.id{suffix}'''
    selected = quality.rows(db, sql, parameters)
    by_id = {row['id']: row for row in selected}
    for row in selected:
        row['events'] = {}
    for event in quality.rows(db, f'''SELECT e.* FROM attempt_events e JOIN ({sql}) selected ON selected.id=e.attempt_id
                                      ORDER BY e.elapsed_ms,e.kind''', parameters):
        by_id[event['attempt_id']]['events'][event['kind']] = {key: value for key, value in event.items() if key != 'attempt_id'}
    return selected


def completion(row):
    if row['recovery_state'] != 'none':
        return row['recovery_state']
    events = row['events']
    complete = ('uiEnded' in events
                and ('dispatched' not in events or 'serviceReturned' in events or 'serviceFailed' in events)
                and ('transportStarted' not in events or 'transportEnded' in events))
    return 'complete' if complete else ('pending' if row['run_status'] == 'running' else 'unknown_incomplete')


def sample_state(row, now):
    expires = row['sample_expires_at']
    return 'absent' if expires is None else ('retained' if expires > now else 'expired')


def ratio(numerator, denominator):
    return dict(numerator=numerator, denominator=denominator, value=numerator/denominator if denominator else None)


def add_cost(groups, row):
    if row['cost_state'] != 'known':
        return
    try:
        amount = Decimal(row['estimated_cost'])
    except (InvalidOperation, TypeError) as error:
        raise QueryError('Invalid stored known cost.') from error
    if not amount.is_finite() or amount < 0 or not row['currency']:
        raise QueryError('Invalid stored known cost or currency.')
    group = groups.setdefault(row['currency'], dict(total=Decimal(0), adopted_total=Decimal(0), known=0, adopted=0))
    with localcontext() as context:
        context.prec = 100
        group['total'] += amount
        group['known'] += 1
        if 'shown' in row['events'] and 'insertionIssued' in row['events']:
            group['adopted_total'] += amount
            group['adopted'] += 1


def costs(groups, states, total_attempts):
    currencies = []
    for currency, group in sorted(groups.items()):
        with localcontext() as context:
            context.prec = 28
            per_adoption = group['total'] / group['adopted'] if group['adopted'] else None
            adopted_mean = group['adopted_total'] / group['adopted'] if group['adopted'] else None
        currencies.append(dict(currency=currency, known_attempts=group['known'], known_cost=str(group['total']),
                               cost_known_issued_adoptions=group['adopted'],
                               cost_per_issued_adoption=str(per_adoption) if per_adoption is not None else None,
                               adopted_request_cost=str(group['adopted_total']) if group['adopted'] else None,
                               mean_adopted_request_cost=str(adopted_mean) if adopted_mean is not None else None))
    known = sum(group['known'] for group in groups.values())
    return dict(states=dict(sorted(states.items())), known_attempts=known, unknown_attempts=total_attempts-known,
                currencies=currencies,
                adoption_cost_scope='all cost-known request costs / shown+insertionIssued count within that same cost-known cohort; per currency',
                estimate='persisted pricing snapshot estimate, not provider billing; division rounded to 28 significant digits')


def cohort_sql(args):
    where, parameters = filters(args)
    pivot = ','.join(f"MAX(CASE WHEN e.kind='{kind}' THEN e.elapsed_ms END) AS {kind}_ms" for kind in EVENTS)
    return f"""WITH eligible AS (
        SELECT a.*,s.expires_at AS sample_expires_at,r.status AS run_status FROM attempts a
        LEFT JOIN samples s ON s.attempt_id=a.id JOIN recording_runs r ON r.id=a.run_id WHERE {where}
    ), event_times AS (
        SELECT e.attempt_id,{pivot},MAX(CASE WHEN e.kind='uiEnded' THEN e.reason END) AS ui_reason,
            MAX(CASE WHEN e.kind='serviceFailed' THEN e.reason END) AS failure_reason,
            MAX(CASE WHEN e.kind='transportEnded' THEN e.reason END) AS transport_reason
        FROM attempt_events e JOIN eligible a ON a.id=e.attempt_id GROUP BY e.attempt_id
    ), cohort AS (SELECT a.*,e.* FROM eligible a LEFT JOIN event_times e ON e.attempt_id=a.id)
    """, parameters


def recording_runs(db):
    runs = quality.rows(db, 'SELECT id,started_at,ended_at,status,counters_json FROM recording_runs ORDER BY started_at,id')
    counters = Counter()
    # Add only cumulative command counters; gauges and diagnostic codes are not sums.
    additive = ('submitted', 'written', 'droppedQueue', 'droppedOversized', 'droppedBusy', 'droppedDisabled',
                'droppedMissingAttempt', 'errors')
    coverage = Counter()
    for run in runs:
        data = json.loads(run['counters_json'])
        for key in additive:
            if isinstance(data.get(key), int) and not isinstance(data[key], bool):
                counters[key] += data[key]
                coverage[key] += 1
    return dict(scope='whole_db_lifetime_unfiltered', runs=len(runs),
                statuses=dict(sorted(Counter(r['status'] for r in runs).items())),
                counter_totals={key: counters[key] if coverage[key] else None for key in additive},
                counter_known_runs={key: coverage[key] for key in additive},
                diagnostics=[dict(id=run['id'], status=run['status'], started_at=run['started_at'], ended_at=run['ended_at'],
                                  counters={key: json.loads(run['counters_json']).get(key)
                                            for key in ('buffered', 'peakBuffered', 'disabled', 'lastErrorCode')}) for run in runs],
                note='command counters, not request denominators; persisted best effort, unavailable fatal/crash tail cannot be inferred')


def summary(db, args):
    sql, parameters = cohort_sql(args)
    counts = Counter({kind: 0 for kind in EVENTS})
    counts['attempts'] = 0
    token_totals, token_known = Counter(), Counter()
    usage_states, cost_states, states, terminal_reasons = Counter(), Counter(), Counter(), Counter()
    failure_reasons, transport_reasons = Counter(), Counter()
    candidate_coverage, retention, comparisons, cost_groups = Counter(), Counter(), {}, {}
    for field in ('matches_first_candidate', 'matches_candidate_page'):
        comparisons[field] = dict(known=0, true=0, false=0, unknown=0)
    issued_shown = issued_network = shown_network = truncated = oversized = 0
    now = now_epoch()
    # Stream one pivoted attempt at a time. No all-history event dictionaries or sample bodies.
    for raw in db.execute(sql + 'SELECT * FROM cohort', parameters):
        row = dict(raw)
        row['events'] = {kind: dict(elapsed_ms=row[kind+'_ms'], reason=row['ui_reason'] if kind == 'uiEnded' else None)
                         for kind in EVENTS if row[kind+'_ms'] is not None}
        events = row['events']
        counts['attempts'] += 1
        counts.update(events.keys())
        issued_shown += 'insertionIssued' in events and 'shown' in events
        issued_network += 'insertionIssued' in events and 'transportStarted' in events
        shown_network += 'shown' in events and 'transportStarted' in events
        states[completion(row)] += 1
        if 'uiEnded' in events and 'shown' not in events:
            terminal_reasons[row['ui_reason'] or 'unknown'] += 1
        if 'serviceFailed' in events:
            failure_reasons[row['failure_reason'] or 'unknown'] += 1
        if 'transportEnded' in events:
            transport_reasons[row['transport_reason'] or 'unknown'] += 1
        usage_states[row['usage_state']] += 1
        for key in TOKENS:
            if row['usage_state'] in ('valid', 'partial') and row[key] is not None:
                token_totals[key] += row[key]
                token_known[key] += 1
        cost_states[row['cost_state']] += 1
        add_cost(cost_groups, row)
        candidate_coverage[row['candidate_coverage'] or 'unavailable'] += 1
        for field, evidence in comparisons.items():
            value = row[field]
            if value in (0, 1):
                evidence['known'] += 1
                evidence['true' if value == 1 else 'false'] += 1
            else:
                evidence['unknown'] += 1
        retention[sample_state(row, now)] += 1
        truncated += row['response_truncated'] != 0
        oversized += row['response_oversized'] != 0
    total = counts['attempts']
    latency = {
        'network_to_response': 'responseObserved_ms-transportStarted_ms',
        'schedule_to_first_show': 'shown_ms-scheduled_ms',
        'dispatch_to_first_show': 'shown_ms-dispatched_ms',
        'last_edit_to_first_show': """CASE WHEN shown_ms>=dispatched_ms AND last_edit_to_dispatch_ms IS NOT NULL
            THEN last_edit_to_dispatch_ms+shown_ms-dispatched_ms
            WHEN shown_ms>=scheduled_ms THEN last_edit_to_schedule_ms+shown_ms-scheduled_ms END""",
        'ordinary_visible_at_dispatch': 'ordinary_visible_ms',
    }
    return dict(counts=dict(counts),
                rates=dict(display_adoption=ratio(issued_shown, counts['shown']),
                           request_conversion=ratio(issued_network, counts['transportStarted']),
                           display_rate=ratio(shown_network, counts['transportStarted'])),
                completion={**{key: states[key] for key in ('complete', 'pending', 'interrupted', 'closed_incomplete', 'unknown_incomplete')},
                            'service_failed': counts['serviceFailed'], 'undisplayed_ui_end_reasons': dict(sorted(terminal_reasons.items())),
                            'service_failure_reasons': dict(sorted(failure_reasons.items())),
                            'transport_end_reasons': dict(sorted(transport_reasons.items())),
                            'note': 'UI end and transport/service completion are independent; incomplete is not rejection'},
                usage=dict(states=dict(sorted(usage_states.items())),
                           tokens={key: dict(known_attempts=token_known[key], total=token_totals[key] if token_known[key] else None) for key in TOKENS},
                           token_scope='valid/partial usage only; each field has its own known cohort; cached and reasoning are subsets, never add to totals'),
                cost=costs(cost_groups, cost_states, total),
                latency_ms={key: quality.sql_distribution(db, sql, parameters, expression, total, 'milliseconds') for key, expression in latency.items()},
                comparison=dict(scope='selected_prefix_plus_current_page; equality, not correctness or all-Rime recall',
                                candidate_coverage=dict(sorted(candidate_coverage.items())), **comparisons,
                                suggestion_length=quality.sql_distribution(db, sql, parameters, 'suggestion_length', total, 'Swift Characters')),
                retention=dict(as_of_epoch_seconds=now, states={state: retention[state] for state in ('retained', 'expired', 'absent')},
                               response_truncated=truncated, response_oversized=oversized,
                               note='absent does not prove expiry; read-time expiry hides content even before writer cleanup'),
                recording_runs=recording_runs(db))


def listing(db, args):
    now = now_epoch()
    selected = attempts(db, args, limit=args.limit)
    fields = ('id', 'scheduled_at', 'composition_id', 'dispatch_composition_id', 'app_bundle_id',
              'requested_model', 'returned_model', 'strategy_version', 'usage_state', 'cost_state', 'estimated_cost', 'currency')
    return dict(limit=args.limit, order='scheduled_at descending, id ascending', attempts=[
        dict({key: row[key] for key in fields}, completion=completion(row),
             events=list(row['events']), sample_state=sample_state(row, now)) for row in selected])


def ordinary_compositions(path, row):
    associations = {}
    for field, label in [('composition_id', 'scheduled'), ('dispatch_composition_id', 'dispatched')]:
        if row[field] is not None:
            associations.setdefault(row[field], []).append(label)
    result = []
    with closing(quality.connect(path)) as db:
        db.execute('BEGIN')
        for identity, labels in associations.items():
            found = db.execute('SELECT id,started_at,ended_at,outcome,outcome_reason,operations_json FROM compositions WHERE id=?', (identity,)).fetchone()
            result.append(dict(id=identity, associations=labels, state='found' if found else 'missing',
                               composition=quality.decode_row(dict(found)) if found else None))
    return result


def inspect(db, args):
    selected = attempts(db, args, attempt_id=args.attempt_id)
    if not selected:
        raise QueryError('Attempt not found or does not match the supplied filters.')
    row = selected[0]
    state = sample_state(row, now_epoch())
    sample = dict(state=state, expires_at=row['sample_expires_at'])
    if state == 'retained':
        raw = db.execute('SELECT input_json,candidates_json,response_text FROM samples WHERE attempt_id=?', (row['id'],)).fetchone()
        sample.update(quality.decode_row(dict(raw)))
    configuration = db.execute('SELECT * FROM configurations WHERE id=?', (row['configuration_id'],)).fetchone()
    result = dict(attempt={key: value for key, value in row.items() if key != 'events'}, events=list(row['events'].values()),
                  completion=completion(row), sample=sample, configuration=quality.decode_row(dict(configuration)),
                  response_text_semantics='first serviceReturned recommendation when observed, otherwise bounded raw provider content; truncation flag may describe an earlier capture')
    if args.quality_db is not None:
        result['ordinary_compositions'] = ordinary_compositions(args.quality_db, row)
        result['ordinary_join_scope'] = 'exact recorded IDs only; separate read snapshot, missing association remains unknown'
    return result


def bounded_limit(value):
    result = quality.positive(value)
    if result > 1000:
        raise argparse.ArgumentTypeError('must be at most 1000')
    return result


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest='command', required=True)
    for command in ('summary', 'list', 'inspect'):
        sub = commands.add_parser(command)
        if command == 'list':
            sub.add_argument('--limit', type=bounded_limit, default=50, help='1–1000; default 50 most recent attempts')
        if command == 'inspect':
            sub.add_argument('attempt_id', help='Exact ID from list')
            sub.add_argument('--quality-db', type=Path, help='Optional existing ordinary quality DB; join exact composition IDs')
        sub.add_argument('--db', type=Path, default=DEFAULT_DB)
        sub.add_argument('--since', type=quality.timestamp, help='Inclusive attempt start; local YYYY-MM-DD or timestamp with offset')
        sub.add_argument('--until', type=quality.timestamp, help='Exclusive attempt start; all saved history by default')
        sub.add_argument('--model', help='Exact requested model, not returned model')
        sub.add_argument('--strategy', help='Exact strategy version')
        sub.add_argument('--app', help='Exact app bundle ID')
        sub.add_argument('--format', choices=('json', 'table', 'csv'), default='table')
    return result


def main(argv=None):
    try:
        args = parser().parse_args(argv)
        if args.since and args.until and datetime.fromisoformat(args.since) >= datetime.fromisoformat(args.until):
            raise QueryError('--since must be earlier than the exclusive --until boundary.')
        with closing(connect(args.db)) as db:
            result = {'summary': summary, 'list': listing, 'inspect': inspect}[args.command](db, args)
        result = dict(command=args.command, history_scope='all saved attempts unless filtered',
                      filters={key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()
                               if key in ('db', 'since', 'until', 'model', 'strategy', 'app')}, **result)
        quality.render(result, args.format)
        return 0
    except SystemExit as error:
        return error.code
    except (QueryError, sqlite3.Error, ValueError, OSError) as error:
        print(f'ai-statistics: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())

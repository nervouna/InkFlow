"""Versioned manual exchange; all imported rows live only in memory."""
from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import uuid

FORMAT = 'inkflow-quality'
MAX_BYTES = 256 * 1024 * 1024


def source_id(path, create=False):
    marker = Path(path).expanduser().resolve().parent / 'quality-source-id'
    if not marker.exists() and create:
        try:
            with marker.open('x') as stream:
                stream.write(str(uuid.uuid4()))
        except FileExistsError:
            pass
    if not marker.exists():
        return 'local'
    value = marker.read_text().strip()
    return str(uuid.UUID(value))


def sanitize(table, row):
    row = dict(row)
    if table == 'config_revisions':
        row['applied_config_json'] = '{}'
    if table == 'candidate_decisions':
        for field in ('snapshot_json', 'first_page_json', 'visited_pages_json'):
            if row[field] is None:
                continue
            value = json.loads(row[field])
            pages = value if field == 'visited_pages_json' else [value]
            if not isinstance(pages, list) or any(not isinstance(p, dict) for p in pages):
                raise ValueError('Invalid candidate page JSON.')
            for page in pages:
                page.pop('configuration', None)
            row[field] = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return row


def snapshot(path, connect, columns, create_source=False):
    with closing(connect(path)) as db:
        db.execute('BEGIN')
        tables = {table: [sanitize(table, row) for row in db.execute(f'SELECT * FROM {table} ORDER BY id')]
                  for table in columns}
    times = [r['started_at'] for r in tables['compositions']] + [r['occurred_at'] for r in tables['effectiveness_events']]
    return dict(format=FORMAT, format_version=1, schema_version=3,
                source_id=source_id(path, create_source),
                exported_at=datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
                range=dict(first=min(times) if times else None, last=max(times) if times else None), tables=tables)


def export(path, output, connect, columns):
    output = output.expanduser().resolve()
    database = path.expanduser().resolve()
    if output == database or output.name == 'quality-source-id':
        raise ValueError('Choose a new JSON path, not the database or source marker.')
    document = snapshot(path, connect, columns, create_source=True)
    validate(document, columns)
    # CLI refuses to overwrite any file; Settings uses the save panel's overwrite choice.
    payload = json.dumps(document, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
    if len(payload.encode('utf-8')) > MAX_BYTES:
        raise ValueError('Export exceeds 256 MiB; no output file written.')
    with output.open('x') as stream:
        try:
            stream.write(payload)
        except BaseException:
            output.unlink(missing_ok=True)
            raise
    return dict(output=str(output), source_id=document['source_id'], range=document['range'],
                counts={t: len(r) for t, r in document['tables'].items()},
                privacy='May contain input, candidates, selected text and preceding context. Manual transfer only.')


def load(path, columns):
    path = path.expanduser().resolve()
    if path.stat().st_size > MAX_BYTES:
        raise ValueError(f'Export exceeds 256 MiB: {path}')
    try:
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError('Duplicate JSON field in export.')
                result[key] = value
            return result
        def reject_number(_):
            raise ValueError('Invalid JSON number.')
        document = json.loads(path.read_text(), object_pairs_hook=unique, parse_constant=reject_number)
        validate(document, columns)
    except (ValueError, TypeError, KeyError, AttributeError, RecursionError) as error:
        raise ValueError(f'Invalid quality export {path}: {error}') from error
    document['_input_path'] = str(path)
    return document


def validate(document, columns):
    if (not isinstance(document, dict) or document.get('format') != FORMAT
            or type(document.get('format_version')) is not int or document['format_version'] != 1
            or type(document.get('schema_version')) is not int or document['schema_version'] != 3):
        raise ValueError('Incompatible format; expected inkflow-quality v1, schema v3.')
    document['source_id'] = str(uuid.UUID(document['source_id']))
    observed = datetime.fromisoformat(document['exported_at'].replace('Z', '+00:00'))
    if observed.tzinfo is None:
        raise ValueError('Export time needs a UTC offset.')
    tables = document['tables']
    if not isinstance(tables, dict) or set(tables) != set(columns):
        raise ValueError('Expected exactly six quality tables.')
    nullable = {
        'recording_runs': {'ended_at', 'error_code'},
        'config_revisions': {'ranking_fingerprint', 'settings_fingerprint', 'measurement_fingerprint', 'build_identity'},
        'compositions': {'app_bundle_id', 'client_id', 'outcome_reason'},
        'commits': {'client_id'},
        'candidate_decisions': {'commit_id', 'selected_display_index', 'selected_text', 'first_page_json', 'unknown_rank_reason', 'path_reason'},
        'effectiveness_events': {'reason', 'milliseconds'},
    }
    integers = {'metric_rule_version', 'error_code', 'page_history_truncated', 'dropped_page_count',
                'insertion_issued', 'sequence', 'selected_display_index', 'regular_ranked_selection',
                'matches_custom_phrase', 'count', 'milliseconds'}
    indexes = {}
    for table, fields in columns.items():
        if not isinstance(tables[table], list):
            raise ValueError(f'{table} must be an array.')
        indexes[table] = {}
        for row in tables[table]:
            if not isinstance(row, dict) or set(row) != set(fields.split()):
                raise ValueError(f'Unexpected columns in {table}.')
            if any(v is not None and type(v) not in (str, int, float) for v in row.values()):
                raise ValueError(f'Invalid scalar in {table}.')
            if (table == 'effectiveness_events' and type(row['id']) is not int
                    or table != 'effectiveness_events' and (not isinstance(row['id'], str) or not row['id'])):
                raise ValueError(f'Invalid ID in {table}.')
            if row['id'] in indexes[table]:
                raise ValueError(f'Duplicate record ID in {table}.')
            for field, value in row.items():
                if value is None:
                    if field not in nullable[table]:
                        raise ValueError(f'Missing required value in {table}.{field}.')
                    continue
                expected = int if field in integers or (table == 'effectiveness_events' and field == 'id') else str
                if type(value) is not expected:
                    raise ValueError(f'Invalid value type in {table}.{field}.')
                if type(value) is int and not -(1 << 63) <= value < (1 << 63):
                    raise ValueError(f'Integer outside SQLite range in {table}.{field}.')
                if field in {'page_history_truncated', 'insertion_issued', 'regular_ranked_selection', 'matches_custom_phrase'} and value not in (0, 1):
                    raise ValueError(f'Invalid boolean in {table}.{field}.')
                if field in {'dropped_page_count', 'sequence', 'selected_display_index'} and value < 0:
                    raise ValueError(f'Negative count/index in {table}.{field}.')
                if field.endswith('_json') and value is not None:
                    decoded = json.loads(value)
                    expected = list if field == 'visited_pages_json' else dict
                    if not isinstance(decoded, expected):
                        raise ValueError(f'Invalid JSON shape in {table}.{field}.')
                if field.endswith('_at') and value is not None:
                    moment = datetime.fromisoformat(value.replace('Z', '+00:00'))
                    if moment.tzinfo is None or moment.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z') != value:
                        raise ValueError('Record times must use writer UTC milliseconds (YYYY-MM-DDTHH:MM:SS.sssZ).')
            if table == 'effectiveness_events':
                if not 1 <= row['count'] <= 64 or row['milliseconds'] is not None and not 0 <= row['milliseconds'] <= 60000:
                    raise ValueError('Invalid effectiveness count or duration.')
                if (row['event'] == 'rejected') != (row['reason'] is not None):
                    raise ValueError('Invalid rejection reason.')
            indexes[table][row['id']] = row
    references = {'compositions': {'run_id': 'recording_runs'}, 'commits': {'composition_id': 'compositions'},
                  'candidate_decisions': {'composition_id': 'compositions', 'config_revision_id': 'config_revisions', 'commit_id': 'commits'},
                  'effectiveness_events': {'run_id': 'recording_runs'}}
    sequences = set()
    for table, fields in references.items():
        for row in tables[table]:
            for field, parent in fields.items():
                value = row[field]
                if value is None and field == 'commit_id':
                    continue
                if value not in indexes[parent]:
                    raise ValueError(f'Missing parent in {table}.{field}.')
            if table == 'candidate_decisions':
                sequence = (row['composition_id'], row['sequence'])
                if sequence in sequences or row['outcome'] == 'committed' and row['commit_id'] is None:
                    raise ValueError('Invalid decision sequence or committed decision without a commit.')
                sequences.add(sequence)
                if row['commit_id'] is not None and indexes['commits'][row['commit_id']]['composition_id'] != row['composition_id']:
                    raise ValueError('Commit belongs to a different composition.')
                for field in ('snapshot_json', 'first_page_json', 'visited_pages_json'):
                    if row[field] is None:
                        continue
                    value = json.loads(row[field]); pages = value if field == 'visited_pages_json' else [value]
                    if any(not isinstance(p, dict) or p.get('configurationRevisionID') not in indexes['config_revisions'] for p in pages):
                        raise ValueError('Page references a missing configuration revision.')
    times = [r['started_at'] for r in tables['compositions']] + [r['occurred_at'] for r in tables['effectiveness_events']]
    if document['range'] != dict(first=min(times) if times else None, last=max(times) if times else None):
        raise ValueError('Record range does not match exported records.')


def canonical(row):
    # JSON whitespace/key order does not create a conflicting record.
    return {k: json.loads(v) if k.endswith('_json') and v is not None else v for k, v in row.items()}


def combine(documents, columns):
    merged = {t: {} for t in columns}
    sources = {}
    for document in documents:
        sid = document['source_id']
        observed = datetime.fromisoformat(document['exported_at'].replace('Z', '+00:00'))
        info = sources.setdefault(sid, dict(source_id=sid, snapshots=0, exported_at=[], range=document['range']))
        info.setdefault('input_paths', [])
        if (origin := document.get('_input_path')) and origin not in info['input_paths']:
            info['input_paths'].append(origin)
        info['snapshots'] += 1
        info['exported_at'].append(document['exported_at'])
        for table, records in document['tables'].items():
            for raw in records:
                row = sanitize(table, raw)
                # INTEGER PRIMARY KEY can be reused after retention cleanup. Include run and time.
                rid = (row['run_id'], row['id'], row['occurred_at']) if table == 'effectiveness_events' else row['id']
                key = (sid, rid)
                if key in merged[table]:
                    previous, previous_time = merged[table][key]
                    if table == 'recording_runs' and observed != previous_time:
                        if observed > previous_time:
                            merged[table][key] = (row, observed)
                    elif canonical(previous) != canonical(row):
                        raise ValueError(f'conflicting {table} record from source {sid}; no summary produced.')
                else:
                    merged[table][key] = (row, observed)
    db = sqlite3.connect(':memory:')
    db.row_factory = sqlite3.Row
    try:
        for table, fields in columns.items():
            names = fields.split()
            db.execute(f'CREATE TABLE {table} ({",".join(names)}, source_id TEXT)')
            for (sid, rid), (raw, _) in merged[table].items():
                row = dict(raw)
                row['id'] = sid + ':' + (json.dumps(rid, separators=(',', ':')) if isinstance(rid, tuple) else str(rid))
                for field in ('run_id', 'composition_id', 'config_revision_id', 'commit_id'):
                    if row.get(field) is not None:
                        row[field] = sid + ':' + row[field]
                if table == 'candidate_decisions':
                    for field in ('snapshot_json', 'first_page_json', 'visited_pages_json'):
                        if row[field] is None:
                            continue
                        value = json.loads(row[field]); pages = value if field == 'visited_pages_json' else [value]
                        for page in pages:
                            page['configurationRevisionID'] = sid + ':' + page['configurationRevisionID']
                        row[field] = json.dumps(value, ensure_ascii=False)
                db.execute(f'INSERT INTO {table} VALUES ({",".join("?" for _ in names)}, ?)', [row[n] for n in names] + [sid])
        for table, key in [('compositions', 'id'), ('candidate_decisions', 'composition_id'), ('config_revisions', 'id'), ('commits', 'id')]:
            db.execute(f'CREATE INDEX idx_{table} ON {table}({key})')
        db.commit()
        db.execute('PRAGMA query_only=ON')
        for sid, info in sources.items():
            times = [r[0] for r in db.execute('SELECT started_at FROM compositions WHERE source_id=? UNION ALL SELECT occurred_at FROM effectiveness_events WHERE source_id=?', (sid, sid))]
            info['range'] = dict(first=min(times) if times else None, last=max(times) if times else None)
            info['counts'] = {t: db.execute(f'SELECT COUNT(*) FROM {t} WHERE source_id=?', (sid,)).fetchone()[0] for t in columns}
            info['versions'] = [dict(r) for r in db.execute("SELECT json_extract(build_metadata_json,'$.appVersion') AS app_version, json_extract(build_metadata_json,'$.appBuild') AS app_build, COUNT(*) AS metadata_records FROM (SELECT build_metadata_json FROM config_revisions WHERE source_id=? UNION ALL SELECT build_metadata_json FROM recording_runs WHERE source_id=?) GROUP BY app_version,app_build", (sid, sid))]
        return db, sources
    except BaseException:
        db.close()
        raise

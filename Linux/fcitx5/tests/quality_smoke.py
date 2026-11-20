"""Exercise quality decisions using only the disposable installed-addon test daemon."""
import asyncio
import json
import os
from pathlib import Path
import sqlite3

from contextlib import closing


async def check_quality(context, controller, key, type_text, panels, commits, config, capabilities, log):
    assert os.environ.get("INKFLOW_ISOLATED_TEST") == "1"
    path = Path(os.environ["XDG_DATA_HOME"]) / "inkflow/quality/counts.sqlite3"
    marker = "质检机密标记"
    options = ("CandidateCount=8\n\n[CustomPhrases]\n"
               f"0=zzqs={marker}\n1=zzqx=SecretPhrase\n2=zzqe=天气🔒\n")

    async def recording(enabled):
        value = "True" if enabled else "False"
        config.write_text(f"RecordQuality={value}\n" + options)
        await controller.call_reload_addon_config("inkflow")

    def counts():
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            return dict(((length, has_context, page, rank), n) for length, has_context, page, rank, n in db.execute(
                "SELECT length,context,page_size,rank_bin,sum(n) FROM counts_v1 "
                "GROUP BY length,context,page_size,rank_bin"))

    await recording(False)
    baseline = counts()
    await recording(True)
    await context.call_set_capability(capabilities | (1 << 6))
    await context.call_set_surrounding_text("准备午", 3, 3)
    await type_text("zzqs")
    assert panels[-1][0][1] == marker
    await key(49)
    assert commits[-1] == marker
    await context.call_set_surrounding_text("", 0, 0)
    await type_text("nihao")
    await key(32)
    assert commits[-1] == "你好"
    await type_text("shi")
    assert await key(0xff56)
    index = next(i for i, item in enumerate(panels[-1]) if len(item[1]) == 1 and "\u4e00" <= item[1] <= "\u9fff")
    await context.call_select_candidate(index)
    await type_text("nia")
    index = next(i for i, item in enumerate(panels[-1]) if item[1] == "你")
    await context.call_select_candidate(index)
    final = panels[-1][0][1]
    assert await key(32)
    assert commits[-1] == "你" + final
    partial_bin = 0 if index == 0 else 1 if index < 3 else 2

    await type_text("nia")
    index = next(i for i, item in enumerate(panels[-1]) if item[1] == "你")
    await context.call_select_candidate(index)
    await key(0xff08)
    assert panels[-1][0][1] == "你啊", panels[-1]
    await key(32)
    assert commits[-1] == "你啊"
    await type_text("nihao")
    await key(ord(","))
    for code in ("zzqx", "zzqe"):
        await type_text(code)
        await key(32)
    await type_text("nihao")
    await key(0xff0d)
    await type_text("nihao")
    await controller.call_set_current_im("keyboard-us")
    await controller.call_set_current_im("inkflow-pinyin")
    await type_text("zzqs")
    await context.call_set_capability(capabilities | (1 << 36))
    await context.call_select_candidate(0)
    await controller.call_set_current_im("keyboard-us")
    await context.call_set_capability(capabilities)
    await controller.call_set_current_im("inkflow-pinyin")
    await controller.call_activate()
    await context.call_reset()
    await controller.call_set_current_im("inkflow-pinyin")
    await controller.call_activate()
    await recording(False)
    after = counts()
    expected = dict(baseline)
    for cell in ((3, 1, 8, 0), (2, 0, 8, 0), (1, 0, 8, 3), (1, 0, 8, partial_bin), (1, 0, 8, 0), (2, 0, 8, 0)):
        expected[cell] = expected.get(cell, 0) + 1
    assert expected == after, (expected, after)

    # Start collecting midway through a composition and finish it. That decision
    # straddles the privacy boundary. A new composition after the pause is eligible.
    await type_text("zzqs")
    await recording(True)
    await context.call_select_candidate(0)
    await recording(False)
    assert counts() == after
    private_db = path.with_suffix(".saved")
    path.rename(private_db)
    path.mkdir()
    try:
        await recording(True)
        await type_text("zzqs")
        assert await key(32)
        assert commits[-1] == marker
        await recording(False)
        assert path.is_dir()
    finally:
        path.rmdir()
        private_db.rename(path)
    assert counts() == after
    if os.geteuid() != 0:
        path.chmod(0o400)
        try:
            await recording(True)
            await type_text("zzqs")
            assert await key(32)
            assert commits[-1] == marker
            await recording(False)
        finally:
            path.chmod(0o600)
        assert counts() == after
    for file in (path, log):
        contents = file.read_bytes()
        assert marker.encode() not in contents and b"SecretPhrase" not in contents
    assert path.stat().st_mode & 0o077 == 0
    cli = Path(__file__).resolve().parents[2] / "scripts/quality.py"
    process = await asyncio.create_subprocess_exec("python3", str(cli), "--json", stdout=asyncio.subprocess.PIPE)
    stdout, _ = await process.communicate()
    assert process.returncode == 0 and marker.encode() not in stdout and b"SecretPhrase" not in stdout
    assert json.loads(stdout)["overall"]["known_rank"] == sum(after.values())
    print("PASS quality: proven clicks/space/digits, context, paging, segments, exclusions, privacy and store failure")

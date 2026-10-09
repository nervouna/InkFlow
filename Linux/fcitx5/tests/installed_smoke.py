#!/usr/bin/env python3
"""Exercise an installed addon on a private D-Bus with disposable personal data."""
import asyncio
import json
import os
from pathlib import Path
import sys

from dbus_next.aio import MessageBus


async def main():
    assert os.environ.get("INKFLOW_ISOLATED_TEST") == "1"
    log = Path(os.environ["XDG_CONFIG_HOME"]) / "fcitx.log"
    with log.open("w") as output:
        daemon = await asyncio.create_subprocess_exec(
            "fcitx5", "-k", "--disable", "all", "--enable",
            "dbus,dbusfrontend,keyboard,inkflow", stdout=output, stderr=output,
        )
        bus = await MessageBus().connect()
        context = controller = None
        try:
            tree = await bus.introspect("org.freedesktop.DBus", "/org/freedesktop/DBus")
            names = bus.get_proxy_object(
                "org.freedesktop.DBus", "/org/freedesktop/DBus", tree
            ).get_interface("org.freedesktop.DBus")
            for _ in range(100):
                if await names.call_name_has_owner("org.fcitx.Fcitx5"):
                    tree = await bus.introspect("org.fcitx.Fcitx5", "/controller")
                    break
                if daemon.returncode is not None:
                    raise RuntimeError("Fcitx5 exited before registering D-Bus")
                await asyncio.sleep(0.1)
            else:
                raise RuntimeError("Fcitx5 did not register D-Bus")
            controller = bus.get_proxy_object("org.fcitx.Fcitx5", "/controller", tree).get_interface(
                "org.fcitx.Fcitx.Controller1"
            )
            tree = await bus.introspect("org.fcitx.Fcitx5", "/org/freedesktop/portal/inputmethod")
            frontend = bus.get_proxy_object(
                "org.fcitx.Fcitx5", "/org/freedesktop/portal/inputmethod", tree
            ).get_interface("org.fcitx.Fcitx.InputMethod1")
            path, _ = await frontend.call_create_input_context([["program", "inkflow-isolated-smoke"]])
            tree = await bus.introspect("org.fcitx.Fcitx5", path)
            context = bus.get_proxy_object("org.fcitx.Fcitx5", path, tree).get_interface(
                "org.fcitx.Fcitx.InputContext1"
            )
            commits, preedits, panels = [], [], []
            context.on_commit_string(lambda text: commits.append(text))
            context.on_update_formatted_preedit(lambda text, cursor: preedits.append((text, cursor)))

            def panel(preedit, cursor, upper, lower, candidates, index, layout, previous, following):
                panels.append(candidates)

            context.on_update_client_side_ui(panel)
            capabilities = (1 << 1) | (1 << 4) | (1 << 39)
            await context.call_set_capability(capabilities)
            await context.call_focus_in()
            await controller.call_set_current_im("inkflow-pinyin")
            await controller.call_activate()
            assert await controller.call_current_input_method() == "inkflow-pinyin"

            async def key(code, release=False):
                return await context.call_process_key_event(code, 0, 0, release, 0)

            async def type_text(text):
                for char in text:
                    assert await key(ord(char)), f"unhandled fixture key: {char}"
                    await key(ord(char), True)

            await type_text("nihao")
            assert any(parts for parts, _ in preedits), "no preedit received"
            assert panels and panels[-1], "no candidates received"
            assert panels[-1][0][1] == "你好", panels[-1]
            await context.call_select_candidate(0)
            assert commits == ["你好"], commits
            assert not preedits[-1][0], "preedit survived selection"
            print("PASS installed addon: preedit, candidate panel, click selection, one commit")

            await type_text("nihao")
            assert await key(32)
            await key(32, True)
            assert commits == ["你好", "你好"], commits
            await type_text("nihao")
            await context.call_reset()
            assert not preedits[-1][0]
            await type_text("nihao")
            await context.call_focus_out()
            await context.call_focus_in()
            assert not preedits[-1][0]
            assert commits == ["你好", "你好"], commits
            print("PASS installed addon: space selection, key releases, reset and focus cancellation")

            for flag in (1 << 3, 1 << 36):
                await context.call_set_capability(capabilities | flag)
                assert not await key(ord("n")), "sensitive key was consumed"
                assert commits == ["你好", "你好"]
            await context.call_set_capability(capabilities)
            await controller.call_set_current_im("inkflow-pinyin")
            await controller.call_activate()
            await type_text("nihao")
            await context.call_reset()
            print("PASS installed addon: password/sensitive pass-through and recovery")

            config = Path(os.environ["XDG_CONFIG_HOME"]) / "fcitx5/conf/inkflow.conf"
            config.parent.mkdir(exist_ok=True)
            marker = "fixture-phrase-must-not-appear-in-logs"
            config.write_text(f"CandidateCount=7\n\n[CustomPhrases]\n0={marker}\n1=zzcs=安装测试\n")
            await controller.call_reload_addon_config("inkflow")
            await type_text("zzcs")
            assert panels[-1][0][1] == "安装测试", panels[-1]
            await context.call_select_candidate(0)
            assert commits[-1] == "安装测试"
            assert marker not in log.read_text()
            print("PASS installed addon: configuration reload, custom phrase, text-free warning")

            backup = config.parent / "fixture-backup.json"
            backup.write_text(json.dumps({
                "format": 1, "rime": "1.17.0",
                "settings": {
                    "integers": {
                        "candidateCount": 7, "fontSize": 18,
                        "input.abbreviation": 1, "input.typoTolerance": 1,
                        "input.fuzzyZ": 0, "input.fuzzyC": 0, "input.fuzzyS": 0,
                        "input.emoji": 1, "input.bracketPaging": 1,
                        "input.minusEqualPaging": 1, "input.englishPunctuation": 0,
                        "input.cornerQuotes": 1, "input.middleDot": 1,
                        "input.fullwidthPipe": 1, "input.ideographicComma": 1,
                        "input.traditional": 0,
                    },
                    "phrases": [{"id": "p1", "code": "zzbk", "text": "备份测试"}],
                },
                "dictionaries": {"pinyin_simp": None, "inkflow_shared_english": None,
                                 "inkflow_voice_alias": None},
            }))
            config.write_text(f"ImportBackup={backup}\n")
            await controller.call_reload_addon_config("inkflow")
            assert f"ImportBackup={backup}" not in config.read_text()
            await type_text("zzbk")
            assert panels[-1][0][1] == "备份测试", panels[-1]
            await context.call_select_candidate(0)
            assert commits[-1] == "备份测试"
            assert "imported personal data from" in log.read_text()
            print("PASS installed addon: explicit backup import, engine restart, restored phrase")
        finally:
            if context:
                await context.call_destroy_ic()
            if controller:
                await controller.call_exit()
            elif daemon.returncode is None:
                daemon.terminate()
            await asyncio.wait_for(daemon.wait(), 10)
            bus.disconnect()
            if sys.exc_info()[0]:
                print(log.read_text(), file=sys.stderr)


asyncio.run(asyncio.wait_for(main(), 60))

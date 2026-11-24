"""The app's paint mode menu and the engine's allowlist name the same modes."""
from pathlib import Path
import re
import unittest


SOURCE_ROOT = Path(__file__).resolve().parents[2]


def engine_nicks():
    source = (SOURCE_ROOT / "Engine" / "paint.c").read_text()
    body = re.search(r"paint_mode_nicks\[\] = \{(.*?)\};", source, re.S).group(1)
    return re.findall(r'"([^"]+)"', body)


def app_nicks():
    source = (SOURCE_ROOT / "Sources" / "GlimsKit" / "Engine" / "EngineSession.swift").read_text()
    body = re.search(r"static let named: \[\(nick: String, title: String\)\] = \[(.*?)\n        \]", source, re.S).group(1)
    return re.findall(r'\("([^"]+)", "[^"]+"\)', body)


class PaintModeListTests(unittest.TestCase):
    def test_lists_match_in_order(self):
        engine, app = engine_nicks(), app_nicks()
        self.assertEqual(len(engine), 36)
        self.assertEqual(engine, app)
        self.assertEqual(len(set(engine)), len(engine))


if __name__ == "__main__":
    unittest.main()

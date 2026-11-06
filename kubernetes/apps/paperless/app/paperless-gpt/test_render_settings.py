import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_settings as rs  # noqa: E402

TEMPLATE = {
    "custom_fields_enable": True,
    "custom_fields_write_mode": "update",
    "custom_field_names": ["A", "B"],
}
V031_SETTINGS_KEYS = {
    "custom_fields_enable",
    "custom_fields_selected_ids",
    "custom_fields_write_mode",
    "ocr",
}


class RenderSettingsTest(unittest.TestCase):
    def test_names_resolve_in_template_order(self):
        fields = [{"id": 9, "name": "B"}, {"id": 4, "name": "A"}, {"id": 1, "name": "other"}]
        self.assertEqual(rs.resolve(["A", "B"], fields), [4, 9])

    def test_output_matches_settings_struct(self):
        settings = rs.build_settings(TEMPLATE, [4, 9])
        self.assertEqual(set(settings), V031_SETTINGS_KEYS)
        self.assertEqual(settings["custom_fields_selected_ids"], [4, 9])
        json.dumps(settings)

    def test_missing_name_retries_and_never_returns_partial(self):
        responses = [[{"id": 4, "name": "A"}], [{"id": 4, "name": "A"}, {"id": 9, "name": "B"}]]
        sleeps = []
        ids = rs.wait_for_ids(["A", "B"], lambda: responses.pop(0), sleep=sleeps.append)
        self.assertEqual(ids, [4, 9])
        self.assertEqual(sleeps, [rs.RETRY_DELAY_SECONDS])

    def test_deadline_raises_without_ids(self):
        ticks = iter([0, 0, rs.DEADLINE_SECONDS + 1])
        with self.assertRaises(LookupError):
            rs.wait_for_ids(["A"], lambda: [], sleep=lambda _: None, clock=lambda: next(ticks))


if __name__ == "__main__":
    unittest.main()

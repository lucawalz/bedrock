import json
import os
import sys
import unittest

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_settings as rs  # noqa: E402

TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "settings.template.json")
TEMPLATE = {
    "custom_fields_enable": True,
    "custom_fields_write_mode": "update",
}
TAXONOMY = """
document_types: []
tags: []
custom_fields:
  - name: A
    data_type: monetary
  - name: B
    data_type: date
correspondents: []
"""
V031_SETTINGS_KEYS = {
    "custom_fields_enable",
    "custom_fields_selected_ids",
    "custom_fields_write_mode",
    "ocr",
}
UNRESOLVED_ATTEMPTS = 5


class RenderSettingsTest(unittest.TestCase):
    def test_names_come_from_taxonomy_in_order(self):
        self.assertEqual(rs.field_names(yaml.safe_load(TAXONOMY)), ["A", "B"])

    def test_taxonomy_without_fields_is_rejected(self):
        with self.assertRaises(ValueError):
            rs.field_names({"custom_fields": []})

    def test_template_holds_no_field_names(self):
        with open(TEMPLATE_PATH, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), TEMPLATE)

    def test_names_resolve_in_taxonomy_order(self):
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

    def test_keeps_retrying_without_giving_up(self):
        responses = [[]] * UNRESOLVED_ATTEMPTS + [[{"id": 4, "name": "A"}]]
        sleeps = []
        ids = rs.wait_for_ids(["A"], lambda: responses.pop(0), sleep=sleeps.append)
        self.assertEqual(ids, [4])
        self.assertEqual(len(sleeps), UNRESOLVED_ATTEMPTS)


if __name__ == "__main__":
    unittest.main()

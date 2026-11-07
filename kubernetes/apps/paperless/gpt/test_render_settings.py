import json
import os
import sys
import tempfile
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
tags:
  - name: Category A
    description: Private purchases.
  - name: Category B
    description: Letters from offices.
custom_fields:
  - name: A
    description: The main amount.
    data_type: monetary
  - name: B
    description: The due date.
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


PROMPT_FILES = {
    "correspondent_prompt.tmpl": "correspondent body",
    "title_prompt.tmpl": "title body",
}
CONFIGMAP_TIMESTAMP_DIR = "..2026_11_06_00_00_00.000000000"


class CopyPromptsTest(unittest.TestCase):
    def test_copies_only_templates_from_configmap_volume(self):
        with tempfile.TemporaryDirectory() as root:
            src = os.path.join(root, "src")
            dst = os.path.join(root, "dst")
            os.makedirs(os.path.join(src, CONFIGMAP_TIMESTAMP_DIR))
            os.makedirs(dst)
            for name, body in PROMPT_FILES.items():
                with open(os.path.join(src, CONFIGMAP_TIMESTAMP_DIR, name), "w", encoding="utf-8") as handle:
                    handle.write(body)
            os.symlink(CONFIGMAP_TIMESTAMP_DIR, os.path.join(src, "..data"))
            for name in PROMPT_FILES:
                os.symlink(os.path.join("..data", name), os.path.join(src, name))
            rs.copy_prompts(src, dst)
            self.assertEqual(sorted(os.listdir(dst)), sorted(PROMPT_FILES))
            for name, body in PROMPT_FILES.items():
                path = os.path.join(dst, name)
                self.assertFalse(os.path.islink(path))
                with open(path, encoding="utf-8") as handle:
                    self.assertEqual(handle.read(), body)


PROMPT_HEAD = "role line\n<content>\n{{.Content}}\n</content>\n"
PROMPT_TAIL = "\nanswer {{.Language}}\n"
TAG_BLOCK = "<tag_definitions>\nCategory A: Private purchases.\nCategory B: Letters from offices.\n</tag_definitions>"
FIELD_BLOCK = "<field_definitions>\nA: The main amount.\nB: The due date.\n</field_definitions>"


class DefinitionsTest(unittest.TestCase):
    def write_prompts(self, directory, tag_marker=rs.TAG_MARKER, field_marker=rs.FIELD_MARKER):
        for name, marker in ((rs.TAG_PROMPT, tag_marker), (rs.FIELD_PROMPT, field_marker)):
            with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
                handle.write(PROMPT_HEAD + marker + PROMPT_TAIL)

    def read(self, directory, name):
        with open(os.path.join(directory, name), encoding="utf-8") as handle:
            return handle.read()

    def test_markers_are_replaced_with_definitions(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write_prompts(directory)
            rs.insert_definitions(directory, rs.definition_blocks(yaml.safe_load(TAXONOMY)))
            self.assertEqual(self.read(directory, rs.TAG_PROMPT), PROMPT_HEAD + TAG_BLOCK + PROMPT_TAIL)
            self.assertEqual(self.read(directory, rs.FIELD_PROMPT), PROMPT_HEAD + FIELD_BLOCK + PROMPT_TAIL)

    def test_markers_hold_no_template_syntax(self):
        for marker in (rs.TAG_MARKER, rs.FIELD_MARKER):
            self.assertNotIn("{{", marker)
            self.assertNotIn("}}", marker)

    def test_prompt_without_marker_fails(self):
        blocks = rs.definition_blocks(yaml.safe_load(TAXONOMY))
        for markers in ({"tag_marker": "plain line"}, {"field_marker": "plain line"}):
            with self.subTest(markers=markers), tempfile.TemporaryDirectory() as directory:
                self.write_prompts(directory, **markers)
                with self.assertRaisesRegex(ValueError, "exactly once"):
                    rs.insert_definitions(directory, blocks)

    def test_entry_without_description_fails(self):
        taxonomy = yaml.safe_load(TAXONOMY)
        for key, entry in (
            ("tags", "Category A"),
            ("tags", {"name": "Category A"}),
            ("tags", {"name": "Category A", "description": " "}),
            ("custom_fields", {"name": "A", "data_type": "monetary"}),
            ("custom_fields", {"name": "A", "description": "a {{.Title}} amount", "data_type": "monetary"}),
        ):
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                rs.definition_blocks({**taxonomy, key: [entry]})

    def test_shipped_prompts_hold_their_marker_once(self):
        prompts = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompts")
        for name, marker in ((rs.TAG_PROMPT, rs.TAG_MARKER), (rs.FIELD_PROMPT, rs.FIELD_MARKER)):
            with open(os.path.join(prompts, name), encoding="utf-8") as handle:
                self.assertEqual(handle.read().split("\n").count(marker), 1, name)


if __name__ == "__main__":
    unittest.main()

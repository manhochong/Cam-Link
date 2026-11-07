import csv
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from compare_card import compare

class CompareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.card = self.root / 'card'
        self.card.mkdir()
        self.report = self.root / 'report'
        self.report.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def write_report(self, data, **summary):
        with (self.report / 'files.csv').open('w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=['status', 'handle', 'original_name', 'sha256', 'expected_bytes', 'actual_bytes'])
            writer.writeheader()
            for n, b in enumerate(data):
                writer.writerow(dict(status='OK', handle=n, original_name='P100001.JPG', sha256=hashlib.sha256(b).hexdigest(), expected_bytes=len(b), actual_bytes=len(b)))
        (self.report / 'summary.json').write_text(json.dumps(dict(clean_stop=True, valid_jpg=len(data), failed=0, pending=0, validating=0) | summary))

    def test_matching_different_names(self):
        (self.card / 'arbitrary-name.JPG').write_bytes(b'camera original')
        self.write_report([b'camera original'])
        self.assertEqual(compare(self.report, self.card)['result'], 'PASS_BYTE_MATCH')

    def test_same_count_wrong_bytes(self):
        (self.card / 'a.jpg').write_bytes(b'original')
        self.write_report([b'corrupt!'])
        r = compare(self.report, self.card)
        self.assertEqual(r['result'], 'FAIL')
        self.assertEqual(len(r['missing_or_different']), 1)

    def test_same_name_different_folders(self):
        for name, b in [('slot1', b'one'), ('slot2', b'two')]:
            (self.card / name).mkdir()
            (self.card / name / 'same.jpg').write_bytes(b)
        self.write_report([b'one', b'two'])
        self.assertEqual(compare(self.report, self.card)['result'], 'PASS_BYTE_MATCH')

    def test_duplicate_identical_images_need_multiplicity(self):
        (self.card / 'a.jpg').write_bytes(b'original')
        (self.card / 'b.jpg').write_bytes(b'original')
        self.write_report([b'original'])
        self.assertEqual(compare(self.report, self.card)['result'], 'FAIL')

    def test_extra_image(self):
        (self.card / 'a.jpg').write_bytes(b'one')
        self.write_report([b'one', b'extra'])
        self.assertEqual(compare(self.report, self.card)['result'], 'FAIL')

    def test_unclean_stop(self):
        (self.card / 'a.jpg').write_bytes(b'one')
        self.write_report([b'one'], clean_stop=False)
        self.assertEqual(compare(self.report, self.card)['result'], 'FAIL')

    def test_pending(self):
        (self.card / 'a.jpg').write_bytes(b'one')
        self.write_report([b'one'], pending=1)
        self.assertEqual(compare(self.report, self.card)['result'], 'FAIL')

    def test_expected_count(self):
        (self.card / 'a.jpg').write_bytes(b'one')
        self.write_report([b'one'])
        self.assertEqual(compare(self.report, self.card, 300)['result'], 'FAIL')

    def test_empty_card(self):
        self.write_report([])
        with self.assertRaises(ValueError):
            compare(self.report, self.card)

    def test_zip_report(self):
        (self.card / 'a.jpg').write_bytes(b'one')
        self.write_report([b'one'])
        zipped = self.root / 'report.zip'
        with zipfile.ZipFile(zipped, 'w') as z:
            for p in self.report.iterdir():
                z.write(p, p.name)
        self.assertEqual(compare(zipped, self.card)['result'], 'PASS_BYTE_MATCH')

    def test_duplicate_handle(self):
        (self.card / 'a.jpg').write_bytes(b'one')
        (self.card / 'b.jpg').write_bytes(b'two')
        self.write_report([b'one', b'two'])
        p = self.report / 'files.csv'
        p.write_text(p.read_text().replace('OK,1,', 'OK,0,'))
        self.assertEqual(compare(self.report, self.card)['result'], 'FAIL')

    def test_summary_mismatch(self):
        (self.card / 'a.jpg').write_bytes(b'one')
        self.write_report([b'one'], valid_jpg=300)
        self.assertEqual(compare(self.report, self.card)['result'], 'FAIL')

if __name__ == '__main__':
    unittest.main()

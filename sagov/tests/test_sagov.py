"""Offline security/behaviour checks for the fictional SA Government services."""
import importlib.util
import os
import pathlib
import tempfile
import unittest

os.environ.setdefault("TRUMPS_API_KEY", "a" * 32)
os.environ.setdefault("RHBK_PUBLIC_URL", "https://keycloak.demo.invalid")
os.environ.setdefault("SAGOV_PORTAL_URL", "https://portal.demo.invalid")
os.environ.setdefault("MYSAGOV_CLIENT_SECRET", "test-only")
os.environ.setdefault("SAGOV_READER_SECRET", "test-only")
root = pathlib.Path(__file__).resolve().parents[2]


def module(name, location):
    spec = importlib.util.spec_from_file_location(name, root / location)
    item = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(item)
    return item


trumps = module("mock_trumps", "sagov/trumps/app.py")
portal = module("mock_mysagov", "sagov/mysagov/app.py")


class VerificationTests(unittest.TestCase):
    def test_correct_dit_subject_can_verify_record(self):
        self.assertEqual(trumps.verify_record("11111111-1111-4111-8111-111111111111",
                                              "DEMO-LIC-001"), "TRUMPS-1001")

    def test_different_subject_same_email_is_irrelevant(self):
        self.assertIsNone(trumps.verify_record("33333333-3333-4333-8333-333333333333",
                                               "DEMO-LIC-001"))

    def test_unknown_record_fails_closed(self):
        self.assertIsNone(trumps.verify_record("11111111-1111-4111-8111-111111111111",
                                               "NOT-A-LICENCE"))

    def test_link_resolution_requires_both_verified_broker_links(self):
        before = portal.admin_links
        try:
            def lookup(realm, sub):
                if realm == "sa-id":
                    return [{"identityProvider": "idx", "userId": "idx-sub-123"}]
                if realm == "idx":
                    return [{"identityProvider": "dit", "userId": "dit-sub-123"}]
                raise AssertionError(realm)
            portal.admin_links = lookup
            self.assertEqual(portal.verify_chain("sa-sub"), ("idx-sub-123", "dit-sub-123"))
            portal.admin_links = lambda realm, sub: []
            with self.assertRaises(ValueError):
                portal.verify_chain("sa-sub")
        finally:
            portal.admin_links = before

    def test_duplicate_record_claim_by_second_sa_id_is_blocked(self):
        before = portal.DB
        try:
            with tempfile.TemporaryDirectory() as temp:
                portal.DB = str(pathlib.Path(temp) / "claims.sqlite")
                portal.init_db()
                self.assertTrue(portal.save_verified_link("sa-A", "idx-A", "dit-A", "TRUMPS-1001"))
                self.assertFalse(portal.save_verified_link("sa-B", "idx-B", "dit-B", "TRUMPS-1001"))
                self.assertEqual(len(portal.linked_records("sa-A")), 1)
                self.assertEqual(len(portal.linked_records("sa-B")), 0)
                self.assertIn("DENIED_RECORD_ALREADY_CLAIMED",
                              [row[0] for row in portal.audit_records("sa-B")])
        finally:
            portal.DB = before


if __name__ == "__main__":
    unittest.main()

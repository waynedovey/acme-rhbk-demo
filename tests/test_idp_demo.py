"""Offline tests for RHBK IdP example routes (no Keycloak required)."""
import base64
import json
import os
import sys
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "portal"))
import idp_demo


def jwt(payload):
    part = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return "eyJhbGciOiJub25lIn0." + part + ".demo-signature"


class BootstrapSafetyTests(unittest.TestCase):
    def test_existing_fapi_client_is_not_rewritten_by_bootstrap(self):
        """RHBK FAPI policy may reject generic client metadata updates."""
        script = (Path(__file__).resolve().parents[1] / "scripts" / "bootstrap-demo.sh").read_text()
        self.assertIn('if [[ -z "$(client_uuid acme-demo high-assurance-api)" ]]; then', script)
        self.assertIn("Preserving existing FAPI 2 policy-managed client", script)
        self.assertIn("ensure_client acme-demo high-assurance-api", script)


class IdpDemoTests(unittest.TestCase):
    def setUp(self):
        self.saved_url = idp_demo.KEYCLOAK_URL
        idp_demo.KEYCLOAK_URL = "https://keycloak.example"
        idp_demo.FLOWS.clear()
        idp_demo.SESSIONS.clear()

    def tearDown(self):
        idp_demo.KEYCLOAK_URL = self.saved_url

    def request(self, url, cookies=""):
        parsed = urllib.parse.urlsplit(url)
        environ = {
            "PATH_INFO": parsed.path,
            "QUERY_STRING": parsed.query,
            "HTTP_COOKIE": cookies,
        }
        result = {}

        def start(status, headers):
            result["status"] = status
            result["headers"] = headers

        def layout(title, html_body):
            return html_body

        def response(start_response, body, status="200 OK", headers=None,
                     content_type="text/html; charset=utf-8"):
            start_response(status, headers or [])
            return [str(body).encode()]

        body = idp_demo.handle(
            environ, start, "https://portal.example", layout, response
        )
        result["body"] = b"".join(body or []).decode()
        return result

    @staticmethod
    def header(result, key):
        return [v for k, v in result["headers"] if k.lower() == key.lower()]

    def begin(self, app):
        result = self.request("/idp-login?app=" + app)
        self.assertEqual("302 Found", result["status"])
        location = self.header(result, "Location")[0]
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(location).query)
        self.assertEqual([idp_demo.APPS[app]["client"]], params["client_id"])
        self.assertEqual(["S256"], params["code_challenge_method"])
        self.assertEqual(["code"], params["response_type"])
        cookie = self.header(result, "Set-Cookie")[0].split(";", 1)[0]
        return params["state"][0], cookie

    def finish(self, app, existing_cookie=""):
        state, flow_cookie = self.begin(app)
        flow = idp_demo.FLOWS[state]
        client_id = idp_demo.APPS[app]["client"]
        fake_tokens = {
            "id_token": jwt({
                "sub": "demo-user-123",
                "iss": "https://keycloak.example/realms/acme-demo",
                "aud": client_id,
                "nonce": flow["nonce"],
                "preferred_username": "alex",
                "auth_time": 123456,
            }),
            "access_token": jwt({
                "sub": "demo-user-123", "azp": client_id,
                "scope": "openid profile email",
            }),
        }
        with mock.patch.object(idp_demo, "exchange", return_value=fake_tokens) as exchange:
            result = self.request(
                "/idp-callback?code=example&state=" + state,
                flow_cookie + ("; " + existing_cookie if existing_cookie else ""),
            )
            exchange.assert_called_once()
        self.assertEqual("302 Found", result["status"])
        self.assertEqual("/idp-app?app=" + app, self.header(result, "Location")[0])
        new_cookie = [v.split(";", 1)[0] for v in self.header(result, "Set-Cookie") if v.startswith("idpsid=")][0]
        return new_cookie, fake_tokens

    def test_two_clients_one_idp(self):
        citizen_cookie, tokens = self.finish("citizen")
        agency_cookie, _ = self.finish("agency", citizen_cookie)
        self.assertEqual(citizen_cookie, agency_cookie)
        overview = self.request("/idp", agency_cookie)
        self.assertIn("Both apps received independent OIDC tokens", overview["body"])
        self.assertIn("acme-citizen-service", overview["body"])
        self.assertIn("acme-agency-service", overview["body"])
        evidence = self.request("/idp-evidence", agency_cookie)["body"]
        self.assertIn("demo-user-123", evidence)
        self.assertNotIn(tokens["access_token"], evidence)
        self.assertNotIn(tokens["id_token"], evidence)

    def test_reject_wrong_browser_state(self):
        state, cookie = self.begin("citizen")
        wrong = self.request("/idp-callback?code=example&state=" + state, "idpflow=attacker")
        self.assertEqual("400 Bad Request", wrong["status"])
        self.assertEqual({}, idp_demo.SESSIONS)

    def test_reject_wrong_token_audience(self):
        state, cookie = self.begin("citizen")
        flow = idp_demo.FLOWS[state]
        fake = {"id_token": jwt({
            "sub": "user",
            "iss": "https://keycloak.example/realms/acme-demo",
            "aud": "some-other-client",
            "nonce": flow["nonce"],
        }), "access_token": jwt({"azp": "acme-citizen-service"})}
        with mock.patch.object(idp_demo, "exchange", return_value=fake):
            result = self.request("/idp-callback?code=example&state=" + state, cookie)
        self.assertEqual("400 Bad Request", result["status"])
        self.assertEqual({}, idp_demo.SESSIONS)

    def test_reset_only_clears_portal_evidence(self):
        cookie, _ = self.finish("citizen")
        result = self.request("/idp-reset", cookie)
        self.assertEqual("302 Found", result["status"])
        self.assertFalse(idp_demo.SESSIONS)
        self.assertIn("Clear local example sessions", self.request("/idp")["body"])


if __name__ == "__main__":
    unittest.main()

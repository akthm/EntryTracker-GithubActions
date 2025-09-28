import os, sys
sys.path.append(os.path.dirname(os.path.dirname(__file__)))

import app  

def test_health():
    client = app.app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
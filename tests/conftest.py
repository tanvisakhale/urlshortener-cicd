import os

os.environ["DATABASE_URL"] = "sqlite:///./test_db.sqlite3"

import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture(scope="session")
def client():
    with TestClient(app) as c:
        yield c

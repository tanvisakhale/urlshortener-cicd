import os
import time
import uuid
from contextlib import asynccontextmanager

import shortuuid
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import PlainTextResponse, RedirectResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy.orm import Session

from app.database import get_db, init_db
from app.logging_config import logger
from app.metrics import (
    APP_AVAILABILITY,
    HTTP_ERRORS_TOTAL,
    HTTP_REQUEST_DURATION_SECONDS,
    HTTP_REQUESTS_TOTAL,
    URLS_SHORTENED_TOTAL,
)
from app.models import URLMapping
from app.schemas import HealthResponse, ShortenRequest, ShortenResponse


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    logger.info("Application startup complete", extra={"event": "startup"})
    yield
    logger.info("Application shutting down", extra={"event": "shutdown"})


app = FastAPI(title="URL Shortener", version="1.0.0", lifespan=lifespan)

# Base URL used to build the "short_url" returned to clients. Must be
# supplied via env var -- defaults to localhost only for local dev.
BASE_SHORT_URL = os.getenv("BASE_SHORT_URL", "http://localhost:8000").rstrip("/")


@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    """Attaches a request_id, times the request, records Prometheus
    metrics, and emits one structured JSON log line per request."""
    request_id = str(uuid.uuid4())
    start = time.perf_counter()
    endpoint = request.url.path
    method = request.method

    try:
        response = await call_next(request)
        status_code = response.status_code
    except Exception as exc:
        duration = time.perf_counter() - start
        HTTP_ERRORS_TOTAL.labels(method=method, endpoint=endpoint).inc()
        logger.error(
            "Unhandled exception",
            extra={
                "method": method,
                "endpoint": endpoint,
                "status_code": 500,
                "response_time_ms": round(duration * 1000, 2),
                "request_id": request_id,
                "error_message": str(exc),
            },
        )
        raise

    duration = time.perf_counter() - start
    HTTP_REQUESTS_TOTAL.labels(method=method, endpoint=endpoint, status_code=status_code).inc()
    HTTP_REQUEST_DURATION_SECONDS.labels(method=method, endpoint=endpoint).observe(duration)
    if status_code >= 500:
        HTTP_ERRORS_TOTAL.labels(method=method, endpoint=endpoint).inc()

    logger.info(
        "request handled",
        extra={
            "method": method,
            "endpoint": endpoint,
            "status_code": status_code,
            "response_time_ms": round(duration * 1000, 2),
            "request_id": request_id,
            "error_message": None,
        },
    )
    response.headers["X-Request-ID"] = request_id
    return response


@app.get("/health", response_model=HealthResponse, tags=["ops"])
def health() -> HealthResponse:
    """Lightweight liveness/readiness probe target. Must not touch the DB
    with anything expensive -- Kubernetes calls this frequently."""
    APP_AVAILABILITY.set(1)
    return HealthResponse(status="healthy")


@app.get("/metrics", tags=["ops"])
def metrics() -> PlainTextResponse:
    """Prometheus scrape endpoint."""
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/shorten", response_model=ShortenResponse, status_code=201, tags=["url"])
def shorten_url(payload: ShortenRequest, db: Session = Depends(get_db)) -> ShortenResponse:
    short_code = shortuuid.ShortUUID().random(length=7)
    record = URLMapping(short_code=short_code, original_url=str(payload.url))
    db.add(record)
    db.commit()
    db.refresh(record)

    URLS_SHORTENED_TOTAL.inc()
    logger.info("url shortened", extra={"short_code": short_code})

    return ShortenResponse(
        short_code=record.short_code,
        short_url=f"{BASE_SHORT_URL}/{record.short_code}",
        original_url=record.original_url,
        created_at=record.created_at,
    )


@app.get("/{short_code}", tags=["url"])
def redirect_short_url(short_code: str, db: Session = Depends(get_db)) -> RedirectResponse:
    record = db.query(URLMapping).filter(URLMapping.short_code == short_code).first()
    if not record:
        raise HTTPException(status_code=404, detail="Short URL not found")
    return RedirectResponse(url=record.original_url, status_code=307)

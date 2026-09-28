"""
Structured (JSON) logging configuration.

Every log line is emitted as JSON so it can be shipped to CloudWatch /
any log aggregator and queried by field. We never log secrets: passwords,
DB credentials, AWS credentials are never passed into the logger.
"""
import logging
import sys

from pythonjsonlogger import jsonlogger

REQUEST_LOG_FIELDS = (
    "timestamp",
    "log_level",
    "method",
    "endpoint",
    "status_code",
    "response_time_ms",
    "request_id",
    "error_message",
)


def configure_logging() -> logging.Logger:
    logger = logging.getLogger("urlshortener")
    logger.setLevel(logging.INFO)

    if logger.handlers:
        return logger  # already configured (e.g. reload)

    handler = logging.StreamHandler(sys.stdout)
    formatter = jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
        rename_fields={"asctime": "timestamp", "levelname": "log_level"},
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    return logger


logger = configure_logging()

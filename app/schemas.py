import datetime

from pydantic import AnyUrl, BaseModel, Field


class ShortenRequest(BaseModel):
    url: AnyUrl = Field(..., description="The original URL to shorten")


class ShortenResponse(BaseModel):
    short_code: str
    short_url: str
    original_url: str
    created_at: datetime.datetime

    class Config:
        from_attributes = True


class HealthResponse(BaseModel):
    status: str

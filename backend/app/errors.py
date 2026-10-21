from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


class DomainError(Exception):
    status_code = 400

    def __init__(self, code: str, message: str | None = None):
        super().__init__(code)
        self.code = code
        self.message = message


class BadRequest(DomainError):
    status_code = 400


class NotFound(DomainError):
    status_code = 404

    def __init__(self, code: str = "not_found", message: str | None = None):
        super().__init__(code, message)


class Forbidden(DomainError):
    status_code = 403


class Conflict(DomainError):
    status_code = 409


class TooManyRequests(DomainError):
    status_code = 429


class PaymentProviderError(DomainError):
    status_code = 502


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(DomainError)
    async def _domain_error(_: Request, exc: DomainError) -> JSONResponse:
        body = {"detail": exc.code}
        if exc.message:
            body["message"] = exc.message
        return JSONResponse(status_code=exc.status_code, content=body)

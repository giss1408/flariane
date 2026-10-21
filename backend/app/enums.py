from enum import StrEnum


class OrderStatus(StrEnum):
    QUOTE_REQUESTED = "QUOTE_REQUESTED"
    QUOTED = "QUOTED"
    AWAITING_PAYMENT = "AWAITING_PAYMENT"
    PAID = "PAID"
    PURCHASED = "PURCHASED"
    IN_TRANSIT = "IN_TRANSIT"
    ARRIVED = "ARRIVED"
    READY_FOR_PICKUP = "READY_FOR_PICKUP"
    PICKED_UP = "PICKED_UP"
    CANCELLED = "CANCELLED"
    REFUND_PENDING = "REFUND_PENDING"
    REFUNDED = "REFUNDED"


class QuoteStatus(StrEnum):
    DRAFT = "DRAFT"
    SENT = "SENT"
    ACCEPTED = "ACCEPTED"
    CHANGE_REQUESTED = "CHANGE_REQUESTED"
    EXPIRED = "EXPIRED"
    SUPERSEDED = "SUPERSEDED"


class PaymentStatus(StrEnum):
    INITIATED = "INITIATED"
    PENDING = "PENDING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    EXPIRED = "EXPIRED"
    REFUNDED = "REFUNDED"
    HELD = "HELD"  # amount/currency mismatch, needs manual review


class ItemStatus(StrEnum):
    OK = "OK"
    CANCELLED_BY_STORE = "CANCELLED_BY_STORE"
    MISSING = "MISSING"


class RefundStatus(StrEnum):
    PENDING = "PENDING"
    COMPLETED = "COMPLETED"


class ShipmentStatus(StrEnum):
    OPEN = "OPEN"
    IN_TRANSIT = "IN_TRANSIT"
    ARRIVED = "ARRIVED"


class AdminRole(StrEnum):
    VIEWER = "VIEWER"
    OPERATOR = "OPERATOR"
    SUPER_ADMIN = "SUPER_ADMIN"


ROLE_RANK = {AdminRole.VIEWER: 0, AdminRole.OPERATOR: 1, AdminRole.SUPER_ADMIN: 2}

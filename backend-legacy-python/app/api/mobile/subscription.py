"""Mobile subscription status."""

from fastapi import APIRouter

router = APIRouter(prefix="/subscription")


@router.get("")
async def get_subscription_status():
    """Get subscription status for authenticated user."""
    # TODO: check StoreKit receipt, return status
    return {"status": "trial", "days_left": 7}


@router.post("/verify")
async def verify_receipt(signed_transaction: str):
    """Verify App Store receipt."""
    # TODO: use app-store-server-library to verify
    return {"verified": False, "reason": "not_implemented"}

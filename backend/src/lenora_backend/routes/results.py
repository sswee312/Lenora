from fastapi import APIRouter, Request
from fastapi.responses import FileResponse

router = APIRouter()


@router.get("/results/{result_id}")
async def get_result(result_id: str, request: Request) -> FileResponse:
    stored = await request.app.state.results.open(result_id)
    # ponytail: a sweep can delete the file between open and send only after 24 h; that rare race returns a 500.
    return FileResponse(stored.path, media_type=stored.content_type, headers={"Cache-Control": "no-store"})

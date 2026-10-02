import asyncio
import time

import httpx
import pytest

from lenora_backend.kinds import AssetInput, JobRequest, UploadRequest
from lenora_adapter_cloudinary import CloudinaryAdapter, CloudinarySettings

pytestmark = pytest.mark.live
SAMPLE = "https://res.cloudinary.com/demo/image/upload/sample.jpg"


def test_upload_then_remove_background():
    async def scenario():
        async with httpx.AsyncClient(timeout=60) as http:
            adapter = CloudinaryAdapter(CloudinarySettings(), http)
            model = "cloudinary/background-removal"
            ticket = await adapter.create_upload(model, UploadRequest(model=model, contentType="image/jpeg", byteCount=1, filename="s.jpg"))
            upload = await http.post(str(ticket.ticket.url), data={**ticket.ticket.fields, "file": SAMPLE})
            assert upload.status_code == 200, upload.text
            job = await adapter.submit(model, JobRequest(kind="image.removeBackground", model=model,
                                                         inputs=[AssetInput(assetRef=ticket.assetRef)]))
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                state = await adapter.status(job.jobId)
                if state.status != "running":
                    return state
                await asyncio.sleep(state.retryAfter or 2)
            pytest.fail("background removal did not finish in 120 s")

    state = asyncio.run(scenario())
    assert state.status == "succeeded", state.error
    assert httpx.get(str(state.results[0].url)).headers["content-type"] == "image/png"

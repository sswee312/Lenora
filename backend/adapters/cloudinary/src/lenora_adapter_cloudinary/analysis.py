"""Tagging, analysis, enhancement, and crop jobs for subscribed Cloudinary add-ons."""
import uuid

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    Estimate, ImageAnalyzeParams, ImageCropParams, JobError, JobRequest, JobState, SubmittedJob,
)
from lenora_adapter_cloudinary.account import ANALYSIS_BY_ID, DELIVERY_BY_ID
from lenora_adapter_cloudinary.api import error_message, parse_ref, problem
from lenora_adapter_cloudinary.delivery import encode_url_job, signed_url
from lenora_adapter_cloudinary.generation import failed, running

ADDON_ESTIMATE = Estimate(amount=0, unit="addon")
REQUIRED = {
    "prompt": "AI Vision needs a prompt.",
    "tags": "AI Vision tagging needs tags, each with a name and a description.",
    "questions": "AI Vision moderation needs questions.",
}


def _require(adapter, addon: str, name: str) -> None:
    if addon not in adapter.account.enabled:
        raise ProblemError("provider_unavailable", (
            f"This Cloudinary account doesn't include {name}. "
            "Subscribe to it in the Cloudinary console, then use Test Connection."
        ), retryable=False)


def _analysis_of(body: dict) -> dict | None:
    data = body.get("data") if isinstance(body.get("data"), dict) else {}
    analysis = data.get("analysis")
    return analysis if isinstance(analysis, dict) else None


def _succeeded(job_id: str, analysis: dict) -> JobState:
    return JobState(jobId=job_id, status="succeeded", analysis=analysis)


async def submit(adapter, job: JobRequest) -> SubmittedJob:
    spec = ANALYSIS_BY_ID.get(job.model)
    if spec is None:
        raise ProblemError("unknown_model", f"No analysis model '{job.model}'.")
    _require(adapter, spec.addon, spec.display_name)
    params = ImageAnalyzeParams.model_validate(job.params)
    if spec.requires and getattr(params, spec.requires) is None:
        raise ProblemError("invalid_request", REQUIRED[spec.requires])
    ref = parse_ref(job.inputs[0], "image")
    if spec.mode == "explicit":
        response = await adapter.api.explicit(ref.public_id, str(int(adapter.clock())),
                                              {"categorization": spec.endpoint})
        if response.status_code != 200:
            raise problem(response)
        info = (response.json().get("info") or {}).get("categorization")
        if not isinstance(info, dict):
            raise ProblemError("provider_error", "Cloudinary returned no tags.", retryable=True)
        analysis = {"categorization": info, "tags": response.json().get("tags") or []}
    else:
        asset = await adapter.api.asset(ref)
        body: dict = {"source": {"asset_id": asset.asset_id}}
        if params.prompt:
            body["prompts"] = [params.prompt]
        if params.tags:
            body["tag_definitions"] = [tag.model_dump() for tag in params.tags]
        if params.questions:
            body["rejection_questions"] = params.questions
        response = await adapter.api.analyze(spec.endpoint, body)
        if response.status_code == 202:
            task_id = (response.json().get("data") or {}).get("task_id")
            if not isinstance(task_id, str) or not task_id:
                raise ProblemError("provider_error", "Cloudinary accepted the analysis without a task id.", retryable=True)
            analysis_id = str(uuid.uuid4())
            adapter.store.insert_analysis(analysis_id, spec.endpoint, task_id, None, adapter.clock())
            return SubmittedJob(jobId=f"an:{analysis_id}", status="queued", estimate=ADDON_ESTIMATE)
        if response.status_code != 200:
            raise problem(response)
        analysis = _analysis_of(response.json())
        if analysis is None:
            raise ProblemError("provider_error", "Cloudinary returned no analysis.", retryable=True)
    analysis_id = str(uuid.uuid4())
    adapter.store.insert_analysis(analysis_id, spec.endpoint, None, analysis, adapter.clock())
    return SubmittedJob(jobId=f"an:{analysis_id}", status="queued", estimate=ADDON_ESTIMATE)


async def status(adapter, job_id: str, analysis_id: str) -> JobState:
    row = adapter.store.analysis(analysis_id)
    if row is None:
        raise ProblemError("not_found", "Unknown job.")
    if row.result is not None:
        return _succeeded(job_id, row.result)
    response = await adapter.api.analysis_task(row.task_id)
    if response.status_code != 200:
        raise problem(response)
    body = response.json()
    data = body.get("data") if isinstance(body.get("data"), dict) else {}
    state = data.get("status")
    if state in ("pending", "processing"):
        return running(job_id)
    if state == "failed":
        detail = data.get("error")
        message = detail["message"] if isinstance(detail, dict) and isinstance(detail.get("message"), str) else error_message(response)
        return JobState(jobId=job_id, status="failed", error=JobError(code="provider_error", message=message, retryable=False))
    analysis = data.get("analysis")
    if not isinstance(analysis, dict):
        nested = data.get("result")
        analysis = nested.get("analysis") if isinstance(nested, dict) else None
    if not isinstance(analysis, dict):
        return failed(job_id, "Analysis finished without a result.")
    adapter.store.save_analysis(analysis_id, analysis)
    return _succeeded(job_id, analysis)


def submit_delivery(adapter, job: JobRequest) -> SubmittedJob:
    spec = DELIVERY_BY_ID.get(job.model)
    if spec is None:
        raise ProblemError("unknown_model", f"No delivery add-on '{job.model}'.")
    _require(adapter, spec.addon, spec.display_name)
    ref = parse_ref(job.inputs[0], "image")
    if spec.kind == "image.crop":
        aspect = ImageCropParams.model_validate(job.params).aspectRatio
        transformation = f"ar_{aspect},c_fill,g_imagga_crop"
    else:
        transformation = "e_viesus_correct"
    secret = adapter.settings.api_secret.get_secret_value()
    url = signed_url(adapter.settings.cloud_name, "image", transformation, f"{ref.public_id}.png", secret)
    adapter.budget.reserve(ADDON_ESTIMATE)
    return SubmittedJob(jobId=encode_url_job(url), status="queued", estimate=ADDON_ESTIMATE)

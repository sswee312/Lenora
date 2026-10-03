import pytest
from pydantic import ValidationError

from typing import get_args

from lenora_backend.kinds import (
    REWRITE_TARGET_PROMPTS, AssetInput, ImageEditParams, ImageGenerateParams, JobState, RewritePromptParams,
    RewriteTarget, SpeechParams, VideoGenerateParams, VideoReframeParams, input_problem,
)

REF = "image/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d"


def ref(role=None):
    return AssetInput(assetRef=REF, role=role)


@pytest.mark.parametrize("prompt, ok", [
    ("a" * 100, True), ("a" * 101, False), ("", False), ("the red car", True), ("it's a dog-like cat.", True),
    ("car,boat", False), ("car;to_boat", False), ("a/b", False), ("a:b", False), ("a_b", False), ("café", False),
])
def test_url_prompt_allowlist(prompt, ok):
    params = {"op": "remove", "prompt": prompt}
    if ok:
        ImageEditParams.model_validate(params)
    else:
        with pytest.raises(ValidationError):
            ImageEditParams.model_validate(params)


@pytest.mark.parametrize("params", [
    {"op": "fill", "aspectRatio": "16:9"},
    {"op": "replace", "from": "cat", "to": "dog"},
    {"op": "remove", "prompt": "the cup"},
    {"op": "recolor", "prompt": "the car", "color": "#00ff00"},
    {"op": "backgroundReplace"},
    {"op": "backgroundReplace", "prompt": "a beach"},
    {"op": "restore"},
])
def test_each_edit_op_parses(params):
    assert ImageEditParams.model_validate(params).root.op == params["op"]


@pytest.mark.parametrize("params", [
    {"op": "sharpen"}, {"op": "fill"}, {"op": "restore", "extra": 1}, {"op": "recolor", "prompt": "x", "color": "red"},
])
def test_bad_edit_params_are_rejected(params):
    with pytest.raises(ValidationError):
        ImageEditParams.model_validate(params)


@pytest.mark.parametrize("duration, resolution, ok", [
    (8, "1080p", True), (6, "1080p", False), (4, "720p", True), (5, "720p", False),
])
def test_video_generate_duration_rules(duration, resolution, ok):
    params = {"prompt": "p", "duration": duration, "resolution": resolution}
    if ok:
        VideoGenerateParams.model_validate(params)
    else:
        with pytest.raises(ValidationError):
            VideoGenerateParams.model_validate(params)


def test_image_generate_bounds():
    with pytest.raises(ValidationError):
        ImageGenerateParams.model_validate({"prompt": "p", "count": 5})
    with pytest.raises(ValidationError):
        ImageGenerateParams.model_validate({"prompt": "p", "seed": -1})
    with pytest.raises(ValidationError):
        VideoReframeParams.model_validate({"aspectRatio": "2:1"})


@pytest.mark.parametrize("kind, inputs, problem", [
    ("video.generate", [], None),
    ("video.generate", [ref("startFrame"), ref("endFrame"), ref("reference"), ref("reference")], None),
    ("video.generate", [ref("endFrame")], "needs a startFrame"),
    ("video.generate", [ref("startFrame"), ref("startFrame")], "at most 1 startFrame"),
    ("video.generate", [ref("reference")] * 3, "at most 2 reference"),
    ("video.generate", [ref()], "at most 0 unlabelled"),
    ("image.generate", [ref("reference")] * 4, None),
    ("image.generate", [ref("reference")] * 5, "at most 4 reference"),
    ("image.edit", [], "needs 1 input"),
    ("image.edit", [ref(), ref()], "at most 1 unlabelled"),
    ("image.upscale", [ref("startFrame")], "at most 0 startFrame"),
])
def test_input_roles(kind, inputs, problem):
    found = input_problem(kind, inputs)
    assert (found is None) if problem is None else (problem in found)


@pytest.mark.parametrize("params, ok", [
    ({}, True), ({"outputs": {}}, True), ({"outputs": {"vertical": "9:16", "teaserSeconds": 15}}, True),
    ({"outputs": {"teaserSeconds": 5}}, True), ({"outputs": {"teaserSeconds": 30}}, True),
    ({"outputs": {"teaserSeconds": 4}}, False), ({"outputs": {"teaserSeconds": 31}}, False),
    ({"outputs": {"vertical": "16:9"}}, False), ({"outputs": {"poster": False}}, False), ({"extra": 1}, False),
])
def test_publish_params(params, ok):
    from lenora_backend.kinds import VideoPublishParams
    if ok:
        VideoPublishParams.model_validate(params)
    else:
        with pytest.raises(ValidationError):
            VideoPublishParams.model_validate(params)


@pytest.mark.parametrize("count, problem", [(0, True), (1, False), (2, True)])
def test_publish_takes_exactly_one_input(count, problem):
    assert (input_problem("video.publish", [ref()] * count) is not None) == problem


@pytest.mark.parametrize("params, ok", [
    ({"prompt": "Hello."}, True),
    ({"prompt": "a" * 4096, "voice": "nova", "styleInstructions": "", "format": "wav"}, True),
    ({"prompt": ""}, False),
    ({"prompt": "a" * 4097}, False),
    ({"prompt": "Hi", "styleInstructions": "a" * 1001}, False),
    ({"prompt": "Hi", "format": "ogg"}, False),
    ({"prompt": "Hi", "voice": ""}, False),
    ({"prompt": "Hi", "speed": 1.2}, False),
])
def test_speech_params(params, ok):
    if ok:
        assert SpeechParams.model_validate(params).format in ("mp3", "wav")
    else:
        with pytest.raises(ValidationError):
            SpeechParams.model_validate(params)


@pytest.mark.parametrize("params, ok", [
    ({"text": "a cat", "targetKind": "image.generate"}, True),
    ({"text": "a" * 4096, "targetKind": "audio.speech", "guidance": "shorter"}, True),
    ({"text": "", "targetKind": "image.generate"}, False),
    ({"text": "a" * 4097, "targetKind": "audio.speech"}, False),
    ({"text": "a cat", "targetKind": "audio.music"}, False),
    ({"text": "a cat", "targetKind": "image.generate", "guidance": "a" * 501}, False),
])
def test_rewrite_prompt_params(params, ok):
    if ok:
        RewritePromptParams.model_validate(params)
    else:
        with pytest.raises(ValidationError):
            RewritePromptParams.model_validate(params)


def test_every_rewrite_target_has_a_prompt_rule():
    assert set(get_args(RewriteTarget)) == set(REWRITE_TARGET_PROMPTS)


@pytest.mark.parametrize("target, text, ok", [
    ("image.generate", "a" * 1000, True), ("image.generate", "a" * 1001, False), ("video.generate", "a" * 1001, False),
    ("audio.speech", "a" * 4096, True), ("audio.speech", "a" * 4097, False),
    ("image.edit", "red car", True), ("image.edit", "red, shiny car", False), ("image.edit", "a" * 101, False),
])
def test_rewrite_target_prompt_rules(target, text, ok):
    if ok:
        assert REWRITE_TARGET_PROMPTS[target].validate_python(text) == text
    else:
        with pytest.raises(ValidationError):
            REWRITE_TARGET_PROMPTS[target].validate_python(text)


@pytest.mark.parametrize("kind", ["audio.speech", "text.rewritePrompt"])
def test_text_kinds_take_no_inputs(kind):
    assert input_problem(kind, []) is None
    assert input_problem(kind, [ref()]) is not None


def test_job_state_text_is_omitted_unless_set():
    assert "text" not in JobState(jobId="j", status="running").model_dump(mode="json")
    assert JobState(jobId="j", status="succeeded", text="A cat.").model_dump(mode="json")["text"] == "A cat."

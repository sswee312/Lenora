import pytest
from pydantic import ValidationError

from lenora_backend.kinds import (
    AssetInput, ImageEditParams, ImageGenerateParams, VideoGenerateParams, VideoReframeParams, input_problem,
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

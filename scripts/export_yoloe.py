"""Builds the on-device object detector from the word list.

Reads CoachCam/Resources/vocabulary.json, bakes those words into a YOLOE open-vocabulary
model, and writes CoachCam/Resources/Models/yoloe.mlpackage (Core ML).

The words are baked in at export time, so the app can't change them on the phone:
edit vocabulary.json and push, and the build workflow re-runs this (cached otherwise).
Runs on a GitHub macOS runner; Core ML conversion doesn't work on Windows.

License: YOLOE / Ultralytics are AGPL-3.0, fine for a personal, non-distributed app.
"""
import json
import shutil
from pathlib import Path

from ultralytics import YOLOE

ROOT = Path(__file__).resolve().parents[1]
VOCAB = ROOT / "CoachCam" / "Resources" / "vocabulary.json"
DEST = ROOT / "CoachCam" / "Resources" / "Models" / "yoloe.mlpackage"

vocab = json.loads(VOCAB.read_text(encoding="utf-8"))
names = [n.strip() for n in vocab["names"] if n.strip()]
weights = vocab.get("model", "yoloe-26s-seg.pt")
print(f"Model {weights}, {len(names)} words")

model = YOLOE(weights)
try:
    model.set_classes(names)
except TypeError:
    # Older Ultralytics API needs the text embeddings passed explicitly.
    model.set_classes(names, model.get_text_pe(names))

exported = Path(model.export(format="coreml", imgsz=640, half=True, nms=False))
print("Exported:", exported)

DEST.parent.mkdir(parents=True, exist_ok=True)
shutil.rmtree(DEST, ignore_errors=True)
shutil.move(str(exported), str(DEST))

# Print the model's inputs/outputs so the Swift decoder can be checked against them.
import coremltools as ct

spec = ct.models.MLModel(str(DEST), skip_model_load=True).get_spec()
print("=== MODEL DESCRIPTION ===")
print(spec.description)

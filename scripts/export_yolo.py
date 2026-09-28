"""Exports YOLO11n (COCO, 80 classes) to a Core ML .mlpackage with built-in NMS.

Runs on a GitHub macOS runner (see .github/workflows/export-model.yml); Core ML
conversion doesn't work on Windows. With nms=True, Vision returns ready-made
VNRecognizedObjectObservation results (label + confidence + box).

License note: YOLO11 is AGPL-3.0, which is fine for a personal, non-distributed app.
"""
from ultralytics import YOLO

model = YOLO("yolo11n.pt")  # Downloaded automatically from Ultralytics.
path = model.export(format="coreml", nms=True, imgsz=640, half=True)
print("Exported:", path)

"""Research job: exports the prompt-free YOLOE models (built-in ~4,585-name vocabulary)
to Core ML, prints their real size, and checks which everyday words the vocabulary covers.

Nothing here goes into the app yet; it only answers "how big, and does it know keys?".
Writes pf-report.txt and yoloe-26{n,s}-pf.mlpackage (zipped by the workflow).
"""
import shutil
from pathlib import Path

from ultralytics import YOLOE

WANTED = ["key", "keys", "charger", "charging block", "power adapter", "earbud", "earphone", "airpods",
          "wallet", "sunglasses", "water bottle", "bottle", "shoe", "sneaker", "laptop", "pasta", "noodle",
          "pizza", "burger", "salad", "sushi", "coffee cup", "mug", "phone", "cellphone", "mobile phone",
          "backpack", "handbag", "watch", "headphone", "remote", "lipstick", "perfume", "candle", "umbrella",
          "mirror", "stairs", "bench", "bicycle", "cake", "croissant", "taco", "ramen", "dumpling", "fries"]

lines = []
for scale in ["n", "s"]:
    name = f"yoloe-26{scale}-seg-pf.pt"
    model = YOLOE(name)
    names = [str(v).lower() for v in model.names.values()]
    lines.append(f"== {name}: {len(names)} names ==")
    for word in WANTED:
        hits = [n for n in names if word in n]
        lines.append(f"  {word:<16} {'YES' if hits else 'no ':<4} {', '.join(hits[:6])}")
    Path(f"pf-names-26{scale}.txt").write_text("\n".join(names), encoding="utf-8")

    exported = Path(model.export(format="coreml", imgsz=640, half=True, nms=False))
    dest = Path(f"yoloe-26{scale}-pf.mlpackage")
    shutil.rmtree(dest, ignore_errors=True)
    shutil.move(str(exported), str(dest))
    size = sum(f.stat().st_size for f in dest.rglob("*") if f.is_file()) / 1e6
    lines.append(f"  Core ML size: {size:.1f} MB")

    import coremltools as ct
    spec = ct.models.MLModel(str(dest), skip_model_load=True).get_spec()
    for out in spec.description.output:
        shape = list(out.type.multiArrayType.shape)
        lines.append(f"  output {out.name}: {shape}")

report = "\n".join(lines)
print(report)
Path("pf-report.txt").write_text(report, encoding="utf-8")

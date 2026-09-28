"""Builds the on-device person-type model (apparent age group + gender) from FairFace.

FairFace (github.com/joojs/fairface, CC BY 4.0): ResNet-34 trained on a face dataset
balanced across ethnicities. Its final layer has 18 outputs: 7 race, 2 gender, 9 age.

PRIVACY: the race outputs are cut out of the network here, so the app's model cannot
compute them at all. Only gender (2) and age group (9) remain.

Output "probs" (11 numbers):
  [0] male, [1] female                                   (softmax)
  [2..10] age 0-2, 3-9, 10-19, 20-29, 30-39, 40-49, 50-59, 60-69, 70+   (softmax)

Writes CoachCam/Resources/Models/PersonTypeModel.mlpackage (not 'PersonType': Xcode generates a Swift class named after the model, which would clash with the PersonType enum). Run once on a GitHub macOS runner.
"""
from pathlib import Path

import coremltools as ct
import gdown
import torch
import torchvision
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "CoachCam" / "Resources" / "Models" / "PersonTypeModel.mlpackage"
WEIGHTS = Path("res34_fair_align_multi_7_20190809.pt")

if not WEIGHTS.exists():
    gdown.download(id="11y0Wi3YQf21a_VcspUV4FwqzhMcfaVAB", output=str(WEIGHTS), quiet=False)

full = torchvision.models.resnet34(weights=None)
full.fc = torch.nn.Linear(full.fc.in_features, 18)
full.load_state_dict(torch.load(WEIGHTS, map_location="cpu"))
full.eval()

# Keep only rows 7..17 of the final layer (gender + age). Race rows 0..6 are dropped.
fc = torch.nn.Linear(full.fc.in_features, 11)
with torch.no_grad():
    fc.weight.copy_(full.fc.weight[7:18])
    fc.bias.copy_(full.fc.bias[7:18])
full.fc = fc


class GenderAge(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        logits = self.net(x)
        gender = torch.softmax(logits[:, 0:2], dim=1)
        age = torch.softmax(logits[:, 2:11], dim=1)
        return torch.cat([gender, age], dim=1)


model = GenderAge(full).eval()
example = torch.rand(1, 3, 224, 224)
traced = torch.jit.trace(model, example)

# ImageNet normalisation folded into the input (one shared std is close enough).
std = 0.226
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / (255 * std),
                         bias=[-0.485 / std, -0.456 / std, -0.406 / std],
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="probs")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,
)
# 8-bit weights: about half the size, negligible accuracy change.
mlmodel = linear_quantize_weights(
    mlmodel, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric")))
mlmodel.short_description = ("FairFace ResNet-34 (CC BY 4.0). Apparent gender + age group only; "
                             "race outputs removed.")
mlmodel.author = "FairFace: Karkkainen & Joo (2021)"
mlmodel.license = "CC BY 4.0"

DEST.parent.mkdir(parents=True, exist_ok=True)
mlmodel.save(str(DEST))
print("Saved", DEST)
print(mlmodel.get_spec().description)

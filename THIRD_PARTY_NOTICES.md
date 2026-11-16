# Third-party licenses and assets

The original application source is AGPL-3.0-only. Third-party models and assets retain their own terms; the complete distribution is not licensed uniformly under AGPL.

## MAGI

Upstream model: https://huggingface.co/ragavsachdeva/magi/tree/15ad498ad45093ad3b833d625728220c6309ad99
Model card license: https://huggingface.co/ragavsachdeva/magi/blob/15ad498ad45093ad3b833d625728220c6309ad99/README.md#license-and-citation
Author: Ragav Sachdeva and Andrew Zisserman (University of Oxford).
The original model card permits personal, research, non-commercial and not-for-profit use; other uses require contacting its author. This installation retains the original trained panel/text/dialogue detector, omitting OCR and character matching. This does not replace its upstream licensing terms. Upstream source files are downloaded separately with pinned source checksums.

## Bubble/panel segmentation

Inspected weight: https://github.com/nonillion-studios/manga-inpainter/blob/b967ab723edc4420e71a87cd199d5817f048c344/best.pt
SHA256: 60fe35d6664c71084edd6a56738ed10ca4fae2052fab21faaa7f43f401a39d84
The repository LICENSE is Apache-2.0, but the actual checkpoint embeds Ultralytics AGPL-3.0 metadata. Its task is instance segmentation and runtime names are bubble/panel/sfx/text. Do not infer unrestricted proprietary/commercial model rights from the repository license. The reviewed upstream source is available at the pinned repository; no LaMa/inpainting pipeline is used. The setup script installs the model from the pinned release bundle for packaging in the Android APK.

Ultralytics export environment 8.4.210: https://github.com/ultralytics/ultralytics/tree/v8.4.210
Original licensing: https://github.com/ultralytics/ultralytics/blob/v8.4.210/LICENSE
Ultralytics is under AGPL-3.0 with separately offered commercial terms. Android inference uses ExecuTorch rather than the Python Ultralytics runtime. Other export dependencies retain their own licenses; tools/requirements-export.txt records the export environment versions.

## Suki Manga startup assets

Acme Regular by Huerta Tipografica, distributed under the SIL Open Font License 1.1. Font and license are bundled in app/assets/branding/Acme-Regular.ttf and Acme-OFL.txt. Source: https://github.com/google/fonts/tree/main/ofl/acme .

The ten startup covers were retrieved from MangaDex; individual title and cover URLs and selection date are recorded in app/assets/branding/cover_sources.json. Cover artwork remains the property of its respective rights holders.

Runtime dependencies: Flutter/Dart (BSD-3-Clause), AndroidX (Apache-2.0), OpenCV (Apache-2.0), ExecuTorch (BSD-3-Clause); see their upstream distributions for full notices. The source-model bundle retains MAGI README.md and pinned source files. The bubble model is conservatively treated as AGPL-3.0, including the linked export source. Cover artwork is not relicensed by this repository.

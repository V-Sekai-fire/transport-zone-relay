# interactor-muscle-drive

Muscle-driven rollout of retargeted Kimodo/SOMA clips on MS-Human-700 (MuJoCo Menagerie) with MuscleMimic.

Pipeline: Kimodo/SOMA30 clip, then `retarget_msh700.py` (interactor-garment-proxy) gives MS-Human-700 qpos, then
`scripts/msh700_trajectory.py` (musclemimic branch `dev/msh700`) converts the pelvis to a free root and resamples to 100 Hz
with makima, then the `MsHuman700MyoFullBody` environment tracks it.

Set `MSH700_XML` to `ms_human_700/MS-Human-700.xml`. Training needs Linux with an NVIDIA GPU (WSL2 on the Windows desk).
No gated Hugging Face data is used.

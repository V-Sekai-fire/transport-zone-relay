"""Contact sheet of a converted MS-Human-700 clip: side view (x forward, z up), floor line, mimic sites and colliding foot capsules.

  MSH700_XML=.../MS-Human-700.xml uv run --no-project --with mujoco --with numpy --with matplotlib python contact_sheet.py clip.npz out.png [--frames=24] [--cols=6]

Pure matplotlib (no OpenGL). Each cell labels the frame, the time, and the lowest colliding point's height above the floor in mm
(red when under -1 mm or over 20 mm). The skeleton is the 17 mimic sites joined along the body; capsules are the colliding foot geoms.
"""

import importlib.util
import os
import pathlib
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import mujoco
import numpy as np

_here = pathlib.Path(__file__).resolve().parent
_root = _here.parents[1] / "3-interactor/musclemimic/musclemimic/environments/humanoids/ms_human_700_root.py"
_s = importlib.util.spec_from_file_location("ms_human_700_root", _root)
root = importlib.util.module_from_spec(_s)
_s.loader.exec_module(root)
_pf = importlib.util.spec_from_file_location("plant_feet", _here / "plant_feet.py")
plant_feet = importlib.util.module_from_spec(_pf)
_pf.loader.exec_module(plant_feet)

SITES = {"pelvis": "pelvis_mimic", "lumbar1": "upper_body_mimic", "head_neck": "head_mimic", "humerus_l": "left_shoulder_mimic",
         "ulna_l": "left_elbow_mimic", "hand_l": "left_hand_mimic", "humerus_r": "right_shoulder_mimic", "ulna_r": "right_elbow_mimic",
         "hand_r": "right_hand_mimic", "femur_l": "left_hip_mimic", "tibia_l": "left_knee_mimic", "talus_l": "left_ankle_mimic",
         "toes_l": "left_toes_mimic", "femur_r": "right_hip_mimic", "tibia_r": "right_knee_mimic", "talus_r": "right_ankle_mimic",
         "toes_r": "right_toes_mimic"}
EDGES = [("pelvis", "lumbar1"), ("lumbar1", "head_neck"), ("lumbar1", "humerus_l"), ("humerus_l", "ulna_l"), ("ulna_l", "hand_l"),
         ("lumbar1", "humerus_r"), ("humerus_r", "ulna_r"), ("ulna_r", "hand_r"), ("pelvis", "femur_l"), ("femur_l", "tibia_l"),
         ("tibia_l", "talus_l"), ("talus_l", "toes_l"), ("pelvis", "femur_r"), ("femur_r", "tibia_r"), ("tibia_r", "talus_r"),
         ("talus_r", "toes_r")]
LEFT = {"humerus_l", "ulna_l", "hand_l", "femur_l", "tibia_l", "talus_l", "toes_l"}


def capsule_ends(m, d, g):
    R, p, s = d.geom_xmat[g].reshape(3, 3), d.geom_xpos[g], m.geom_size[g]
    return p - R[:, 2] * s[1], p + R[:, 2] * s[1], s[0]


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    n = next((int(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--frames=")), 24)
    cols = next((int(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--cols=")), 6)
    src, dst = args
    spec = mujoco.MjSpec.from_file(os.environ["MSH700_XML"])
    root.prepare_spec(spec, SITES)
    m = spec.compile()
    d = mujoco.MjData(m)
    z = np.load(src)
    q, hz = z["qpos"], float(z["frequency"])
    idx = np.linspace(0, len(q) - 1, n).astype(int)
    colliding = [g for g in range(m.ngeom) if (m.geom_contype[g] or m.geom_conaffinity[g]) and m.geom_type[g] != mujoco.mjtGeom.mjGEOM_PLANE]
    caps = [g for g in colliding if m.geom_type[g] == mujoco.mjtGeom.mjGEOM_CAPSULE and m.body(m.geom_bodyid[g]).name.split("_")[0] in ("calcn", "toes")]
    sid = {b: m.site(s).id for b, s in SITES.items()}
    # fixed window: horizontal travel follows the pelvis, vertical from the floor to 1.8 m
    rows = int(np.ceil(n / cols))
    fig, axes = plt.subplots(rows, cols, figsize=(2.3 * cols, 2.3 * rows), squeeze=False)
    for ax, f in zip(axes.flat, idx):
        d.qpos[:] = q[f]
        mujoco.mj_forward(m, d)
        low = min(plant_feet.lowest_geom_z(m, d, g) for g in colliding) * 1000
        x0 = d.site_xpos[sid["pelvis"]][0]
        ax.axhline(0, color="0.4", lw=1)
        for g in caps:
            a, b, r = capsule_ends(m, d, g)
            ax.plot([a[0], b[0]], [a[2], b[2]], color="tab:orange", lw=max(r * 700, 2), alpha=0.5, solid_capstyle="round")
        for a, b in EDGES:
            pa, pb = d.site_xpos[sid[a]], d.site_xpos[sid[b]]
            ax.plot([pa[0], pb[0]], [pa[2], pb[2]], color="tab:blue" if a in LEFT or b in LEFT else "tab:green", lw=1.4)
        ax.set_xlim(x0 - 0.8, x0 + 0.8)
        ax.set_ylim(-0.1, 1.8)
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        bad = low < -1.0 or low > 20.0
        ax.set_title(f"f{f} {f / hz:.2f}s  low {low:+.1f} mm", fontsize=7, color="red" if bad else "black")
    for ax in list(axes.flat)[n:]:
        ax.axis("off")
    fig.suptitle(f"{pathlib.Path(src).name}   blue = left, green = right, orange = colliding foot capsules", fontsize=9)
    fig.tight_layout()
    fig.savefig(dst, dpi=90)
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()

"""Convert a folder of retargeted clips (<clip>.qpos.npy + .qpos.json from retarget_msh700.py) to 100 Hz MuscleMimic trajectories.

  MSH700_XML=.../MS-Human-700.xml pixi run python batch_to_100hz.py <qpos dir> <out dir> [--fps=F]

Per clip: pelvis to a free `root` joint, makima to 100 Hz at the json's `fps` (or --fps when the json has none; with neither it stops), qvel from
mj_differentiatePos, then ground_clip's root lift where a frame penetrates the floor (upsampling adds 2 to 6 mm). Writes
<out dir>/<clip>.npz (qpos, qvel, joint_names, jnt_type, frequency, split_points) and summary.tsv with the floor numbers before
and after grounding and the share of floating frames (lowest colliding point over 20 mm), which a flight phase legitimately has.
"""

import importlib.util
import json
import pathlib
import sys

import mujoco
import numpy as np

_here = pathlib.Path(__file__).resolve().parent
_mm = _here.parents[1] / "3-interactor/musclemimic/scripts/msh700_trajectory.py"
_s = importlib.util.spec_from_file_location("msh700_trajectory", _mm)
conv = importlib.util.module_from_spec(_s)
_s.loader.exec_module(conv)

from ground_clip import ground  # noqa: E402
from penetration_check import clearance, penetration  # noqa: E402
from musclemimic.environments.humanoids.ms_human_700 import MsHuman700MyoFullBody  # noqa: E402


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    explicit_fps = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--fps=")), None)
    src, dst = pathlib.Path(args[0]), pathlib.Path(args[1])
    dst.mkdir(parents=True, exist_ok=True)
    import os

    xml = os.environ["MSH700_XML"]
    m6 = mujoco.MjModel.from_xml_path(xml)
    mf, pos, quat = conv.free_model(xml)
    env_model = MsHuman700MyoFullBody()._model  # carries the floor plane and the mimic sites
    rows = ["clip\tsrc_fps\tsrc_frames\tframes_100\tseconds\tpen_mm\tpen_frames_over_1mm\tgrounded_pen_mm\tlift_mean_mm\tlift_max_mm\tfloating_frac"]
    for q_path in sorted(src.glob("*.qpos.npy")):
        name = q_path.name[: -len(".qpos.npy")]
        meta_path = q_path.with_name(name + ".qpos.json")
        if meta_path.exists() and "fps" in json.load(open(meta_path)):
            fps = float(json.load(open(meta_path))["fps"])
        elif explicit_fps is not None:
            fps = explicit_fps
        else:
            raise SystemExit(f"{name}: no fps in {meta_path.name} and no --fps given; a wrong rate would stretch the clip")
        q6 = np.load(q_path)
        qf = conv.convert(m6, mf, pos, quat, q6)
        qpos = conv.resample(qf, fps)
        qvel = conv.velocities(mf, qpos)
        _, pf = penetration(env_model, qpos)
        gq, lift = ground(env_model, qpos)
        _, pf2 = penetration(env_model, gq)
        qvel = np.zeros((len(gq), mf.nv))
        for i in range(len(gq) - 1):
            mujoco.mj_differentiatePos(mf, qvel[i], 1.0 / conv.CONTROL_HZ, gq[i], gq[i + 1])
        qvel[-1] = qvel[-2]
        floating = float((clearance(env_model, gq) > 0.02).mean())
        names = [mf.joint(j).name for j in range(mf.njnt)]
        np.savez(dst / f"{name}.npz", qpos=gq, qvel=qvel, joint_names=np.array(names), jnt_type=mf.jnt_type.copy(),
                 frequency=conv.CONTROL_HZ, split_points=np.array([0, len(gq)]))
        rows.append(f"{name}\t{fps:g}\t{len(q6)}\t{len(gq)}\t{len(gq) / conv.CONTROL_HZ:.2f}\t{pf.max() * 1000:.1f}\t{(pf > 0.001).mean():.2f}\t{pf2.max() * 1000:.1f}\t{lift.mean() * 1000:.1f}\t{lift.max() * 1000:.1f}\t{floating:.3f}")
        print(rows[-1], flush=True)
    (dst / "summary.tsv").write_text("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()

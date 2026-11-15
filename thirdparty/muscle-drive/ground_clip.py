"""Lift a converted MS-Human-700 clip so no foot sinks into the floor.

  MSH700_XML=.../MS-Human-700.xml pixi run python ground_clip.py in.traj.npz out.traj.npz

The retarget fits 17 site positions only, so the foot's pitch is free and the colliding foot capsules can end up 2 cm underground
even when the ankle and toe targets sit at the right height. Per frame, the root is raised by the deepest floor penetration
(iterated, since contacts change with height). Frames without penetration are not touched, so feet are never pushed down.
Velocities are recomputed from the grounded positions with mj_differentiatePos.
"""

import sys

import mujoco
import numpy as np

from musclemimic.environments.humanoids.ms_human_700 import MsHuman700MyoFullBody

ROOT_Z = 2  # free joint qpos: x, y, z, then wxyz


def deepest_penetration(m, d, floor) -> float:
    return max([-c.dist for c in d.contact if c.geom1 in floor or c.geom2 in floor] + [0.0])


def ground(m, qpos, iters: int = 4):
    d = mujoco.MjData(m)
    floor = {g for g in range(m.ngeom) if m.geom_type[g] == mujoco.mjtGeom.mjGEOM_PLANE}
    out, lift = qpos.copy(), np.zeros(len(qpos))
    for i in range(len(qpos)):
        for _ in range(iters):
            d.qpos[:] = out[i]
            mujoco.mj_forward(m, d)
            pen = deepest_penetration(m, d, floor)
            if pen <= 1e-5:
                break
            out[i, ROOT_Z] += pen
            lift[i] += pen
    return out, lift


def main() -> None:
    src, dst = sys.argv[1:3]
    m = MsHuman700MyoFullBody()._model
    z = np.load(src)
    q, lift = ground(m, z["qpos"])
    hz = float(z["frequency"])
    qvel = np.zeros((len(q), m.nv))
    for i in range(len(q) - 1):
        mujoco.mj_differentiatePos(m, qvel[i], 1.0 / hz, q[i], q[i + 1])
    qvel[-1] = qvel[-2]
    np.savez(dst, **{**dict(z), "qpos": q, "qvel": qvel})
    print(f"wrote {dst}: root lift mean {lift.mean() * 1000:.1f} mm, max {lift.max() * 1000:.1f} mm, frames lifted {(lift > 1e-5).mean():.0%}")


if __name__ == "__main__":
    main()

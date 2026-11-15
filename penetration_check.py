"""Floor penetration of a converted MS-Human-700 clip, per body.

  MSH700_XML=.../MS-Human-700.xml pixi run python penetration_check.py walk.traj.npz [more.npz ...]

Replays each frame's qpos in the environment model (kinematics only) and reports, per body, the deepest floor contact and the
number of frames over 1 mm. Gates: max penetration <= 2 mm and under 5 percent of frames over 1 mm; and no floating: the lowest colliding point of the whole body
stays within 20 mm of the floor in all but --allow-flight=F of the frames, and the clip touches the floor (within 5 mm) at least once.
"""

import collections
import sys

import mujoco
import numpy as np

from musclemimic.environments.humanoids.ms_human_700 import MsHuman700MyoFullBody
from plant_feet import lowest_geom_z

MAX_PEN, MAX_FRAC, TOUCH = 0.002, 0.05, 0.001  # [m], fraction, [m]
FLOAT_HEIGHT = 0.02  # [m] lowest colliding point above this counts as floating in that frame
NEVER_TOUCH = 0.005  # [m] a clip whose lowest point never gets under this hovers the whole time


def clearance(m, qpos):
    """(F,) height of the lowest colliding point of the whole body above z = 0 [m], any pose (standing, crouching, prone)."""
    d = mujoco.MjData(m)
    geoms = [g for g in range(m.ngeom) if (m.geom_contype[g] or m.geom_conaffinity[g]) and m.geom_type[g] != mujoco.mjtGeom.mjGEOM_PLANE]
    out = np.zeros(len(qpos))
    for i, q in enumerate(qpos):
        d.qpos[:] = q
        mujoco.mj_forward(m, d)
        out[i] = min(lowest_geom_z(m, d, g) for g in geoms)
    return out


def penetration(m, qpos):
    d = mujoco.MjData(m)
    floor = {g for g in range(m.ngeom) if m.geom_type[g] == mujoco.mjtGeom.mjGEOM_PLANE}
    worst, per_frame = collections.defaultdict(float), np.zeros(len(qpos))
    for i, q in enumerate(qpos):
        d.qpos[:] = q
        mujoco.mj_forward(m, d)
        for c in d.contact:
            if c.geom1 in floor or c.geom2 in floor:
                g = c.geom2 if c.geom1 in floor else c.geom1
                b = m.body(m.geom_bodyid[g]).name
                worst[b] = max(worst[b], -c.dist)
                per_frame[i] = max(per_frame[i], -c.dist)
    return dict(worst), per_frame


def main() -> None:
    m = MsHuman700MyoFullBody()._model
    ok = True
    allow = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--allow-flight=")), 0.0)  # fraction of frames that may float
    for path in [a for a in sys.argv[1:] if not a.startswith("--")]:
        q = np.load(path)["qpos"]
        clr = clearance(m, q)
        floating = float((clr > FLOAT_HEIGHT).mean())
        hover = clr.min() > NEVER_TOUCH
        fgate = floating <= allow and not hover
        ok &= fgate
        print(f"{path}: lowest point height min {clr.min() * 1000:.1f} mm, median {np.median(clr) * 1000:.1f} mm, floating frames (>{FLOAT_HEIGHT * 1000:.0f} mm) {floating:.0%} (allowed {allow:.0%}){' NEVER TOUCHES THE FLOOR' if hover else ''} -> {'PASS' if fgate else 'FAIL'}")
        worst, pf = penetration(m, q)
        frac = float((pf > TOUCH).mean())
        gate = pf.max() <= MAX_PEN and frac < MAX_FRAC
        ok &= gate
        by = ", ".join(f"{b} {w * 1000:.1f}" for b, w in sorted(worst.items(), key=lambda kv: -kv[1])[:4])
        print(f"{path}: max {pf.max() * 1000:.1f} mm, frames over 1 mm {frac:.0%} | deepest by body [mm]: {by} -> {'PASS' if gate else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

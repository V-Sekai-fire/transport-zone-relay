"""Retarget solve with a floor term: the colliding foot capsules stay above z = 0.

retarget_msh700.py (interactor-garment-proxy, dev/retarget-msh700) fits 17 site positions, so foot pitch is free and the foot
capsules sink ~2 cm. FloorRig subclasses its Rig and adds, per colliding capsule on the calcn and toes bodies, a one-sided penalty
sum(max(0, MARGIN - z)^2) on both capsule bottom end points (end point z minus radius), with the analytic gradient from mj_jac.
It does not edit the retarget script; pass the directory that holds it.

  MSH700_XML=.../MS-Human-700.xml pixi run python floor_solve.py <retarget dir> <motion/mm dir> walk out.qpos.npy

Gate (penetration_check.py on the converted clip, no grounding): max 2 mm and under 5 percent of frames over 1 mm.
"""

import os
import sys

import mujoco
import numpy as np
from scipy.optimize import minimize

W_FLOOR = 100.0  # [-] weight of the floor penalty against the squared site error (both in m^2)
MARGIN = 0.001  # [m] keep the capsule bottoms this far above the floor, above the 1 mm contact gate


def foot_capsules(m):
    """(geom id, body id) of colliding capsules on calcn_* and toes_* bodies."""
    out = []
    for g in range(m.ngeom):
        b = m.body(m.geom_bodyid[g]).name
        if m.geom_type[g] == mujoco.mjtGeom.mjGEOM_CAPSULE and (m.geom_contype[g] or m.geom_conaffinity[g]) and b.split("_")[0] in ("calcn", "toes"):
            out.append((g, int(m.geom_bodyid[g])))
    return out


def make_floor_rig(retarget_module):
    class FloorRig(retarget_module.Rig):
        def __init__(self, xml):
            super().__init__(xml)
            self.caps = foot_capsules(self.m)
            assert self.caps, "no colliding foot capsules"

        def floor_terms(self):
            """Penalty value and its gradient over the free joints, after mj_kinematics and mj_comPos."""
            m, d = self.m, self.d
            val, grad = 0.0, np.zeros(len(self.free))
            jp = np.zeros((3, m.nv))
            for g, b in self.caps:
                R, p = d.geom_xmat[g].reshape(3, 3), d.geom_xpos[g]
                half, rad = m.geom_size[g][1], m.geom_size[g][0]
                for sign in (-1.0, 1.0):
                    pt = p + sign * R[:, 2] * half
                    viol = MARGIN - (pt[2] - rad)
                    if viol > 0:
                        mujoco.mj_jac(m, d, jp, None, pt, b)
                        val += viol * viol
                        grad += -2.0 * viol * jp[2, self.free]
            return val, grad

        def solve(self, targets, bounded=True, tag=""):
            m, d, F = self.m, self.d, targets.shape[0]
            q, x = np.zeros((F, m.nq)), np.zeros(len(self.free))
            bounds = list(zip(self.lo, self.hi)) if bounded else None
            if bounds:
                bounds[:3] = [(None, None)] * 3  # root slides carry no anatomical range
            lp, lz = retarget_module.LAMBDA_PREV, retarget_module.LAMBDA_ZERO
            for f in range(F):
                tgt, prev = targets[f].reshape(-1), x.copy()

                def fun(v):
                    d.qpos[:] = 0.0
                    d.qpos[self.free] = v
                    mujoco.mj_kinematics(m, d)
                    s, J = self.sites_jac()  # calls mj_comPos
                    r = s.reshape(-1) - tgt
                    fv, fg = self.floor_terms()
                    val = r @ r + lp * np.sum((v - prev) ** 2) + lz * np.sum(v**2) + W_FLOOR * fv
                    return val, 2 * J.T @ r + 2 * lp * (v - prev) + 2 * lz * v + W_FLOOR * fg

                if f == 0:
                    d.qpos[:] = 0.0
                    mujoco.mj_kinematics(m, d)
                    s, J = self.sites_jac()
                    x[:3] = np.linalg.lstsq(J[:3, :3], tgt[:3] - s[0], rcond=None)[0]
                res = minimize(fun, x, jac=True, method="L-BFGS-B", bounds=bounds, options={"maxiter": 400, "ftol": 1e-14, "gtol": 1e-9})
                x = res.x
                q[f, self.free] = x
            return q

    return FloorRig


def main() -> None:
    rdir, mdir, clip_name, out = sys.argv[1:5]
    sys.path.insert(0, rdir)
    argv, sys.argv = sys.argv, ["x"]
    import retarget_msh700 as R

    sys.argv = argv
    rig = make_floor_rig(R)(os.environ["MSH700_XML"])
    names = open(os.path.join(mdir, "skeleton.txt")).read().split()
    parents = [int(x) for x in open(os.path.join(mdir, "parents.txt")).read().split()]
    P, Rr = R.soma_fk(R.load_clip(mdir, clip_name), parents)
    P = np.einsum("ij,fnj->fni", R.C @ R.yaw_matrix(Rr[0, 0]), P)
    S = R.soma_sites(P, names)
    T = R.build_targets(S, R.segment_scales(rig, S))
    from plant_feet import foot_floor_heights, plant_feet

    ix = {n: i for i, n in enumerate(R.SITE_NAMES)}
    feet = {s: {"ankle": ix[f"{s}_ankle"], "toes": ix[f"{s}_toes"], "hip": ix[f"{s}_hip"]} for s in "lr"}
    h = foot_floor_heights(rig.m)
    leg = float(np.mean([np.linalg.norm(rig.rest[ix[f"{s}_hip"]] - rig.rest[ix[f"{s}_knee"]]) + np.linalg.norm(rig.rest[ix[f"{s}_knee"]] - rig.rest[ix[f"{s}_ankle"]]) for s in "lr"]))
    T, planted, unreachable = plant_feet(T, feet, h["ankle"], leg, R.segment_scales(rig, S)["root"], toes_floor_z=h["toes"])
    print(f"planted frames {planted.sum(0)}, unreachable {unreachable.sum()}")
    q = rig.solve(T)
    e = R.site_errors(rig.site_track(q), T)
    print(f"site err mean max {e.mean(0).max():.4f} m, p99 max {np.percentile(e, 99, axis=0).max():.4f} m, flexion gate {R.flexion_gate(R.range_report(rig, q))[0]}")
    np.save(out, q)


if __name__ == "__main__":
    main()

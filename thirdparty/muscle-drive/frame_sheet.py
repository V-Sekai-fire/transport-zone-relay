"""Frame-by-frame side-view sheet of a retargeted qpos.npy (the 6-joint pelvis layout of retarget_msh700.py) with optional stair boxes.

  MSH700_XML=... python frame_sheet.py <clip.qpos.npy> <out.png> --frames=30-46 [--colliders=colliders.json --flight=a] [--cols=6] [--lane=Y (model y of the stair lane)] [--caps=1 to show the colliding capsules] [--az=90] [--dist=2.6] [--nomuscles=1 for the bones only] [--mwidth=0.003]

Side view (x forward, z up): the visual bone meshes and all 700 muscles (spatial tendons, red) rendered by MuJoCo (MUJOCO_GL=cgl on macOS), the stairs of one flight (grey boxes),
and each cell's title with the deepest foot point under the ground in mm (red over 2 mm).
"""
import json, os, pathlib, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import mujoco
import numpy as np

P = pathlib.Path(__file__).resolve().parents[1] / "garment-proxy" / "prototype"
sys.path.insert(0, str(P))
import retarget_msh700 as R  # noqa: E402

EDGES = [("pelvis", "spine1"), ("spine1", "head"), ("head", "skull"), ("spine1", "l_shoulder"), ("l_shoulder", "l_elbow"), ("l_elbow", "l_wrist"),
         ("spine1", "r_shoulder"), ("r_shoulder", "r_elbow"), ("r_elbow", "r_wrist"), ("pelvis", "l_hip"), ("l_hip", "l_knee"), ("l_knee", "l_ankle"),
         ("l_ankle", "l_toes"), ("pelvis", "r_hip"), ("r_hip", "r_knee"), ("r_knee", "r_ankle"), ("r_ankle", "r_toes")]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opt = {a[2:].split("=")[0]: a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--") and "=" in a}
    q = np.load(args[0])
    lo, hi = (int(x) for x in opt["frames"].split("-"))
    frames = list(range(lo, min(hi, len(q) - 1) + 1))
    cols = int(opt.get("cols", 6)); zoom = float(opt.get("zoom", 0.9))
    rig = R.Rig(os.environ["MSH700_XML"]); m, d = rig.m, rig.d
    ground, boxes = None, []
    if "colliders" in opt:
        raw = [c["prim"] for c in json.load(open(opt["colliders"]))["colliders"] if c["name"].startswith(f"Stairs_{opt['flight']}")]
        boxes = [(-p[3] - p[6], -p[3] + p[6], p[2] + p[5], -p[1] - p[4], -p[1] + p[4]) for p in raw]  # model x range, top and model y range of each step

        def ground(xy):
            return max([t for a, b, t, ya, yb in boxes if a <= xy[0] <= b and ya <= xy[1] <= yb] + [0.0])  # only under the lane, as the gate does
    rows = int(np.ceil(len(frames) / cols))
    fig, axes = plt.subplots(rows, cols, figsize=(2.8 * cols, 2.8 * rows), squeeze=False)
    rend = mujoco.Renderer(m, 360, 360)
    cam = mujoco.MjvCamera(); cam.type = mujoco.mjtCamera.mjCAMERA_FREE; cam.azimuth, cam.elevation, cam.distance = float(opt.get("az", 90)), 0.0, float(opt.get("dist", 2.6))
    opt_v = mujoco.MjvOption(); opt_v.geomgroup[:] = 0; opt_v.geomgroup[0] = 1  # the visual meshes
    m.tendon_rgba[:] = [0.78, 0.12, 0.12, 1.0]  # the 700 muscles are spatial tendons: draw them all
    m.tendon_width[:] = float(opt.get("mwidth", 0.003))
    opt_v.flags[mujoco.mjtVisFlag.mjVIS_TENDON] = 0 if "nomuscles" in opt else 1
    if "caps" in opt:
        m.geom_rgba[m.geom_group == 1] = [1.0, 0.55, 0.1, 0.3]  # the colliding skin capsules, orange
        opt_v.geomgroup[1] = 1  # the colliding capsules too
    for ax, f in zip(axes.flat, frames):
        d.qpos[:] = q[f]; mujoco.mj_kinematics(m, d); mujoco.mj_tendon(m, d)  # the muscle paths
        s_ = rig.sites(); cam.lookat[:] = [s_[0][0], 0.0 if not boxes else s_[0][1], float(opt.get('lookz', 0.75))]
        rend.update_scene(d, cam, opt_v)
        sc = rend.scene
        for a, b, t, _y0, _y1 in boxes:  # the stairs and the floor, as boxes across the lane
            if sc.ngeom >= sc.maxgeom:
                break
            if t <= 0:
                continue
            mujoco.mjv_initGeom(sc.geoms[sc.ngeom], mujoco.mjtGeom.mjGEOM_BOX, np.array([(b - a) / 2, 0.6, t / 2]), np.array([(a + b) / 2, float(opt.get("lane", 0.0)), t / 2]), np.eye(3).ravel(), np.array([0.85, 0.85, 0.9, 1.0], np.float32))
            sc.geoms[sc.ngeom].emission = 0.8
            sc.ngeom += 1
        mujoco.mjv_initGeom(sc.geoms[sc.ngeom], mujoco.mjtGeom.mjGEOM_BOX, np.array([40.0, 3.0, 0.01]), np.array([s_[0][0], float(opt.get("lane", 0.0)), -0.01]), np.eye(3).ravel(), np.array([0.55, 0.6, 0.55, 1.0], np.float32)); sc.geoms[sc.ngeom].emission = 0.5; sc.ngeom += 1
        ax.imshow(rend.render()); ax.set_xticks([]); ax.set_yticks([])
        worst = 0.0
        for g, _ in rig.caps:
            Rg, p = d.geom_xmat[g].reshape(3, 3), d.geom_xpos[g]; half, rad = m.geom_size[g][1], m.geom_size[g][0]
            for sg in (-1, 1):
                pt = p + sg * Rg[:, 2] * half
                worst = max(worst, (ground(pt[:2]) if ground else 0.0) - (pt[2] - rad))
        ax.set_title(f"f{f}  under {worst*1000:+.1f} mm", fontsize=7, color="red" if worst > 0.002 else "black")
    for ax in list(axes.flat)[len(frames):]:
        ax.axis("off")
    fig.suptitle(f"{pathlib.Path(args[0]).name}  frames {lo}-{hi}", fontsize=9)
    fig.tight_layout(); fig.savefig(args[1], dpi=90); print("wrote", args[1])


if __name__ == "__main__":
    main()

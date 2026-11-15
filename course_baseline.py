"""Baseline of the 100 Hz MS-Human-700 clips against the obstacle course of entities-model-explorer (colliders.json), station by station.

  MSH700_XML=.../MS-Human-700.xml pixi run python course_baseline.py <100hz dir> <colliders.json> [out.tsv]

The clips are free-space trajectories, so this measures what a station asks of the body and what the clips offer:
  duck-under bar   underside height  -> the tallest point of the body in each crouch clip must clear it
  tunnel           roof height       -> the tallest point of each crawl clip must clear it
  jump gap         gap width         -> the longest flight (the lowest colliding point over 5 mm) must travel at least gap + 0.25 m (a foot length)
  stairs / ramps   step rise         -> the swing foot's clearance (p99 toe height, walk clips) must reach the highest step
Course metres are for a 1.75 m person; the model is scaled by its standing height / 1.75 (printed). Tallest point = max over geoms of the rotated box top.
"""
import importlib.util, json, os, pathlib, sys
import mujoco
import numpy as np

_here = pathlib.Path(__file__).resolve().parent
_root = _here.parents[1] / "3-interactor/musclemimic/musclemimic/environments/humanoids/ms_human_700_root.py"
_s = importlib.util.spec_from_file_location("ms_human_700_root", _root); root = importlib.util.module_from_spec(_s); _s.loader.exec_module(root)
_pf = importlib.util.spec_from_file_location("plant_feet", _here / "plant_feet.py"); pf = importlib.util.module_from_spec(_pf); _pf.loader.exec_module(pf)
SITES = {"head_neck": "head_mimic", "toes_l": "left_toes_mimic", "toes_r": "right_toes_mimic", "pelvis": "pelvis_mimic"}


def station_numbers(path):
    cs = json.load(open(path))["colliders"]
    by = {}
    for c in cs:
        by.setdefault(c["name"].split("_")[0], []).append(c["prim"])
    bar = [p for p in by["Beam"] if p[0] == 2 or p[5] == 0.1]
    beam_under = min(p[2] - p[5] for p in by["Beam"] if p[2] > 1.0)  # the crossbar: centre y - half height
    tunnel_roof = min(p[2] - p[5] for p in by["Tunnel"] if p[0] == 2)
    pn, pf = by["PlatformNear"][0], by["PlatformFar"][0]
    gap = abs(pf[3] - pn[3]) - (pn[6] + pf[6])
    tops = sorted({round(p[2] + p[5], 3) for p in by["Stairs"]})
    return dict(beam_under=beam_under, tunnel_roof=tunnel_roof, gap=gap, top_step=max(np.diff([0.0] + tops)))  # the highest single rise


def body_top(m, d):
    """Tallest point of the body: the top of every geom's rotated box (planes excluded)."""
    top = -9.0
    for g in range(m.ngeom):
        if m.geom_type[g] == mujoco.mjtGeom.mjGEOM_PLANE:
            continue
        c, h = m.geom_aabb[g, :3], m.geom_aabb[g, 3:]
        R = d.geom_xmat[g].reshape(3, 3)
        top = max(top, d.geom_xpos[g][2] + (R @ c)[2] + np.abs(R[2]) @ h)
    return top


def main():
    src, cj = pathlib.Path(sys.argv[1]), sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else None
    st = station_numbers(cj)
    spec = mujoco.MjSpec.from_file(os.environ["MSH700_XML"]); root.prepare_spec(spec, SITES); m = spec.compile(); d = mujoco.MjData(m)
    sid = {k: m.site(v).id for k, v in SITES.items()}
    cap = [g for g in range(m.ngeom) if (m.geom_contype[g] or m.geom_conaffinity[g]) and m.geom_type[g] != mujoco.mjtGeom.mjGEOM_PLANE]
    stand = np.load(next(src.glob("kimodo-locomotion/idle.npz")))["qpos"][0]
    d.qpos[:] = stand; mujoco.mj_forward(m, d); sc = body_top(m, d) / 1.75
    print(f"standing height {body_top(m, d):.3f} m, course scale {sc:.3f}; stations (scaled): bar {st['beam_under']*sc:.2f}, roof {st['tunnel_roof']*sc:.2f}, gap {st['gap']*sc:.2f}, top step {st['top_step']*sc:.2f}")
    rows = ["dataset\tclip\tstation\tneeded\tclip_value\tpass"]
    for f in sorted(src.glob("*/*.npz")):
        name, ds = f.stem, f.parent.name
        kind = ("crawl" if name.startswith("crawl") else "crouch" if "crouch" in name else "jump" if "jump" in name else "walk" if name.startswith("walk") or "walk" in name else None)
        if kind is None:
            continue
        q = np.load(f)["qpos"]
        idx = np.arange(0, len(q), 5 if kind != "jump" else 2)
        tops, toes, lows, pel = [], [], [], []
        for i in idx:
            d.qpos[:] = q[i]; mujoco.mj_forward(m, d)
            tops.append(body_top(m, d)); toes.append(min(d.site_xpos[sid["toes_l"]][2], d.site_xpos[sid["toes_r"]][2]))
            lows.append(min(pf.lowest_geom_z(m, d, g) for g in cap) if kind == "jump" else 0); pel.append(d.site_xpos[sid["pelvis"]][:2].copy())
        tops, lows = np.array(tops), np.array(lows)
        if kind == "crouch":
            need = st["beam_under"] * sc; val = float(np.percentile(tops, 99)); ok = val <= need; stn = "duck-under bar (max body height <= bar)"
        elif kind == "crawl":
            need = st["tunnel_roof"] * sc; val = float(np.percentile(tops, 99)); ok = val <= need; stn = "tunnel roof (max body height <= roof)"
        elif kind == "jump":
            air = np.array([t > 0.02 for t in [np.min(r) for r in [[0]] ]]) if False else None
            floor_lift = np.array([x for x in lows])
            flying = floor_lift > 0.005
            best, run = 0.0, None
            for k, fl in enumerate(flying):
                if fl and run is None: run = k
                if (not fl or k == len(flying) - 1) and run is not None:
                    best = max(best, float(np.linalg.norm(pel[k] - pel[run]))); run = None
            need = st["gap"] * sc + 0.25; val = best; ok = val >= need; stn = "jump gap (longest flight travel >= gap + 0.25)"
        else:
            need = st["top_step"] * sc; val = float(np.percentile(toes, 99)); ok = val >= need; stn = "stairs top step (p99 toe height >= step)"
        rows.append(f"{ds}\t{name}\t{stn}\t{need:.2f}\t{val:.2f}\t{'PASS' if ok else 'FAIL'}"); print(rows[-1], flush=True)
    if out:
        pathlib.Path(out).write_text("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()

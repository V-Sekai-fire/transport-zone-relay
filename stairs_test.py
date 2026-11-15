"""Walk a clip up a stair flight of the obstacle course with the foot planter, and check the feet against the stairs.

  MSH700_XML=.../MS-Human-700.xml python stairs_test.py <motion dir> <colliders.json> <clip> <flight a|b|c> [--fps=30] [--flat] [--place] [--restart] [--out=DIR]

The clip's site targets are placed at the foot of the flight, planted with plant_feet.py on a flat floor (planted flags and locked
touchdown positions), then each planted foot is shifted along x to the middle of one tread (a stride cannot straddle a riser) and lifted onto the stairs: a planted foot rests on the step under it, a swinging foot clears the riser ahead by
3 cm, and the body rises with the higher planted foot. The retarget solve uses the stairs as its floor (Rig.ground).
Gates: (1) site error mean <= 0.03 m against the lifted targets; (2) no colliding foot capsule point under the stairs by more than 2 mm;
(3) the foot reaches the flight's highest step. --flat is the control: the same clip walked flat (targets not lifted), which must fail 2.
"""
import importlib.util, json, os, pathlib, sys
import numpy as np

P = pathlib.Path(__file__).resolve().parents[1] / "garment-proxy" / "prototype"
sys.path.insert(0, str(P))
import retarget_msh700 as R  # noqa: E402
from plant_feet import foot_floor_heights, plant_feet  # noqa: E402

FLIGHT_X = {"a": 1.4, "b": 0.0, "c": -1.4}  # Godot x of each lane; model y = -x, model x = -z
TREAD, FOOT_MID = 0.3, 0.073  # [m] tread depth of the course; ankle to the middle of the foot
APPROACH = 1.2  # [m] walk-in before the first step


def stairs_ground(colliders, flight):
    boxes = [c["prim"] for c in json.load(open(colliders))["colliders"] if c["name"].startswith(f"Stairs_{flight}")]

    def h(xy):
        gx, gz = -xy[1], -xy[0]
        best = 0.0
        for p in boxes:
            if abs(gx - p[1]) <= p[4] and abs(gz - p[3]) <= p[6]:
                best = max(best, p[2] + p[5])
        return best

    return h, max(p[2] + p[5] for p in boxes), -min(p[3] - p[6] for p in boxes)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    mdir, cj, clip_name, flight = args[:4]
    fps = next((float(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--fps=")), 30.0)
    out = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--out=")), None)
    flat = "--flat" in sys.argv
    h, top, z_start = stairs_ground(cj, flight)
    first_edge = min(-p["prim"][3] - p["prim"][6] for p in json.load(open(cj))["colliders"] if p["name"].startswith(f"Stairs_{flight}"))
    rig = R.Rig(os.environ["MSH700_XML"])
    names = open(os.path.join(mdir, "skeleton.txt")).read().split()
    parents = [int(x) for x in open(os.path.join(mdir, "parents.txt")).read().split()]
    clip = R.load_clip(mdir, clip_name)
    Pw, Rr = R.soma_fk(clip, parents)
    Pw = np.einsum("ij,fnj->fni", R.C @ R.yaw_matrix(Rr[0, 0]), Pw)
    S = R.soma_sites(Pw, names)
    sc = R.segment_scales(rig, S)
    T = R.build_targets(S, sc)
    ix = {n: i for i, n in enumerate(R.SITE_NAMES)}
    feet = {s: {"ankle": ix[f"{s}_ankle"], "toes": ix[f"{s}_toes"], "hip": ix[f"{s}_hip"]} for s in "lr"}
    fh = foot_floor_heights(rig.m)
    leg = float(np.mean([np.linalg.norm(rig.rest[ix[f"{s}_hip"]] - rig.rest[ix[f"{s}_knee"]]) + np.linalg.norm(rig.rest[ix[f"{s}_knee"]] - rig.rest[ix[f"{s}_ankle"]]) for s in "lr"]))
    T, planted, unreachable = plant_feet(T, feet, fh["ankle"], leg, sc["root"], toes_floor_z=fh["toes"])
    T = T + np.array([first_edge - APPROACH, -FLIGHT_X[flight], 0.0])  # world: the flight's foot, its lane
    if not flat and "--place" in sys.argv:  # footstep placement: one tread per footfall, feet alternating, the body carried with them
        T_old = T.copy()
        runs = []
        for i in range(2):
            t = 0
            while t < len(T):
                if planted[t, i]:
                    u = t
                    while u < len(T) and planted[u, i]:
                        u += 1
                    runs.append((t, u, i))
                    t = u
                else:
                    t += 1
        runs.sort()
        k = -1
        lock = {0: [], 1: []}  # per foot: (start, end, x, y) of each planted run, x moved onto its tread
        for t0, t1, i in runs:
            a = feet["lr"[i]]["ankle"]
            x, y = T[t0:t1, a, 0].mean(), T[t0:t1, a, 1].mean()
            if k < 0 and x + FOOT_MID < first_edge:
                lock[i].append((t0, t1, x, y))  # still on the approach: stays where the clip put it
                continue
            k += 1
            lock[i].append((t0, t1, first_edge + (k + 0.5) * TREAD - FOOT_MID, y))
        for i in range(2):
            sd = feet["lr"[i]]
            toe_rel = T_old[:, sd["toes"]] - T_old[:, sd["ankle"]]
            ks = lock[i]
            if not ks:
                continue
            xy = T_old[:, sd["ankle"], :2].copy()
            for t in range(len(T)):
                prev = [r for r in ks if r[1] <= t]
                nxt = [r for r in ks if r[0] > t]
                inside = [r for r in ks if r[0] <= t < r[1]]
                if inside:
                    xy[t] = inside[0][2:4]
                elif prev and nxt:
                    a_, b_ = prev[-1], nxt[0]
                    u = (t - a_[1] + 1) / max(b_[0] - a_[1] + 1, 1)
                    u = u * u * (3 - 2 * u)
                    xy[t] = (1 - u) * np.array(a_[2:4]) + u * np.array(b_[2:4])
                elif nxt:
                    xy[t] = T_old[t, sd["ankle"], :2] + (np.array(nxt[0][2:4]) - T_old[nxt[0][0], sd["ankle"], :2])
                else:
                    xy[t] = T_old[t, sd["ankle"], :2] + (np.array(prev[-1][2:4]) - T_old[prev[-1][0], sd["ankle"], :2])
            T[:, sd["ankle"], :2] = xy
            T[:, sd["toes"], :2] = xy + toe_rel[:, :2]
        # the body keeps its offset to the planted foot: its shift is the shift of the foot(s) planted now, bridged across flight phases
        d_f = np.stack([T[:, feet[s_]["ankle"], 0] - T_old[:, feet[s_]["ankle"], 0] for s_ in "lr"], axis=1)
        dx = np.full(len(T), np.nan)
        for t in range(len(T)):
            if planted[t].any():
                dx[t] = d_f[t][planted[t]].mean()
        good = ~np.isnan(dx)
        dx = np.interp(np.arange(len(T)), np.flatnonzero(good), dx[good])
        dx = np.convolve(np.pad(dx, 5, mode="edge"), np.ones(11) / 11, "valid")
        foot_sites_ = [feet[s_][k_] for s_ in "lr" for k_ in ("ankle", "toes")]
        for site in range(T.shape[1]):
            if site not in foot_sites_:
                T[:, site, 0] += dx
        print(f"  footstep placement: {k + 1} treads used, runs per foot {[len(lock[0]), len(lock[1])]}, body shift {dx.min():+.2f}..{dx.max():+.2f} m")
    if not flat and "--place" not in sys.argv:  # touchdown on the treads: shift each planted run along x so the foot lies in one tread (a stride cannot straddle a riser)
        for i, s_ in enumerate("lr"):
            t = 0
            while t < len(T):
                if not planted[t, i]:
                    t += 1
                    continue
                u = t
                while u < len(T) and planted[u, i]:
                    u += 1
                mid = T[t:u, feet[s_]["ankle"], 0].mean() + FOOT_MID
                k = np.floor((mid - first_edge) / TREAD)
                if k >= 0:  # on the flight: centre the foot on tread k
                    dx = first_edge + (k + 0.5) * TREAD - FOOT_MID - T[t:u, feet[s_]["ankle"], 0].mean()
                    for site in ("ankle", "toes"):
                        T[t:u, feet[s_][site], 0] += dx
                t = u
    if not flat:
        g_foot = np.zeros((len(T), 2))
        for t in range(len(T)):
            for i, s in enumerate("lr"):
                a, k = T[t, feet[s]["ankle"]], T[t, feet[s]["toes"]]
                own = max(h(a[:2]), h(k[:2]))
                if planted[t, i]:
                    g = own
                else:
                    g = max(own, h(k[:2] + np.array([0.15, 0.0]))) + 0.03  # clear the riser ahead
                g_foot[t, i] = g
                for site in ("ankle", "toes"):
                    T[t, feet[s][site], 2] += g
        body = np.array([g_foot[t][planted[t]].max() if planted[t].any() else g_foot[t].min() for t in range(len(T))])
        body = np.convolve(np.pad(body, 5, mode="edge"), np.ones(11) / 11, "valid")  # the body rises smoothly
        foot_sites = [feet[s][k] for s in "lr" for k in ("ankle", "toes")]
        for site in range(T.shape[1]):
            if site not in foot_sites:
                T[:, site, 2] += body
    rig.ground = h
    rig.restart = "--restart" in sys.argv
    q = rig.solve(T)
    if rig.restart:
        print(f"  restarted {rig.restarts_used} of {len(T)} frames")
    err = R.site_errors(rig.site_track(q), T)
    depth = rig.floor_depth(q)
    if "--diag" in sys.argv:
        ia = ix[os.environ.get("DIAG_SITE", "l_ankle")]
        worst = np.argsort(-err[:, ia])[:10]
        for t in sorted(worst):
            hip, ank = T[t, ix["l_hip"]], T[t, ia]
            print(f"  f{t} l_ankle err {err[t, ia]:.3f} m, planted L/R {planted[t]}, target hip-ankle {np.linalg.norm(hip - ank):.3f} m (leg {leg:.3f}), ankle target z {ank[2]:.2f}, ground {h(ank[:2]):.2f}")
            sol = rig.site_track(q)[t]
            print(f"     target ankle xy {np.round(ank[:2], 2)} solved {np.round(sol[ia][:2], 2)} z {sol[ia][2]:.2f}; target pelvis {np.round(T[t, 0], 2)} solved {np.round(sol[0], 2)}")
    reach = float(max(rig.site_track(q)[:, ix["l_ankle"], 2].max(), rig.site_track(q)[:, ix["r_ankle"], 2].max()) - fh["ankle"])
    g1 = bool(err.mean(0).max() <= R.TOL_MEAN)
    g2 = bool(depth.max() <= 0.002)
    g3 = bool(reach >= 0.9 * top)
    print(f"{clip_name} flight {flight} ({'FLAT control' if flat else 'stairs'}): step top {top:.2f} m, planted L/R {planted.sum(0)}, unreachable {int(unreachable.sum())}")
    print(f"  GATE 1 site error mean max {err.mean(0).max():.4f} m ({R.SITE_NAMES[int(err.mean(0).argmax())]}): {'PASS' if g1 else 'FAIL'}")
    print(f"  GATE 2 deepest foot capsule point under the stairs {depth.max()*1000:.1f} mm: {'PASS' if g2 else 'FAIL'}")
    print(f"  GATE 3 highest ankle {reach:.2f} m above its floor height, flight top {top:.2f} m: {'PASS' if g3 else 'FAIL'}")
    if out:
        os.makedirs(out, exist_ok=True)
        np.save(os.path.join(out, f"{clip_name}.{flight}{'.flat' if flat else ''}.qpos.npy"), q)


if __name__ == "__main__":
    main()

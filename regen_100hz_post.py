"""After v2_launch: shard qpos, run batch_to_100hz.py (8 workers), penetration_check per clip, build results.tsv, compare to old."""
import os, re, subprocess, pathlib, glob, json, sys
H = pathlib.Path.home(); OUT = pathlib.Path(os.environ["MSH700_OUT"]); MC = pathlib.Path(__file__).resolve().parent
XML = str(H/"msh700-session/menagerie/ms_human_700/MS-Human-700.xml")
env = dict(os.environ, OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1", MKL_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1", MSH700_XML=XML)
if "--build" not in sys.argv:
    names = sorted(p.name[:-9] for p in (OUT/"qpos").glob("*.qpos.npy"))
    ps = []
    for i in range(8):
        d = OUT/f"shard{i}"; d.mkdir(exist_ok=True)
        for n in names[i::8]:
            for ext in ("npy", "json"):
                s = d/f"{n}.qpos.{ext}"
                if not s.exists(): s.symlink_to(OUT/"qpos"/f"{n}.qpos.{ext}")
        ps.append(subprocess.Popen(f"cd {MC} && pixi run python -u batch_to_100hz.py {d} {OUT}/traj100 > {OUT}/logs/batch{i}.log 2>&1; "
                                   f"for f in $(ls {d}/*.qpos.npy | sed 's#.*/##;s#.qpos.npy##'); do pixi run python penetration_check.py {OUT}/traj100/$f.npz > {OUT}/logs/pen_$f.log 2>&1; done",
                                   shell=True, env=env))
    for p in ps: p.wait()
# build table
clipsd = {}
for lg in glob.glob(str(OUT/"logs/w*.log")):
    cur = None
    for l in open(lg):
        m = re.match(r"\[(\S+)\] (\d+) frames: site error mean max ([\d.]+) m \((\S+)\), p99 max ([\d.]+) m", l)
        if m: cur = clipsd.setdefault(m[1], {}); cur.update(mean=m[3], p99=m[5], worst=m[4]); continue
        if cur is None: continue
        m = re.match(r"\s+GATE (\d)\b.*?(PASS|FAIL)", l)
        if m: cur["g"+m[1]] = m[2]
summ = {}
for f in glob.glob(str(OUT/"logs/batch*.log")):
    for l in open(f):
        c = l.rstrip("\n").split("\t")
        if len(c) == 11 and c[0] != "clip": summ[c[0]] = c[1:]
tsv = [l.rstrip("\n").split("\t") for l in open(os.environ["MSH700_BASELINE_TSV"])]
old = {r[1]: r for r in tsv[1:]}
order = [l.split("\t")[0].strip() for l in open(H/"/.hermes/cache/scratch/msh700-session/me-full/motion/mm/clips.tsv".lstrip("/"))]
hdr = tsv[0] + ["pen_check_floor", "pen_check_float"]
rows = []
for i, c in enumerate(order):
    d = clipsd.get(c, {}); s = summ.get(c, ["", "", "", "", "", "", "", "", "", ""])
    g = [d.get("g1", "NA"), d.get("g2", "NA"), d.get("g3", "NA")]
    allg = "PASS" if g == ["PASS"]*3 else "FAIL"
    ds = "o3de-motionmatching" if 51 <= i < 72 else "kimodo-locomotion"
    pl = open(OUT/f"logs/pen_{c}.log").read() if (OUT/f"logs/pen_{c}.log").exists() else ""
    pf = re.findall(r"-> (PASS|FAIL)", pl)
    rows.append([ds, c, allg, *g, d.get("mean", ""), d.get("p99", ""), d.get("worst", ""), *s, pf[1] if len(pf) > 1 else "NA", pf[0] if pf else "NA"])
(OUT/"results.tsv").write_text("\n".join("\t".join(r) for r in [hdr] + rows) + "\n")
npass = sum(r[2] == "PASS" for r in rows)
print("pass", npass, "of", len(rows))
for r in rows:
    if r[2] == "FAIL": print("FAIL", r[1], r[3:6], r[8])
o = {c: old[c] for c in old}
print("old pass", sum(r[2] == "PASS" for r in o.values()))
for r in rows:
    if r[1] in o and o[r[1]][2] != r[2]: print("CHANGED", r[1], o[r[1]][2], "->", r[2])
for r in rows:
    if r[1] in o and r[2] == o[r[1]][2] == "PASS" and r[-2] != "PASS": print("PENFAIL", r[1], r[-2], r[-1])
print("new", [r[1] for r in rows if r[1] not in o])

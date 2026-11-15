"""Launch retarget_msh700.py (committed) over all 75 clips, 8 workers, into $MSH700_OUT/qpos."""
import os, subprocess, heapq, time, pathlib
H = pathlib.Path.home()
HERE = pathlib.Path(__file__).resolve().parent
MM = H/".hermes/cache/scratch/msh700-session/me-full/motion/mm"
OUT = pathlib.Path(os.environ["MSH700_OUT"])
XML = H/"msh700-session/menagerie/ms_human_700/MS-Human-700.xml"
SCR = HERE.parent / "garment-proxy" / "prototype" / "retarget_msh700.py"
clips = [l.split("\t")[0].strip() for l in open(MM/"clips.tsv") if l.strip()]
GROUND = {"jumps_1", "jumps_free_roam_1"}
def fps(c): return 60 if clips.index(c) in range(51, 72) else 30
items = sorted(((os.path.getsize(MM/f"{c}.f32"), c) for c in clips), reverse=True)
W = 8; heap = [(0, i) for i in range(W)]; groups = [[] for _ in range(W)]
for sz, c in items:
    t, i = heapq.heappop(heap); groups[i].append(c); heapq.heappush(heap, (t+sz, i))
env = dict(os.environ, OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1", MKL_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")
(OUT/"start.txt").write_text(str(time.time()))
for i, g in enumerate(groups):
    sub = {}
    for c in g: sub.setdefault((fps(c), c in GROUND), []).append(c)
    cmds = [f"pixi run python -u {SCR} {XML} {MM} --clips={','.join(cs)} --skip-controls --fps={f} --out={OUT}/qpos {'--ground' if gr else ''} >> {OUT}/logs/w{i}.log 2>&1" for (f, gr), cs in sub.items()]
    subprocess.Popen(["/bin/sh", "-c", f"cd {HERE} && ({'; '.join(cmds)}); echo done > {OUT}/logs/w{i}.done"], env=env, start_new_session=True)
print("launched", len(clips))

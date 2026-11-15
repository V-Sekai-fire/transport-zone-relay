"""Foot planting for retarget targets, after interactor-xr-pilot core/src/Body.cpp (G1 body overlay).

A foot is planted while its ankle rests near the floor: height under PLANT_HEIGHT and speed under PLANT_SPEED. At touchdown the
ankle's horizontal position locks and its height snaps to the rest ankle height. The pelvis (every other site) then drops until the
planted leg reaches its foot (leg length x LEG_SLACK), as in Body.cpp. Inputs are model-frame targets (x forward, y left, z up).
Heights and speeds scale with the clip's root scale, since Body.cpp's 0.06 m and 0.01 m are in a unit-height body.
"""

import numpy as np

PLANT_HEIGHT = 0.06  # [m] ankle above ankle floor height, unit-height body (Body.cpp: ankle.y < 0.06)
PLANT_SPEED = 0.01  # [m/frame] ankle movement between frames (Body.cpp: moved < 0.01)
LEG_SLACK = 0.999  # reach limit as a fraction of thigh + shin (Body.cpp: legLength)


def planted_mask(ankle: np.ndarray, rest_ankle_z: float, scale: float) -> np.ndarray:
    """ankle (F, 3) [m] -> bool (F,): resting near the floor and slow. Frame 0 uses speed 0."""
    moved = np.r_[0.0, np.linalg.norm(np.diff(ankle, axis=0), axis=1)]
    return ((ankle[:, 2] - rest_ankle_z) < PLANT_HEIGHT * scale) & (moved < PLANT_SPEED * scale)


def lowest_geom_z(model, data, g: int) -> float:
    """Lowest world z of one geom. Capsule: end-point minus radius; sphere, box and mesh likewise."""
    import mujoco

    t, R, p, size = int(model.geom_type[g]), data.geom_xmat[g].reshape(3, 3), data.geom_xpos[g], model.geom_size[g]
    if t == mujoco.mjtGeom.mjGEOM_CAPSULE:
        return min((p + R[:, 2] * size[1])[2], (p - R[:, 2] * size[1])[2]) - size[0]
    if t == mujoco.mjtGeom.mjGEOM_SPHERE:
        return p[2] - size[0]
    if t == mujoco.mjtGeom.mjGEOM_BOX:
        corners = np.array([[a, b, c] for a in (-1, 1) for b in (-1, 1) for c in (-1, 1)]) * size
        return float((corners @ R.T + p)[:, 2].min())
    if t == mujoco.mjtGeom.mjGEOM_MESH:
        adr, num = model.mesh_vertadr[model.geom_dataid[g]], model.mesh_vertnum[model.geom_dataid[g]]
        return float((model.mesh_vert[adr : adr + num] @ R.T + p)[:, 2].min())
    raise ValueError(f"unsupported geom type {t}")


def foot_floor_heights(model) -> dict:
    """Body-origin heights at which the colliding foot geoms touch z = 0, from the model at qpos0.

    Only geoms with contype or conaffinity set count (the floor contacts these, not the visual meshes). MS-Human-700's colliding
    foot geoms are skin capsules; the calcn's lowest point sits ~12 mm and the toes' ~9 mm above the floor at qpos0.
    ankle = talus origin z - lowest colliding point of talus and calcn (heel flat); toes = toes origin z - lowest colliding point of
    the toes. Averaged over both sides [m].
    """
    import mujoco

    data = mujoco.MjData(model)
    mujoco.mj_forward(model, data)

    def low(bodies):
        zs = [lowest_geom_z(model, data, g) for g in range(model.ngeom)
              if model.body(model.geom_bodyid[g]).name in bodies and (model.geom_contype[g] or model.geom_conaffinity[g])]
        if not zs:
            raise ValueError(f"no colliding geoms on {sorted(bodies)}")
        return min(zs)

    ankle = [data.body(f"talus_{s}").xpos[2] - low({f"talus_{s}", f"calcn_{s}"}) for s in "lr"]
    toes = [data.body(f"toes_{s}").xpos[2] - low({f"toes_{s}"}) for s in "lr"]
    return {"ankle": float(np.mean(ankle)), "toes": float(np.mean(toes))}


def plant_feet(T: np.ndarray, feet: dict, rest_ankle_z: float, leg_length: float, scale: float, toes_floor_z: float = 0.0):
    """Lock planted ankles and drop the rest of the body to reach them.

    T: targets (F, S, 3) [m]. rest_ankle_z / toes_floor_z: heights of the ankle and toes body origins when the foot rests on the
    floor, from `foot_floor_heights`; no ankle or toe target goes below them in any frame. feet: per side {"ankle": k, "toes": k, "hip": k} site indices. leg_length [m] is thigh + shin of the
    model. Returns (T', planted (F, 2) bool, unreachable (F,) bool). T is not modified.
    """
    T = T.copy()
    F = T.shape[0]
    planted = np.zeros((F, len(feet)), bool)
    lock = {}
    for i, f in enumerate(feet.values()):
        planted[:, i] = planted_mask(T[:, f["ankle"]], rest_ankle_z, scale)
        run = None
        for t in range(F):
            if planted[t, i]:
                if run is None:
                    run = T[t, f["ankle"], :2].copy()  # touchdown position
                lock[(t, i)] = run
            else:
                run = None
    for f in feet.values():  # swing feet cannot dive through the floor either
        T[:, f["ankle"], 2] = np.maximum(T[:, f["ankle"], 2], rest_ankle_z)
        T[:, f["toes"], 2] = np.maximum(T[:, f["toes"], 2], toes_floor_z)
    foot_sites = {s for f in feet.values() for s in (f["ankle"], f["toes"])}
    others = [s for s in range(T.shape[1]) if s not in foot_sites]
    reach = LEG_SLACK * leg_length
    unreachable = np.zeros(F, bool)
    for t in range(F):
        drop = 0.0
        for i, f in enumerate(feet.values()):
            if not planted[t, i]:
                continue
            xy = lock[(t, i)]
            toe_off = T[t, f["toes"]] - T[t, f["ankle"]]
            T[t, f["ankle"], :2], T[t, f["ankle"], 2] = xy, rest_ankle_z
            T[t, f["toes"], :2] = xy + toe_off[:2]
            T[t, f["toes"], 2] = max(T[t, f["toes"], 2], toes_floor_z)
            flat = float(np.sum((T[t, f["hip"], :2] - xy) ** 2))
            if flat < reach**2:
                drop = max(drop, T[t, f["hip"], 2] - (rest_ankle_z + np.sqrt(reach**2 - flat)))
            else:
                unreachable[t] = True
        if drop > 0:
            T[t, others, 2] -= drop
    return T, planted, unreachable

import numpy as np

from plant_feet import plant_feet

FEET = {"l": {"ankle": 1, "toes": 2, "hip": 0}, "r": {"ankle": 4, "toes": 5, "hip": 3}}
REST, LEG = 0.08, 0.8  # sites: 0 l_hip, 1 l_ankle, 2 l_toes, 3 r_hip, 4 r_ankle, 5 r_toes, 6 pelvis


def clip(F=30):
    T = np.zeros((F, 7, 3))
    T[:, 0] = T[:, 3] = [0, 0, 0.9]
    T[:, 6] = [0, 0, 0.95]
    T[:, 1] = [0.0, 0.1, REST + 0.01]  # left foot rests (small jitter added by the caller)
    T[:, 2] = T[:, 1] + [0.15, 0, -0.05]
    T[:, 4] = [0.0, -0.1, REST + 0.2]  # right foot swings in the air
    T[:, 4, 0] = np.linspace(-0.3, 0.3, F) * 1.0
    T[:, 5] = T[:, 4] + [0.15, 0, -0.05]
    return T


def test_planted_ankle_locks_and_floats_untouched():
    T = clip()
    T[:, 1, :2] += np.random.default_rng(0).normal(0, 0.001, (30, 2))  # sliding jitter
    P, planted, _ = plant_feet(T, FEET, REST, LEG, 1.0)
    assert planted[:, 0].all() and not planted[:, 1].any()
    assert np.ptp(P[:, 1, :2], axis=0).max() == 0.0  # no sliding while planted
    assert np.allclose(P[:, 1, 2], REST)  # snapped to rest height
    assert np.allclose(P[:, 4], T[:, 4])  # swing foot target unchanged


def test_control_a_moving_foot_is_not_planted():
    T = clip()
    T[:, 1, 0] = np.linspace(0, 1.5, 30)  # 0.05 m per frame: walking, not resting
    _, planted, _ = plant_feet(T, FEET, REST, LEG, 1.0)
    assert not planted[1:, 0].any()


def test_pelvis_drops_to_reach_planted_foot():
    T = clip()
    T[:, [0, 3, 6], 2] += 0.3  # hips too high for a 0.8 m leg over the foot
    P, _, un = plant_feet(T, FEET, REST, LEG, 1.0)
    assert not un.any()
    reach = 0.999 * LEG
    d = np.linalg.norm(P[:, 0] - P[:, 1], axis=1)
    assert np.all(d <= reach + 1e-9)  # hip within reach of the planted ankle
    assert np.all(P[:, 6, 2] < T[:, 6, 2])  # the rest of the body dropped


def test_toes_never_below_their_floor_and_swing_ankle_clamped():
    T = clip()
    T[:, 2, 2] = -0.02  # planted left toes target underground
    T[:, 5, 2] = 0.0  # swing right toes on the floor origin
    T[10:20, 4, 2] = REST - 0.03  # swing ankle dips below its floor
    P, _, _ = plant_feet(T, FEET, REST, LEG, 1.0, toes_floor_z=0.01)
    assert np.all(P[:, [2, 5], 2] >= 0.01 - 1e-12)  # toes at or above the toes floor, both feet
    assert np.all(P[:, [1, 4], 2] >= REST - 1e-12)  # ankles at or above the ankle floor, both feet


def test_foot_floor_heights_use_colliding_capsules():
    import os

    import pytest

    xml = os.environ.get("MSH700_XML")
    if not xml:
        pytest.skip("set MSH700_XML")
    import mujoco

    from plant_feet import foot_floor_heights

    h = foot_floor_heights(mujoco.MjModel.from_xml_path(xml))
    assert abs(h["ankle"] - 0.0550) < 1e-3 and abs(h["toes"] - 0.0140) < 1e-3  # talus 0.0671 - calcn low 0.0121; toes 0.0231 - low 0.0091

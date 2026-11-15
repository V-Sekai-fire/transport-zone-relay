"""Load a converted MS-Human-700 clip (msh700_trajectory.py output) into the MuscleMimic environment through its trajectory handler.

  MSH700_XML=.../MS-Human-700.xml pixi run python drive_msh700.py walk.traj.npz

Gate 1: the handler accepts the clip and reproduces its qpos, with the mimic-site targets above the floor.
No random actions: the clip is the reference, and later stages track it with a policy.
"""

import sys

import numpy as np

from loco_mujoco.trajectory import Trajectory, TrajectoryData, TrajectoryInfo, TrajectoryModel
from musclemimic.environments.humanoids.ms_human_700 import MsHuman700MyoFullBody


def load_clip(env, path: str) -> Trajectory:
    z = np.load(path)
    names = [str(n) for n in z["joint_names"]]
    model_names = [env._model.joint(j).name for j in range(env._model.njnt)]
    assert names == model_names, "clip joints differ from the environment model"
    info = TrajectoryInfo(
        joint_names=names,
        model=TrajectoryModel(njnt=len(names), jnt_type=np.asarray(z["jnt_type"])),
        frequency=float(z["frequency"]),
    )
    data = TrajectoryData(qpos=np.asarray(z["qpos"]), qvel=np.asarray(z["qvel"]), split_points=np.asarray(z["split_points"]))
    return Trajectory(info=info, data=data)


def main() -> None:
    env = MsHuman700MyoFullBody()
    traj = load_clip(env, sys.argv[1])
    env.load_trajectory(traj=traj)
    th = env.th
    print("handler trajectories:", th.n_trajectories, "length:", th.len_trajectory(0), "frequency:", th.traj.info.frequency)
    q = np.asarray(th.traj.data.qpos)
    print("qpos matches the clip:", np.allclose(q[: len(np.load(sys.argv[1])["qpos"])], np.load(sys.argv[1])["qpos"], atol=1e-6))


if __name__ == "__main__":
    main()

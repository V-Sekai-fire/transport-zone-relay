"""Wire MuscleMimic's own imitation reward to the MS-Human-700 clip and measure two bounds.

  MSH700_XML=.../MS-Human-700.xml pixi run python reward_check.py walk.traj.npz

Reference replay: after each physics step the simulator state is overwritten with the clip's next frame, so the reward is what a
perfect tracker earns (the ceiling). Zero-activation control: no override, every muscle relaxed (ctrl -1), the body falls and the
reward must stay clearly below the ceiling. Reward and terminal settings follow fullbody/conf_fullbody.yaml (MimicReward,
MeanRelativeSiteDeviationWithRootTerminalStateHandler), with the paper's 0.5 m site threshold.
"""

import sys

import mujoco
import numpy as np

from drive_msh700 import load_clip
from loco_mujoco.task_factories import ImitationFactory
from loco_mujoco.task_factories.dataset_confs import CustomDatasetConf
from musclemimic.environments.humanoids.ms_human_700 import BODY2SITES_FOR_MIMIC, MsHuman700MyoFullBody

SITES = list(BODY2SITES_FOR_MIMIC.values())
REWARD = dict(
    qpos_w_sum=0.1, qvel_w_sum=0.1, root_pos_w_sum=0.1, root_vel_w_sum=0.1, rpos_w_sum=0.6, rquat_w_sum=0.01, rvel_w_sum=0.1,
    action_rate_coeff=0.0, activation_energy_coeff=0.0, use_mean_exp_reward=False, sites_for_mimic=SITES,
)
TERMINAL = dict(mean_site_deviation_threshold=0.5, root_deviation_threshold=0.5, root_orientation_threshold=1.0, enable_site_check=True)


def make(traj, name="MsHuman700MyoFullBody"):
    return ImitationFactory.make(
        name,
        custom_dataset_conf=CustomDatasetConf(traj=traj, trajectory_cache_type="full"),
        terminal_state_type="MeanRelativeSiteDeviationWithRootTerminalStateHandler",
        terminal_state_params=TERMINAL,
        goal_type="GoalTrajMimic",
        goal_params=dict(n_step_lookahead=5, n_step_stride=20, sites_for_mimic=SITES, upper_body_xml_name="lumbar1"),
        reward_type="MimicReward",
        reward_params=REWARD,
        headless=True,
    )


def rollout(env, q, qd, replay: bool, n: int, offset: int = 0):
    """Total and per-step rewards over n control steps; replay overwrites the state with clip frame k+1 after each step."""
    env.reset()
    m, d = env._model, env._data
    rewards, steps = [], 0
    if replay:
        post = env._simulation_post_step

        def override(model, data, carry):
            data, carry = post(model, data, carry)
            # the handler starts at a random frame; its root check shifts the reference by the start frame's xy, so the state
            # written here is the clip frame with that xy removed (the post-step carry already holds the next frame's index)
            k = min(int(carry.traj_state.subtraj_step_no) + offset, len(q) - 1)
            data.qpos[:], data.qvel[:] = q[k], qd[k]
            data.qpos[:2] -= q[int(carry.traj_state.subtraj_step_no_init), :2]
            mujoco.mj_forward(model, data)
            return data, carry

        env._simulation_post_step = override
    action = np.full(env.info.action_space.shape, -1.0)  # relaxed
    for steps in range(n):
        _, r, absorbing, done, _ = env.step(action)
        rewards.append(float(r))
        if absorbing or done:
            break
    return np.array(rewards)


def main() -> None:
    path = sys.argv[1]
    env0 = MsHuman700MyoFullBody()
    traj = load_clip(env0, path)
    z = np.load(path)
    q, qd, n = z["qpos"], z["qvel"], len(z["qpos"]) - 2
    for label, replay, off in (("reference replay, frame +0", True, 0), ("reference replay, frame +1", True, 1), ("zero activation", False, 0)):
        r = rollout(make(traj), q, qd, replay, n, off)
        print(f"{label}: {len(r)} steps, mean reward {r.mean():.3f}, total {r.sum():.1f}")


if __name__ == "__main__":
    main()

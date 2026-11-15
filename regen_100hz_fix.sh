#!/bin/sh
# rerun batch shards whose pixi start failed (editable .pth race), then their penetration checks
O=${MSH700_OUT:?set MSH700_OUT to the output dir}; cd "$(dirname "$0")"
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 MSH700_XML=$HOME/msh700-session/menagerie/ms_human_700/MS-Human-700.xml
for i in 1 7; do
 ( pixi run python -u batch_to_100hz.py $O/shard$i $O/traj100 > $O/logs/batch$i.log 2>&1
   for f in $(ls $O/shard$i/*.qpos.npy | sed 's#.*/##;s#.qpos.npy##'); do pixi run python penetration_check.py $O/traj100/$f.npz > $O/logs/pen_$f.log 2>&1; done ) &
 sleep 20
done
wait; echo FIXDONE

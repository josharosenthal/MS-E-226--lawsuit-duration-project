#!/usr/bin/env bash
# =============================================================================
# submit_farmshare.sbatch — run everything as a background "job" on a FarmShare
# compute node, so it keeps going after you close the browser or Terminal.
#   Submit:        sbatch submit_farmshare.sbatch
#   Check status:  squeue -u $USER
#   Read output:   cat scales_setup_<jobnumber>.out
# Resource lines are a reasonable guess; see https://docs.farmshare.stanford.edu/
# =============================================================================
#SBATCH --job-name=scales_setup
#SBATCH --time=08:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --output=scales_setup_%j.out

cd "$SLURM_SUBMIT_DIR"
bash ./run_all.sh

#!/bin/bash

#SBATCH --exclude=nid006865,nid005613,nid005988
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=8
##SBATCH --cpus-per-task=8
#SBATCH --mem=0
#SBATCH --partition=standard-g
#SBATCH --time=0-00:30:00
#SBATCH --gpus-per-node=mi250:8
#SBATCH --exclusive=user
#SBATCH --hint=nomultithread
#SBATCH --account=project_462000273
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err

# if run without sbatch, invoke here
if [ -z $SLURM_JOB_ID ]; then
    mkdir -p logs
    sbatch "$0"
    exit
fi

# hold separate logs for easier debugging
rm -rf separate-logs
mkdir -p separate-logs

LEARNING_RATE=1.5e-4

set -euo pipefail

# symlink logs/latest.out and logs/latest.err
ln -f -s $SLURM_JOB_ID.out logs/latest.out
ln -f -s $SLURM_JOB_ID.err logs/latest.err

CHECKPOINT_PATH=checkpoints
TENSORBOARD_PATH=tensorboard
#rm -rf "$CHECKPOINT_PATH" "$TENSORBOARD_PATH" # Start from scratch

# Data
TRAIN_DATA_PATH="train-data.txt"
VALID_DATA_PATH="validation-data.txt"
TOKENIZER_PATH="tokenizer"

PP_SIZE=4
TP_SIZE=4

MICRO_BATCH_SIZE=1
GLOBAL_BATCH_SIZE=1024

export WORLD_SIZE=$((SLURM_GPUS_ON_NODE*SLURM_JOB_NUM_NODES))

TRAIN_SAMPLES=146_500_000
TRAIN_SAMPLES=${TRAIN_SAMPLES//_}    # drop "_" for bash math
LR_DECAY_SAMPLES=$TRAIN_SAMPLES
LR_WARMUP_SAMPLES=$((TRAIN_SAMPLES/100))

NLAYERS=60
NHIDDEN=6656
NHEADS=52
FFN_HIDDEN_SIZE=$((4*NHIDDEN))
SEQ_LEN=2048

SAVE_INTERVAL=1000
OPTIMIZER_ARGS=" \
    --optimizer adam \
    --adam-beta1 0.9 \
    --adam-beta2 0.95 \
    --adam-eps 1e-8 \
    --lr $LEARNING_RATE \
    --min-lr 2e-5 \
    --lr-decay-style cosine \
    --lr-decay-samples $LR_DECAY_SAMPLES \
    --lr-warmup-samples $LR_WARMUP_SAMPLES \
    --clip-grad 1.0 \
    --weight-decay 1e-1 \
    "

GPT_ARGS=" \
    --num-layers $NLAYERS \
    --hidden-size $NHIDDEN \
    --num-attention-heads $NHEADS \
    --ffn-hidden-size $FFN_HIDDEN_SIZE \
    --seq-length $SEQ_LEN \
    --max-position-embeddings $SEQ_LEN \
    --micro-batch-size $MICRO_BATCH_SIZE \
    --global-batch-size $GLOBAL_BATCH_SIZE \
    --train-samples $TRAIN_SAMPLES \
    --tokenizer-type GPT2BPETokenizer \
    --vocab-file vocab.json \
    --merge-file merges.txt \
    --init-method-std 0.0048 \
    --embed-layernorm \
    --sync-tp-duplicated-parameters \
    --bf16 \
    --seed 42 \
    --position-embedding-type alibi \
    --make-vocab-size-divisible-by 128 \
    $OPTIMIZER_ARGS \
    "

#    --checkpoint-activations \

OUTPUT_ARGS=" \
    --log-interval 1 \
    --save-interval $SAVE_INTERVAL \
    --eval-interval 100 \
    --eval-iters 100 \
    --tensorboard-dir $TENSORBOARD_PATH \
    --tensorboard-queue-size 5 \
    --log-timers-to-tensorboard \
    --log-batch-size-to-tensorboard \
    --log-validation-ppl-to-tensorboard \
    "

ZERO_STAGE=0

mkdir -p ds_configs
DS_CONFIG_PATH="ds_configs/$SLURM_JOB_ID.json"

cat <<EOF > $DS_CONFIG_PATH
{
    "train_micro_batch_size_per_gpu": $MICRO_BATCH_SIZE,
    "train_batch_size": $GLOBAL_BATCH_SIZE,
    "gradient_clipping": 1.0,
    "zero_optimization": {
        "stage": $ZERO_STAGE
    },
    "bf16": {
        "enabled": true
    },
    "steps_per_print": 2000,
    "wall_clock_breakdown": false
}
EOF

DEEPSPEED_ARGS=" \
    --deepspeed \
    --deepspeed_config $DS_CONFIG_PATH \
    --zero-stage $ZERO_STAGE \
    "

CMD=" \
    Megatron-DeepSpeed/pretrain_gpt.py \
    --tensor-model-parallel-size $TP_SIZE \
    --pipeline-model-parallel-size $PP_SIZE \
    $GPT_ARGS \
    $OUTPUT_ARGS \
    --save $CHECKPOINT_PATH \
    --load $CHECKPOINT_PATH \
    --train-weighted-split-paths-path $TRAIN_DATA_PATH \
    --valid-weighted-split-paths-path $VALID_DATA_PATH \
    --data-impl mmap \
    --dataloader-type single \
    --num-workers 2 \
     $DEEPSPEED_ARGS \
    "

# Bind masks from Samuel
c=fe

# Bind mask for one thread per core
BIND_MASK_1="0x${c}000000000000,0x${c}00000000000000,0x${c}0000,0x${c}000000,0x${c},0x${c}00,0x${c}00000000,0x${c}0000000000"

# Bind mask for two threads per core
BIND_MASK_2="0x${c}00000000000000${c}000000000000,0x${c}00000000000000${c}00000000000000,0x${c}00000000000000${c}0000,0x${c}00000000000000${c}000000,0x${c}00000000000000${c},0x${c}00000000000000${c}00,0x${c}00000000000000${c}00000000,0x${c}00000000000000${c}0000000000"

BIND_MASK="$BIND_MASK_1"
echo "Using --cpu-bind=mask_cpu:$BIND_MASK"

echo $CMD

echo "START $SLURM_JOBID: $(date)"

srun \
    --label \
    --cpu-bind=mask_cpu:$BIND_MASK \
    launch.sh \
    $CMD

echo "END $SLURM_JOBID: $(date)"

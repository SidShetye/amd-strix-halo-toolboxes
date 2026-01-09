#!/usr/bin/env bash
set -uo pipefail

# optionally let user supply models directory as first argument
if [[ ${#} -ge 1 && -n "$1" ]]; then
  MODEL_DIR="$(realpath "$1")"
else
  MODEL_DIR="$(realpath models)"
fi
# Use an absolute path for the results directory
if [[ -e results ]]; then
  RESULT_DIR="$(realpath results)"
else
  mkdir -p results
  RESULT_DIR="$(realpath results)"
fi

# Pick exactly one .gguf file or link, per model: either
#  - any .gguf without "-000*-of-" (single-file models)
#  - or the first shard "*-00001-of-*.gguf"
mapfile -t MODEL_PATHS < <(
  find "$MODEL_DIR" \( -type f -o -type l \) -name '*.gguf' \
    \( -name '*-00001-of-*.gguf' -o -not -name '*-000*-of-*.gguf' \) \
    | sort
)

if (( ${#MODEL_PATHS[@]} == 0 )); then
  echo "❌ No models found under $MODEL_DIR – check your paths/patterns!"
  exit 1
fi

echo "Found ${#MODEL_PATHS[@]} model(s) to bench:"
for p in "${MODEL_PATHS[@]}"; do
  echo "  • $p"
done
echo

is_ubuntu() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      return 0
    fi
    if [[ -n "${ID_LIKE:-}" && "${ID_LIKE,,}" == *ubuntu* ]]; then
      return 0
    fi
  fi
  return 1
}

if is_ubuntu; then

  # In Ubuntu GPU access needs root, docker runs as root, pass args
  EXTRA_CONTAINER_ARGS="--device /dev/dri \
  --device /dev/kfd \
  --security-opt seccomp=unconfined \
  --ipc=host \
  --pid=host \
  -v ${MODEL_DIR}:${MODEL_DIR} \
  -v ${RESULT_DIR}:${RESULT_DIR}"

  declare -A CMDS=(
    ##[rocm6_4_4]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-6.4.4 /usr/local/bin/llama-bench"
    ##[rocm6_4_4-rocwmma]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-6.4.4-rocwmma /usr/local/bin/llama-bench"
    [rocm7.1.1]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.1.1 /usr/local/bin/llama-bench"
    [rocm7.1.1-rocwmma]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.1.1-rocwmma /usr/local/bin/llama-bench"
    ##[rocm-7alpha-rocwmma-improved]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7alpha-rocwmma-improved /usr/local/bin/llama-bench"
    [rocm-7alpha]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7alpha /usr/local/bin/llama-bench"
    ##[rocm-7alpha-rocwmma]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7alpha-rocwmma /usr/local/bin/llama-bench"
    [rocm7_rc]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7rc /usr/local/bin/llama-bench"
    ##[rocm7_rc-rocwmma]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7rc-rocwmma /usr/local/bin/llama-bench"
    # discontinued path
    ##[vulkan_amdvlk]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:vulkan-amdvlk /usr/sbin/llama-bench"
    [vulkan_radv]="docker run --rm ${EXTRA_CONTAINER_ARGS} docker.io/kyuz0/amd-strix-halo-toolboxes:vulkan-radv /usr/sbin/llama-bench"
  )
else
  declare -A CMDS=(
    #[rocm6_4_4]="toolbox run -c llama-rocm-6.4.4 -- /usr/local/bin/llama-bench"
    #[rocm6_4_4-rocwmma]="toolbox run -c llama-rocm-6.4.4-rocwmma -- /usr/local/bin/llama-bench"
    [rocm7.1.1]="toolbox run -c llama-rocm-7.1.1 -- /usr/local/bin/llama-bench"
    #[rocm7.1.1-rocwmma]="toolbox run -c llama-rocm-7.1.1-rocwmma -- /usr/local/bin/llama-bench"
    #[rocm-7alpha-rocwmma-improved]="toolbox run -c llama-rocm-7alpha-rocwmma-improved -- /usr/local/bin/llama-bench"
    #[rocm-7alpha]="toolbox run -c llama-rocm-7alpha -- /usr/local/bin/llama-bench"
    #[rocm-7alpha-rocwmma]="toolbox run -c llama-rocm-7alpha-rocwmma -- /usr/local/bin/llama-bench"
    [rocm7_rc]="toolbox run -c llama-rocm-7rc -- /usr/local/bin/llama-bench"
    #[rocm7_rc-rocwmma]="toolbox run -c llama-rocm-7rc-rocwmma -- /usr/local/bin/llama-bench"
    #[vulkan_amdvlk]="toolbox run -c llama-vulkan-amdvlk -- /usr/sbin/llama-bench"
    [vulkan_radv]="toolbox run -c llama-vulkan-radv -- /usr/sbin/llama-bench"
  )
fi


get_hblt_modes() {
  local env="$1"
  if [[ "$env" == rocm* ]]; then
    printf '%s\n' default off
  else
    printf '%s\n' default
  fi
}

for MODEL_PATH in "${MODEL_PATHS[@]}"; do
  MODEL_NAME="$(basename "$MODEL_PATH" .gguf)"

  for ENV in "${!CMDS[@]}"; do
    CMD="${CMDS[$ENV]}"
    mapfile -t HBLT_MODES < <(get_hblt_modes "$ENV")

    for MODE in "${HBLT_MODES[@]}"; do
      BASE_SUFFIX=""
      CMD_EFFECTIVE="$CMD"

      if [[ "$ENV" == rocm* ]]; then
        if [[ "$MODE" == off ]]; then
          BASE_SUFFIX="__hblt0"
          CMD_EFFECTIVE="${CMD_EFFECTIVE/-- /-- env ROCBLAS_USE_HIPBLASLT=0 }"
        else
          CMD_EFFECTIVE="${CMD_EFFECTIVE/-- /-- env ROCBLAS_USE_HIPBLASLT=1 }"
        fi
      fi

      # run twice: baseline and with flash attention
      for FA in 1; do
        SUFFIX="$BASE_SUFFIX"
        EXTRA_ARGS=()
        if (( FA == 1 )); then
          SUFFIX="${SUFFIX}__fa1"
          EXTRA_ARGS=( -fa 1 )
        fi

        for CTX in default longctx32768; do
          CTX_SUFFIX=""
          CTX_ARGS=()
          if [[ "$CTX" == longctx32768 ]]; then
            CTX_SUFFIX="__longctx32768"
            CTX_ARGS=( -p 2048 -n 32 -d 32768 )
            if [[ "$ENV" == *vulkan* ]]; then
              CTX_ARGS+=( -ub 512 )
            else
              CTX_ARGS+=( -ub 2048 )
            fi
          fi

          OUT="$RESULT_DIR/${MODEL_NAME}__${ENV}${SUFFIX}${CTX_SUFFIX}.log"
          CTX_REPS=3
          if [[ "$CTX" == longctx32768 ]]; then
            CTX_REPS=1
          fi

          if [[ -s "$OUT" ]]; then
            echo "⏩ Skipping [${ENV}] ${MODEL_NAME}${SUFFIX}${CTX_SUFFIX:+ ($CTX_SUFFIX)}, log already exists at $OUT"
            continue
          fi

          FULL_CMD=( $CMD_EFFECTIVE -ngl 99 -mmp 0 -m "$MODEL_PATH" "${EXTRA_ARGS[@]}" "${CTX_ARGS[@]}" -r "$CTX_REPS" )

          printf "\n▶ [%s] %s%s%s\n" "$ENV" "$MODEL_NAME" "${SUFFIX:+ $SUFFIX}" "${CTX_SUFFIX:+ $CTX_SUFFIX}"
          printf "  → log: %s\n" "$OUT"
          printf "  → cmd: %s\n\n" "${FULL_CMD[*]}"

          if ! "${FULL_CMD[@]}" >"$OUT" 2>&1; then
            status=$?
            echo "✖ ! [${ENV}] ${MODEL_NAME}${SUFFIX}${CTX_SUFFIX:+ $CTX_SUFFIX} failed (exit ${status})" >>"$OUT"
            echo "  * [${ENV}] ${MODEL_NAME}${SUFFIX}${CTX_SUFFIX:+ $CTX_SUFFIX} : FAILED"
          fi
        done
      done
    done
  done
done

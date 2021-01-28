#!/bin/bash

# Require root
[ "$UID" -eq 0 ] || exec sudo bash "$0" "$@"

config_path=/etc/gpu-profile/config

if ! test -f "$config_path/default.conf"; then
  echo "No default config found"
  exit
fi

# Enable persistence mode
nvidia-smi -pm 1

get_container_property() {
  arg="${1}"
  key="${2}"
  container_id="${3}"

  docker inspect -f "{{range \$index, \$value := $arg}}{{if eq (index (split \$value \"=\") 0) \"$key\" }}{{range \$i, \$part := (split \$value \"=\")}}{{if gt \$i 1}}{{print \"=\"}}{{end}}{{if gt \$i 0}}{{print \$part}}{{end}}{{end}}{{end}}{{end}}" $container_id
}

process_container() {
  status="${1}"
  container_id="${2}"
  gpu_id="${3}"

  echo "EVENT Status: $status Container: $container_id"

  if [ "$gpu_id" = "all" ]; then
    echo "Skipping as no specific GPU provided"
    continue
  fi

  echo "Applying settings to GPU: $gpu_id"

  image_name="$(docker inspect -f '{{ .Config.Image }}' $container_id)"
  container_config_path="$config_path/$image_name.conf"

  if test -f "$container_config_path"; then
    source $container_config_path
    echo "Loading custom config"
  else
    source "$config_path/default.conf"
    echo "Loading default config"
  fi

  echo "Setting power limit: $POWER_LIMIT watt"
  nvidia-smi -i $gpu_id -pl $POWER_LIMIT # This does not require X. Everything below does.
  
  # Setup X for overclocking. This is messy and might not work on your machine. Fuck nvidia.
  pkill -f /usr/lib/xorg/Xorg
  sleep 3
  X :99 &
  sleep 3
  export DISPLAY=:99
  sleep 3

  echo "Setting memory offset $MEM_CLOCK_OFFSET with clock support $CLOCK_SUPPORT"
  nvidia-settings -a "[gpu:$gpu_id]/GPUMemoryTransferRateOffset[$CLOCK_SUPPORT]=$MEM_CLOCK_OFFSET"

  echo "Setting clock offset $CLOCK_OFFSET with clock support $CLOCK_SUPPORT"
  nvidia-settings -a "[gpu:$gpu_id]/GPUGraphicsClockOffset[$CLOCK_SUPPORT]=$CLOCK_OFFSET"

  pkill -f /usr/lib/xorg/Xorg
}


# Apply initial values on startup
docker ps -q | while read container;
do
  gpu_id=$(get_container_property ".Config.Env" "NVIDIA_VISIBLE_DEVICES" $container)
  process_container "boot" $container $gpu_id
done

echo "Starting container monitor"

while [ 1 ]
do
  docker events --format "{{json .}}" | while read line; do
    status=$(echo "$line" | jq -r .status)

    if [ "$status" = "start" ]; then
      container_id=$(echo "$line" | jq -r .id)
      gpu_id=$(get_container_property ".Config.Env" "NVIDIA_VISIBLE_DEVICES" $container_id)

      process_container $status $container_id $gpu_id
    fi
  done
done

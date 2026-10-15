The script only works when the sudo nvme smart-log command is configured for **passwordless** execution.

## make the script executable
chmod +x nvme-write-monitor.sh

## run interactively
./nvme-write-monitor.sh

## send to background
./nvme-write-monitor.sh &

## force immediate logging (Writing a newline character (\n) to the FIFO)
printf '\n' > /run/user/$UID/nvme-write-monitor-$UID/wake

## create an alias
alias nvme-log-now="printf '\n' > /run/user/\$UID/nvme-write-monitor-\$UID/wake"

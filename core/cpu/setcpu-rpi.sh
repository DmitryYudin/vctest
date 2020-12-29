set -eu

set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )

. $dirScript/../../remote.local

plink -P 22 -batch -l $user -pw $passw $ip \
'
    sudo cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
	echo userspace | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
	echo 1500000 | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed
	echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/policy0/stats/reset
	echo scaling_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
	echo scaling_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
'

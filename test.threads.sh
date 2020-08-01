set -eu -o pipefail

BITRATE="1000"
VECTORS=tears_of_steel_1280x720_24.webm.yuv
VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)

PRESET=
HIDE_BANNER=
encode() {
	local THREADS="1 2 3 4 5 6"
	for i in $THREADS; do
		./core/testbench.sh --threads $i -i "$VECTORS" -c "$codec" -p "${QP:-} ${BITRATE:-}" ${PRESET:+ --preset "$PRESET"} \
			-o report/threads${PRESET:+_preset}.log ${HIDE_BANNER:+ --hide} "$@"
		HIDE_BANNER=1
	done
}

if [[ 1 == 1 ]]; then 			# use default preset
	codec="ashevc";  encode "$@"
	codec="x265";    encode "$@"
	codec="kvazaar"  encode "$@"
	codec="kingsoft" encode "$@"
	codec="intel_sw" encode "$@"
	codec="intel_hw" encode "$@"
	codec="h265demo" encode "$@"
else							# use max speed
	codec="ashevc";  PRESET="1" 		encode "$@"
	codec="x265";    PRESET="ultrafast" encode "$@"
	codec="kvazaar"  PRESET="ultrafast" encode "$@"
	codec="kingsoft" PRESET="ultrafast" encode "$@"
	codec="intel_sw" PRESET="veryfast"  encode "$@"
	codec="intel_hw" PRESET="veryfast"  encode "$@"
	codec="h265demo" PRESET="6"   		encode "$@"
fi

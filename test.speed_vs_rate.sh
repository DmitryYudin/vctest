set -eu -o pipefail

case 1 in
	0)	BITRATE="60  100  150"; VECTORS="akiyo_qcif.yuv";; # fast check
	1)	BITRATE="500 1000 1500" VECTORS=tears_of_steel_1280x720_24.webm.yuv
esac
VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)
THREADS=1

PRESET=
HIDE_BANNER=
encode() {
	local suff='preset=none'
	[ -n "$PRESET" ] && suff='preset=fast'
	./core/testbench.sh --threads $THREADS -i "$VECTORS" -c "$codec" -p "${QP:-} ${BITRATE:-}" ${PRESET:+ --preset "$PRESET"} \
		-o report/speed_vs_rate_$suff.log ${HIDE_BANNER:+ --hide}
	HIDE_BANNER=1
}

if [ 1 == 1 ]; then 			# use default preset
	codec="ashevc";  encode
	codec="x265";    encode
	codec="kvazaar"  encode
	codec="kingsoft" encode
	codec="intel_sw" encode
	codec="intel_hw" encode
	codec="h265demo" encode
else							# use max speed
	codec="ashevc";  PRESET="1" 		encode
	codec="x265";    PRESET="ultrafast" encode
	codec="kvazaar"  PRESET="ultrafast" encode
	codec="kingsoft" PRESET="ultrafast" encode
	codec="intel_sw" PRESET="veryfast"  encode
	codec="intel_hw" PRESET="veryfast"  encode
	codec="h265demo" PRESET="6"   		encode
fi

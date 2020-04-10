set -eu -o pipefail

case 1 in
	0)	BITRATE=80;   VECTORS="akiyo_qcif.yuv";; # fast check
	1)	BITRATE=1000; VECTORS=tears_of_steel_1280x720_24.webm.yuv
esac
VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)

HIDE_BANNER=
encode() {
	./core/testbench.sh -i "$VECTORS" -c "$codec" -p "${QP:-} ${BITRATE:-}" --preset "$PRESET" \
		-o preset.log -d out/preset ${HIDE_BANNER:+ --hide}
	HIDE_BANNER=1
}

if [ 0 == 0 ]; then  # too slow preset removed
	codec="ashevc";  PRESET="1 2 3 4 5" 																	encode
	codec="x265";    PRESET="ultrafast superfast veryfast faster fast medium slow" 							encode
	codec="kvazaar"  PRESET="ultrafast superfast veryfast faster fast medium slow" 							encode
	codec="kingsoft" PRESET="ultrafast superfast veryfast        fast medium slow" 							encode
	codec="intel_sw" PRESET="                    veryfast faster fast medium slow"         					encode
	codec="intel_hw" PRESET="                    veryfast faster fast medium slow"         					encode
	codec="h265demo" PRESET="6 5 4 3 2"                                                                		encode
else                 # full range
	codec="ashevc";  PRESET="1 2 3 4 5 6" 																	encode
	codec="x265";    PRESET="ultrafast superfast veryfast faster fast medium slow slower veryslow placebo" 	encode
	codec="kvazaar"  PRESET="ultrafast superfast veryfast faster fast medium slow slower veryslow placebo" 	encode
	codec="kingsoft" PRESET="ultrafast superfast veryfast        fast medium slow        veryslow placebo" 	encode
	codec="intel_sw" PRESET="                    veryfast faster fast medium slow slower veryslow"         	encode
	codec="intel_hw" PRESET="                    veryfast faster fast medium slow slower veryslow"         	encode
	codec="h265demo" PRESET="6 5 4 3 2 1"                                                                  	encode
fi

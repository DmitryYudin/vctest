set -eu -o pipefail

#
# This is a frontend example for the './core/testbench.sh' script
#
[ "$#" -gt 0 ] && ./core/testbench.sh -h && exit

#CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo"
#CODECS=ashevc
#CODECS=x265

QP="28 34 39 44"
case 0 in
	0)	BITRATE="  60   80   120   150"; VECTORS="akiyo_qcif.yuv foreman_qcif.yuv";; # fast check
	1)	BITRATE="1500  2000 3000  4000"; VECTORS="FourPeople_1280x720_30.y4m.yuv tears_of_steel_1280x720_24.webm.yuv";;
esac

VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)
./core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "${QP:-} ${BITRATE:-}"

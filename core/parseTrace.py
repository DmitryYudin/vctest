import sys
import mmap
import re

if len(sys.argv)<=1:
    print("Usage: parseTrace.py <trace file>\n")
    print("  Typically, trace file is TraceDec.txt or TraceEnc.txt\n")

numSkip=0
numIntra=0
numInter=0

with open(sys.argv[1], 'r+') as f:

    m = f.read()
    curpos = 0
    def getSlicePos(only_p_slice, curpos):
        pattern = r"slice_type.*1\n" if only_p_slice else r"slice_type.*\n"
        cpat1 = re.compile(pattern)
        res = cpat1.search(m, curpos)
        if res is None:
            return len(m)
        curpos = res.regs[0][0]

        cpat2 = re.compile(r"POC:.*\n")
        res = cpat2.search(m, curpos)

        curpos = res.regs[0][0]

        if res is None:
            return len(m)
        else:
            return curpos

    def getLine(curpos):
        cpat = re.compile(r"\n")
        res = cpat.search(m, curpos)
        if res is None:
            return len(m)
        else:
            return m[curpos:res.regs[0][0]]


    #next slice
    slice_start = getSlicePos(True, curpos)
    curpos = slice_start

    while True:
        if curpos>=len(m)-1:
            break;

        next_slice_start = getSlicePos(False, curpos+1)

        while True:
            if curpos >= next_slice_start:
                slice_start=next_slice_start
                break
            line = getLine(curpos)
            curpos = curpos+len(line)+1
            if re.match(".*SkipFlag.*uiSymbol: 1", line):
                numInter=numInter+1
                numSkip=numSkip+1
            else:
                if re.match(".*CoeffNxN.*predmode=.", line):
                    if line[-1]=='0': #inter
                        numInter = numInter + 1
                    else:
                        if line[-1]=='1': #intra
                            numIntra = numIntra + 1
                        else:
                            raise Exception("parse error: predmode value expected but not found  ")

    print("numIntra:%d numInter:%d numSkip:%d" % (numIntra, numInter, numSkip))

